import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.bbdaniels.topaz.loupe", category: "FileDeliveries")

/// The files the running sessions send with SendUserFile, as cards in the
/// panel (`FileDeliveriesSection`). Every `interval` it reads what each
/// running session's transcript has gained since the last read
/// (`TranscriptFollow`: the MacBook's from disk, the iMac's over one ssh),
/// takes the SendUserFile calls from it (`FileDeliveryRecord`) and keeps
/// them, with each transcript's offset, in `FileDeliveryLog` on disk. A
/// click on a file copies it here from the session's machine when it is the
/// iMac's (`FileDeliveryFetch`) and opens it in its default app, whatever
/// its type.
@MainActor
final class FileDeliveryService: ObservableObject {
    /// The cards, newest first.
    @Published private(set) var deliveries: [FileDelivery] = []
    /// The files being fetched and opened now (`fileKey`).
    @Published private(set) var opening: Set<String> = []
    /// Why the last open of a file failed (`fileKey`), until it is tried again.
    @Published private(set) var failures: [String: String] = [:]

    static let interval: TimeInterval = 5
    /// A session that has just left the live list is read for this long
    /// after, so a file sent as its last act is not missed.
    static let followAfterEnd: TimeInterval = 30

    private var log = FileDeliveryLog.load()
    private var timer: DispatchSourceTimer?
    private var polling = false
    private weak var agents: AgentsService?
    private weak var history: SessionHistoryService?
    /// The sessions seen running, with when each was last seen.
    private var followed: [String: (target: TranscriptFollow.Target, name: String, seen: Date)] = [:]

    static func fileKey(_ delivery: FileDelivery, _ file: String) -> String { delivery.id + "\n" + file }

