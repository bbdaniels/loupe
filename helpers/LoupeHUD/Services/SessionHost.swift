import Foundation

// MARK: - Session host

/// The machine a Claude Code session ran on. History lists both: the Mac's
/// own transcripts, and the iMac's (Ubuntu, `ssh imac`), read from a local
/// read-only mirror that `IMacMirror` refreshes with rsync. One scan, one
/// filing rule and one index serve both; the host only says where the
/// transcript and its claim live, how its paths map onto this Mac, and where
/// it resumes.
///
/// Foundation only (no AppKit), so the tests compile it directly.
enum SessionHost: String, CaseIterable, Sendable {
    case mac
    case iMac

    /// The machine as Ben reads it on a session's line and in an alert.
    var machine: String {
        switch self {
        case .mac: return "MacBook"
        case .iMac: return "iMac"
        }
    }

    /// The iMac's home directory, where its `~/.claude` and `~/Projects` live.
    static let iMacHome = "/home/bbdaniels"

    /// Where the iMac's mirror lives on this Mac:
    /// `~/Library/Caches/Loupe/hosts/imac`, holding `projects/` (its
    /// transcripts) and `session-projects/` (its claim records).
    static func iMacMirrorRoot(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Caches/Loupe/hosts/imac"
    }

    /// The directory of per-project transcript directories this host's scan reads.
    func projectsDir(home: String = NSHomeDirectory()) -> String {
        switch self {
        case .mac: return home + "/.claude/projects"
        case .iMac: return Self.iMacMirrorRoot(home: home) + "/projects"
        }
    }

    /// The directory of this host's claim records (`SessionFiling`).
    func claimsDir(home: String = NSHomeDirectory()) -> URL {
        switch self {
        case .mac:
            return URL(fileURLWithPath: home).appendingPathComponent(".claude/session-projects", isDirectory: true)
        case .iMac:
            return URL(fileURLWithPath: Self.iMacMirrorRoot(home: home))
                .appendingPathComponent("session-projects", isDirectory: true)
        }
    }

    // MARK: Path mapping

    /// A path as this host wrote it, on this Mac. The Mac's paths are its
    /// own. The iMac's `~/Projects` holds the same checkouts as the Mac's, so
    /// `/home/bbdaniels/Projects/<rest>` maps to `<home>/Projects/<rest>`
    /// and an iMac session files under the same vault project as a Mac one.
    /// Any other iMac path is returned unchanged: this Mac has no copy of it.
    func macPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard self == .iMac else { return path }
        let root = Self.iMacHome + "/Projects"
        if path == root { return home + "/Projects" }
        guard path.hasPrefix(root + "/") else { return path }
        return home + "/Projects" + path.dropFirst(root.count)
    }

    /// Claude Code's encoding of a directory as a project directory name:
    /// every character that is not an ASCII letter or digit becomes "-".
    static func encodeDirName(_ path: String) -> String {
        String(path.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-"
        })
    }

    /// An iMac project directory name under `~/Projects`
    /// (`-home-bbdaniels-Projects-heat-tv`) as the Mac would have named the
    /// same directory (`-Users-bbdaniels-Projects-heat-tv`), so the Mac's
    /// decoder resolves it against the Mac's own checkouts. Nil for an iMac
    /// directory outside `~/Projects`, and for every Mac directory name.
    func macDirName(_ dirName: String, home: String = NSHomeDirectory()) -> String? {
        guard self == .iMac else { return nil }
        let iMacRoot = Self.encodeDirName(Self.iMacHome + "/Projects")
        guard dirName == iMacRoot || dirName.hasPrefix(iMacRoot + "-") else { return nil }
        return Self.encodeDirName(home + "/Projects") + dirName.dropFirst(iMacRoot.count)
    }
}

// MARK: - The iMac mirror