    /// Start following. `history` supplies a MacBook transcript's path when
    /// a session's row has none.
    func start(agents: AgentsService, history: SessionHistoryService) {
        self.agents = agents
        self.history = history
        let dropped = log.prune()
        if !dropped.isEmpty { log.save() }
        deliveries = log.deliveries
        let kept = log.deliveries
        Task.detached(priority: .utility) { FileDeliveryFetch.sweep(keeping: kept) }

        guard timer == nil else { return }
        // A GCD timer fires whatever the panel's run-loop mode (AgentsService.start).
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: Self.interval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in Task { @MainActor in self?.poll() } }
        t.resume()
        timer = t
    }

    /// The transcripts to read now: each running session's, and for
    /// `followAfterEnd` after it was last seen, each one that has ended.
    private func targets(now: Date) -> [(target: TranscriptFollow.Target, name: String)] {
        for a in agents?.agents ?? [] where a.isAlive {
            guard let sid = a.sessionId, TranscriptFollow.isSessionId(sid) else { continue }
            let host: SessionHost = a.isIMac ? .iMac : .mac
            var target = TranscriptFollow.Target(host: host, sessionId: sid, offset: nil)
            if host == .mac {
                target.localPath = a.transcriptPath
                    ?? history?.sessions.first { $0.id == sid && $0.host == .mac }?.filePath
                if target.localPath == nil { continue }
            }
            followed[FileDeliveryLog.key(host, sid)] = (target, a.title ?? a.name, now)
        }
        followed = followed.filter { now.timeIntervalSince($0.value.seen) <= Self.followAfterEnd }
        return followed.values.map { entry in
            var target = entry.target
            target.offset = log.offset(target.host, target.sessionId)
            return (target, entry.name)
        }
    }

    private func poll() {
        guard !polling else { return }
        let started = Date()
        let wanted = targets(now: started)
        guard !wanted.isEmpty else {
            markWatched(answered: Set(SessionHost.allCases), at: started)
            saveIfDue(at: started)
            return
        }
        polling = true
        let names = Dictionary(wanted.map { (FileDeliveryLog.key($0.target.host, $0.target.sessionId), $0.name) },
                               uniquingKeysWith: { a, _ in a })
        let list = wanted.map(\.target)
        Task.detached(priority: .utility) { [weak self] in
            let result = TranscriptFollow.read(list)
            await MainActor.run {
                guard let self else { return }
                self.polling = false
                let offsets = self.log.tails.mapValues(\.offset)
                var changed = false
                for chunk in result.chunks {
                    let name = names[FileDeliveryLog.key(chunk.host, chunk.sessionId)] ?? ""
                    if self.log.apply(chunk, sessionName: name) { changed = true }
                }
                self.markWatched(answered: result.answered, at: started)
                if changed {
                    _ = self.log.prune()
                    self.deliveries = self.log.deliveries
                    logger.info("file deliveries: \(self.log.deliveries.count, privacy: .public) cards after a read")
                }
                // A card or an offset is written at once; the read times
                // alone at most once a minute.
                if changed || self.log.tails.mapValues(\.offset) != offsets {
                    self.lastSave = started
                    self.log.save()
                } else {
                    self.saveIfDue(at: started)
                }
            }
        }
    }

    /// Note that `answered` were read at `at`. The iMac counts only when
    /// its gate also answered, so a poll with no iMac session to read says
    /// nothing while the iMac is unreachable.
    private func markWatched(answered: Set<SessionHost>, at: Date) {
        for host in answered where host == .mac || GateLive.answered(.iMac) {
            log.watched[host.rawValue] = at
        }
    }

    private var lastSave = Date.distantPast

    private func saveIfDue(at: Date) {
        guard at.timeIntervalSince(lastSave) >= 60 else { return }
        lastSave = at
        log.save()
    }

    // MARK: - Cards

    /// The session's name as its line shows it now, else as History lists
    /// it, else as it was when the file was sent.
    func sessionName(_ delivery: FileDelivery) -> String {
        if let a = agents?.agents.first(where: { $0.isAlive && $0.sessionId == delivery.sessionId }) {
            return a.title ?? a.name
        }
        if let s = history?.sessions.first(where: { $0.id == delivery.sessionId }) { return s.preview }
        return delivery.sessionName.isEmpty ? "A session on the \(delivery.host.machine)" : delivery.sessionName
    }

    func dismiss(_ delivery: FileDelivery) {
        log.dismiss(delivery.id)
        log.save()
        deliveries = log.deliveries
        for file in delivery.files { failures[Self.fileKey(delivery, file)] = nil }
        let folder = FileDeliveryFetch.cacheFolder(delivery)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: - Opening

    /// Open `file` of `delivery` in its default app: copied here first when
    /// it is the iMac's. A type no app opens is shown in the Finder instead.
    func open(_ delivery: FileDelivery, file: String) {
        let key = Self.fileKey(delivery, file)
        guard !opening.contains(key) else { return }
        opening.insert(key)
        failures[key] = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = FileDeliveryFetch.localCopy(delivery, file: file)
            await MainActor.run {
                guard let self else { return }
                self.opening.remove(key)
                switch outcome {
                case .failed(let reason):
                    self.failures[key] = reason
                    logger.error("file delivery: \(file, privacy: .public): \(reason, privacy: .public)")
                case .ready(let url):
                    if !NSWorkspace.shared.open(url) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
    }

    // MARK: - Command line

    /// `Loupe --fetch-file-delivery <call id>`: bring every file of that
    /// card here as a click would, without opening any, and print where each
    /// is. For checking the copy from the iMac over ssh.
    nonisolated static func fetchCommandLine(_ id: String) -> Int32 {
        guard let delivery = FileDeliveryLog.load().deliveries.first(where: { $0.id == id }) else {
            FileHandle.standardError.write(Data("no card with the call id \(id)\n".utf8))
            return 1
        }
        var status: Int32 = 0
        for file in delivery.files {
            switch FileDeliveryFetch.localCopy(delivery, file: file) {
            case .ready(let url):
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? -1
                print("\(url.path)  (\(size) bytes)")
            case .failed(let reason):
                print("\(file): \(reason)")
                status = 1
            }
        }
        return status
    }
}