/// Copies the iMac's transcripts and claim records into this Mac's mirror
/// (`SessionHost.iMacMirrorRoot`) with rsync over ssh. Read-only toward the
/// iMac: nothing is ever written there.
///
/// What is copied: each top-level `*.jsonl` of every project directory of the
/// iMac's `~/.claude/projects` (not the subagent transcripts in deeper
/// folders, which history never lists), and every `*.json` claim of its
/// `~/.claude/session-projects`. `--delete` drops what the iMac removed.
///
/// The Mac's `/usr/bin/rsync` is openrsync (protocol 29), which has neither
/// `--append-verify` nor working compression against the iMac's rsync 3.4.1
/// (a `-z` transfer stalled until its I/O timeout in two probes on 2026-11-03).
/// So the transfer is rsync's default: a file whose size and modification
/// time are unchanged is skipped, and a grown transcript sends only its new
/// blocks through the delta algorithm, then replaces the mirror's copy by an
/// atomic rename, so a scan never reads a half-written file. `-t` keeps the
/// iMac's modification times, which History shows as the session's time.
/// `--partial-dir` keeps an interrupted file's bytes in a hidden folder so the
/// next run resumes it: a first mirror larger than one run's time limit
/// completes over several refreshes.
///
/// One run at a time (a second call while one runs returns `.busy`), a hard
/// limit of `timeLimit` seconds, after which rsync is stopped and the mirror
/// keeps what it had. Blocks: call it off the main thread.
enum IMacMirror {
    static let timeLimit: TimeInterval = 30
    static let rsyncPath = "/usr/bin/rsync"

    enum Outcome: Equatable {
        case synced
        case busy
        case failed(String)
    }

    /// rsync's arguments for one run into `root`.
    static func rsyncArguments(root: String = SessionHost.iMacMirrorRoot()) -> [String] {
        [
            "-rtm", "--delete",
            "--timeout=20",
            "--partial-dir=.rsync-partial",
            "-e", "ssh -o BatchMode=yes -o ConnectTimeout=10",
            "--include=/projects/",
            "--include=/projects/*/",
            "--include=/projects/*/*.jsonl",
            "--include=/session-projects/",
            "--include=/session-projects/*.json",
            "--exclude=*",
            "\(IMacLauncher.sshHost):.claude/",
            root.hasSuffix("/") ? root : root + "/",
        ]
    }

    /// A cheap fingerprint of the mirror (every file's path, size and
    /// modification time), so a caller rescans only when a run changed it.
    static func signature(root: String = SessionHost.iMacMirrorRoot()) -> Int {
        var hasher = Hasher()
        let fm = FileManager.default
        for sub in ["projects", "session-projects"] {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root + "/" + sub),
                                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                hasher.combine(url.path)
                hasher.combine(v?.fileSize ?? -1)
                hasher.combine(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return hasher.finalize()
    }

    private static let lock = NSLock()
    private static var running = false

    /// Run rsync once. Returns `.busy` without starting anything while
    /// another run is in progress.
    static func run(root: String = SessionHost.iMacMirrorRoot()) -> Outcome {
        lock.lock()
        if running { lock.unlock(); return .busy }
        running = true
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }

        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            return .failed("the mirror directory could not be made: \(error.localizedDescription)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rsyncPath)
        process.arguments = rsyncArguments(root: root)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failed("rsync could not start: \(error.localizedDescription)")
        }
        // Read stderr while rsync runs, so a full pipe can never stall it.
        var stderrData = Data()
        let reader = DispatchQueue(label: "com.bbdaniels.loupe.hud.imac-mirror.stderr")
        reader.async { stderrData = errors.fileHandleForReading.readDataToEndOfFile() }
        if finished.wait(timeout: .now() + timeLimit) == .timedOut {
            process.terminate()
            finished.wait()
            reader.sync {}
            return .failed("rsync stopped after \(Int(timeLimit)) s; the mirror keeps what it had")
        }
        reader.sync {}
        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failed("rsync exit \(process.terminationStatus)\(message.isEmpty ? "" : ": " + message)")
        }
        return .synced
    }
}

// MARK: - A gate's live sessions

/// The running Claude Code sessions of one machine, from its gate's `live`
/// verb (`~/bin/pi-gate live`, run here for the MacBook and over ssh for the
/// iMac: `HostProcs.runGate`): the CLI's own `~/.claude/sessions/<pid>.json`
/// records whose process still runs, each checked there against its
/// process's start time, with the tmux session that holds it. Read-only
/// toward both machines. One implementation, the machine its parameter.
///
/// `cached` is what the last fetch returned; `refresh` fetches again off the
/// main thread at most every `interval` seconds, so the Agents poll (every
/// 2 s) never waits on a gate. `fetch` blocks and answers fresh, for the
/// History resume guard. A failed fetch (the iMac asleep, ssh refused, the
/// gate missing) keeps nothing: an empty list, so a stale row never claims a
/// session is running.
enum GateLive {
    static let interval: TimeInterval = 10
    /// The tmux server every gate runs its sessions on (`tmux -L pi-gate`).
    static let tmuxServer = "pi-gate"

    /// The gate's answer, read: each element of `live` as a record. Nil when
    /// the answer is not the gate's (`ok` missing or false).
    static func records(from stdout: Data) -> [ClaudeSessionRecord]? {
        guard let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              obj["ok"] as? Bool == true,
              let live = obj["live"] as? [[String: Any]] else { return nil }
        return live.compactMap {
            (try? JSONSerialization.data(withJSONObject: $0)).flatMap(ClaudeSessionRecords.parse)
        }
    }

    /// The records of `host`'s answer that get a line of their own, in the
    /// gate's order. Everywhere: Ben's interactive sessions, never a service
    /// (the runner's Duet session, `service` from the gate, is not his work:
    /// 2026-11-06, "hide it"), and a session id once.
    ///
    /// The iMac: every such session, with or without a tmux session (one the
    /// phone started has none until a click adopts it). The MacBook: only a
    /// session the gate itself runs, in a tmux session `rc-<name>` of its
    /// own server, since the MacBook's other sessions are listed from their
    /// own sources (a daemon job, a phone-started session) and a terminal
    /// session Ben started by hand is in front of him already. `listed` is
    /// the session ids those sources already gave a live line on that
    /// machine: such a session is left out here, so none is listed twice.
    static func rows(host: SessionHost, records: [ClaudeSessionRecord],
                     listed: Set<String> = []) -> [ClaudeSessionRecord] {
        var seen = listed
        return records.filter { r in
            guard r.kind == "interactive", r.service == nil else { return false }
            if host == .mac {
                guard r.tmuxServer == tmuxServer, let session = r.tmuxSession,
                      session.hasPrefix("rc-"), IMacLauncher.isGateName(session.dropFirst(3)) else { return false }
            }
            return seen.insert(r.sessionId).inserted
        }
    }

    /// One fetch from `host`'s gate. Blocks up to about 10 s: call it off
    /// the main thread.
    static func fetch(_ host: SessionHost) -> [ClaudeSessionRecord]? {
        guard let r = HostProcs.runGate(host, ["live"], timeout: 10), r.status == 0 else { return nil }
        return records(from: r.stdout)
    }

    private struct State {
        var last: [ClaudeSessionRecord] = []
        var answered = false
        var fetchedAt: Date?
        var fetching = false
        /// The `done` of each forced refresh asked for while a fetch ran: they
        /// get a fetch started after it, since that one may predate what they
        /// wait for (a session just started, a link just clicked).
        var waiting: [@Sendable () -> Void] = []
    }

    private static let lock = NSLock()
    private static var states: [SessionHost: State] = [:]

    /// The last fetch's records ([] before the first and after a failure).
    static func cached(_ host: SessionHost) -> [ClaudeSessionRecord] {
        lock.lock(); defer { lock.unlock() }
        return states[host]?.last ?? []
    }

    /// Whether the last fetch had the gate's answer, so an empty `cached`
    /// can be told from a machine that did not answer.
    static func answered(_ host: SessionHost) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return states[host]?.answered ?? false
    }

    /// Start a fetch in the background when the last is older than
    /// `interval` and none is running; `done` runs on the main queue after it.
    /// `force` skips the interval: right after a session starts, so it is
    /// listed in seconds, not ten. A forced refresh while a fetch runs waits
    /// for the next fetch, which starts when that one ends; an unforced one
    /// is dropped, as the poll's next turn asks again.
    static func refresh(_ host: SessionHost, force: Bool = false, done: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        var state = states[host] ?? State()
        if state.fetching {
            if force { state.waiting.append(done); states[host] = state }
            lock.unlock(); return
        }
        if !force && (state.fetchedAt.map { Date().timeIntervalSince($0) < interval } ?? false) {
            lock.unlock(); return
        }
        state.fetching = true
        states[host] = state
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { fetchLoop(host, [done]) }
    }

    private static func fetchLoop(_ host: SessionHost, _ first: [@Sendable () -> Void]) {
        var callers = first
        while true {
            let got = fetch(host)
            lock.lock()
            var state = states[host] ?? State()
            state.last = got ?? []; state.answered = got != nil; state.fetchedAt = Date()
            let next = state.waiting
            state.waiting = []
            if next.isEmpty { state.fetching = false }
            states[host] = state
            lock.unlock()
            let now = callers
            DispatchQueue.main.async { now.forEach { $0() } }
            guard !next.isEmpty else { return }
            callers = next
        }
    }
}
