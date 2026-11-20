import Foundation

// MARK: - A delivery

/// One SendUserFile call of a Claude Code session: the files it sent Ben, as
/// its transcript records them. The Claude app shows a card for each; a
/// terminal shows nothing that can be opened, so Loupe reads the calls from
/// the transcripts of the running sessions and shows the cards itself (Ben,
/// 2026-11-20). The message type is what is read, never a file's extension:
/// any file a session sends is listed and opens in its default app.
///
/// Foundation only (no AppKit), so the tests compile this file directly.
struct FileDelivery: Codable, Equatable, Identifiable, Sendable {
    /// The call's `tool_use` id, unique across sessions.
    let id: String
    let sessionId: String
    /// The machine the session runs on, which is where the files are.
    let host: SessionHost
    /// Absolute paths on `host`.
    let files: [String]
    let caption: String
    let sentAt: Date
    /// The session's name when the call was read, for a card whose session
    /// has since ended and left every list.
    var sessionName: String = ""
}

extension SessionHost: Codable {}

// MARK: - Reading the calls from transcript records

/// The SendUserFile calls in transcript records (JSONL lines). A call is an
/// assistant record whose message content holds
/// `{"type":"tool_use","id":…,"name":"SendUserFile","input":{"files":[…],"caption":…}}`.
/// The tool's name also appears in records that are not calls (the tool
/// list of a request, a deferred-tools attachment, a logged request body),
/// so the record's type and the block's type are both required.
enum FileDeliveryRecord {
    static let toolName = "SendUserFile"

    struct Call: Equatable {
        var id: String
        var files: [String]
        var caption: String
        var sentAt: Date?
    }

    struct Found: Equatable {
        var calls: [Call] = []
        /// The `tool_use` ids whose result was an error: nothing was
        /// delivered (a path that does not exist), so the call gets no card.
        var failed: [String] = []
    }

    private static let callMarker = Data("\"name\":\"\(toolName)\"".utf8)
    private static let errorMarker = Data("\"is_error\":true".utf8)

    /// The calls and failed results in `data`, which must hold whole lines
    /// only (`TranscriptFollow.wholeLines`). A line is parsed only when its
    /// bytes hold one of the two markers, so a megabyte of ordinary records
    /// costs two byte searches a line.
    static func read(_ data: Data) -> Found {
        var found = Found()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let isCall = line.range(of: callMarker) != nil
            guard isCall || line.range(of: errorMarker) != nil,
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            switch json["type"] as? String {
            case "assistant" where isCall:
                let cwd = json["cwd"] as? String
                let sentAt = ClaudeProcessSnapshot.parseDate(json["timestamp"])
                for block in blocks {
                    guard block["type"] as? String == "tool_use", block["name"] as? String == toolName,
                          let id = block["id"] as? String, !id.isEmpty,
                          let input = block["input"] as? [String: Any],
                          let files = input["files"] as? [String] else { continue }
                    let paths = files.compactMap { absolute($0, cwd: cwd) }
                    guard !paths.isEmpty else { continue }
                    found.calls.append(Call(id: id, files: paths,
                                            caption: (input["caption"] as? String ?? "")
                                                .trimmingCharacters(in: .whitespacesAndNewlines),
                                            sentAt: sentAt))
                }
            case "user":
                for block in blocks where block["type"] as? String == "tool_result" && block["is_error"] as? Bool == true {
                    if let id = block["tool_use_id"] as? String { found.failed.append(id) }
                }
            default:
                continue
            }
        }
        return found
    }

    /// A path of the call as an absolute one: the tool takes paths relative
    /// to the session's working directory, which the record names. Nil for
    /// an empty path, and for a relative one in a record with no directory.
    static func absolute(_ path: String, cwd: String?) -> String? {
        if path.hasPrefix("/") { return path }
        guard !path.isEmpty, let cwd, cwd.hasPrefix("/") else { return nil }
        return (cwd.hasSuffix("/") ? cwd : cwd + "/") + path
    }

    /// `Loupe --file-deliveries <transcript.jsonl>`: every call the transcript
    /// holds, one block each, read the way the follower reads it (whole
    /// lines of a chunk at a time). For checking the reader against a real
    /// transcript; read-only.
    static func report(path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "cannot read \(path)\n" }
        defer { try? handle.close() }
        var calls: [Call] = []
        var failed = Set<String>()
        var pending = Data()
        while true {
            let chunk = handle.readData(ofLength: 4 << 20)
            pending.append(chunk)
            let whole = chunk.isEmpty ? pending.count : TranscriptFollow.wholeLines(in: pending, filled: false)
            let found = read(pending.prefix(whole))
            calls += found.calls
            failed.formUnion(found.failed)
            if chunk.isEmpty { break }
            pending = Data(pending.dropFirst(whole))
        }
        let stamp = ISO8601DateFormatter()
        var out = ""
        for call in calls where !failed.contains(call.id) {
            out += "\(call.sentAt.map(stamp.string(from:)) ?? "no time")  \(call.id)\n"
            if !call.caption.isEmpty { out += "  \(call.caption)\n" }
            for file in call.files { out += "  \(file)\n" }
        }
        let delivered = calls.filter { !failed.contains($0.id) }.count
        return out + "\(delivered) call\(delivered == 1 ? "" : "s"), \(failed.intersection(calls.map(\.id)).count) failed\n"
    }
}

// MARK: - Following a transcript

/// Reading the new bytes of the running sessions' transcripts, where each
/// one lives: the MacBook's from its own disk, the iMac's over one ssh for
/// all of them. Only what was appended since the last read crosses, so a
/// 250 MB transcript costs what it grew by. Read-only toward both machines.
///
/// The iMac's mirror (`IMacMirror`) is not the source: it is refreshed once
/// a minute by an rsync that reads each grown transcript whole on both
/// sides, which is right for History and too slow and too heavy for a
/// notice that a file has just arrived.
enum TranscriptFollow {
    /// The most one read takes from one transcript; a longer backlog is
    /// read over the next polls.
    static let readLimit = 32 << 20
    /// A transcript met for the first time is read from its start when it
    /// is no larger than this (a session that has just begun), and from its
    /// end otherwise (a long one already under way: its history is not
    /// resurfaced, nor pulled across).
    static let firstReadLimit = 8 << 20

    /// A transcript to read: `offset` is where the last read stopped, nil
    /// when it has never been read. `localPath` is the MacBook's file; the
    /// iMac's is found there by its session id.
    struct Target: Equatable, Sendable {
        var host: SessionHost
        var sessionId: String
        var offset: Int?
        var localPath: String? = nil
    }

    /// What one read returned: the transcript's size, and `bytes`, which
    /// begin at `start` in it.
    struct Chunk: Equatable, Sendable {
        var host: SessionHost
        var sessionId: String
        var size: Int
        var start: Int
        var bytes: Data
        /// True when the transcript had never been read before.
        var first: Bool
    }

    /// A session id as Claude Code writes one (a UUID): the only form that
    /// goes into the iMac's command line.
    static func isSessionId(_ s: String) -> Bool {
        (8...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Where a read of a transcript of `size` bytes starts and how many
    /// bytes it takes. One rule for both machines; the iMac's script
    /// (`remoteScript`) states the same rule in shell.
    static func span(size: Int, offset: Int?) -> (start: Int, count: Int) {
        guard let offset else {
            return size <= firstReadLimit ? (0, size) : (size, 0)
        }
        // A transcript shorter than where the last read stopped was
        // replaced: nothing of it is known, so it is followed from its end.
        guard offset <= size else { return (size, 0) }
        return (offset, min(size - offset, readLimit))
    }

    /// The length of the whole lines at the start of `bytes`: through its
    /// last newline, so a record still being written is left for the next
    /// read. A read that filled its limit without one newline is passed
    /// whole (`filled`), or a single record longer than the limit would be
    /// read again forever.
    static func wholeLines(in bytes: Data, filled: Bool) -> Int {
        if let newline = bytes.lastIndex(of: 0x0A) { return bytes.distance(from: bytes.startIndex, to: newline) + 1 }
        return filled ? bytes.count : 0
    }

    // MARK: The MacBook's transcripts

    static func readLocal(_ target: Target) -> Chunk? {
        guard let path = target.localPath, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let (start, count) = span(size: Int(end), offset: target.offset)
        var bytes = Data()
        if count > 0 {
            guard (try? handle.seek(toOffset: UInt64(start))) != nil else { return nil }
            bytes = handle.readData(ofLength: count)
        }
        return Chunk(host: target.host, sessionId: target.sessionId, size: Int(end), start: start,
                     bytes: bytes, first: target.offset == nil)
    }

    // MARK: The iMac's transcripts

    /// What the iMac's shell runs, with one `<session id>:<offset>` argument
    /// a transcript (offset -1 for one never read). For each transcript it
    /// finds (the newest `<id>.jsonl` under `~/.claude/projects`), one
    /// header line, `transcript <id> <size> <start> <count>`, then exactly
    /// `count` bytes of it from `start`. The spans are `span`'s.
    static let remoteScript = """
        for a in "$@"; do
          sid=${a%%:*}; off=${a##*:}
          f=$(ls -t "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -n 1)
          [ -n "$f" ] || continue
          size=$(stat -c %s "$f") || continue
          start=$off; n=0
          if [ "$off" -lt 0 ]; then
            if [ "$size" -le \(firstReadLimit) ]; then start=0; n=$size; else start=$size; fi
          elif [ "$off" -gt "$size" ]; then start=$size
          else n=$((size - off)); [ "$n" -le \(readLimit) ] || n=\(readLimit)
          fi
          printf 'transcript %s %s %s %s\\n' "$sid" "$size" "$start" "$n"
          [ "$n" -gt 0 ] && tail -c +"$((start + 1))" "$f" | head -c "$n"
        done
        exit 0
        """

    static func remoteArguments(_ targets: [Target]) -> [String] {
        let args = targets.filter { isSessionId($0.sessionId) }.map { "\($0.sessionId):\($0.offset ?? -1)" }
        let command = (["sh", "-c", remoteScript, "loupe-follow"] + args)
            .map(IMacLauncher.shellQuote).joined(separator: " ")
        return ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", IMacLauncher.sshHost, command]
    }

    /// The script's output, read: each header and the bytes after it. A
    /// header that does not read as one, or bytes cut short (the ssh ended
    /// early), end the reading there; what was whole before it is kept.
    static func chunks(fromRemote output: Data, targets: [Target]) -> [Chunk] {
        let asked = Dictionary(targets.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        var chunks: [Chunk] = []
        var rest = output[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            let fields = String(decoding: rest[..<newline], as: UTF8.self).split(separator: " ")
            guard fields.count == 5, fields[0] == "transcript", let target = asked[String(fields[1])],
                  let size = Int(fields[2]), let start = Int(fields[3]), let count = Int(fields[4]),
                  size >= 0, start >= 0, count >= 0 else { break }
            let body = rest[rest.index(after: newline)...]
            guard body.count >= count else { break }
            chunks.append(Chunk(host: .iMac, sessionId: target.sessionId, size: size, start: start,
                                bytes: Data(body.prefix(count)), first: target.offset == nil))
            rest = body.dropFirst(count)
        }
        return chunks
    }

    /// One ssh for every iMac transcript in `targets`. Blocks up to
    /// `timeout`: call it off the main thread. Nil when the iMac does not
    /// answer; the offsets then stay where they were and the next poll
    /// reads the same span.
    static func readRemote(_ targets: [Target], timeout: TimeInterval = 60) -> [Chunk]? {
        let targets = targets.filter { isSessionId($0.sessionId) }
        guard !targets.isEmpty else { return [] }
        guard let result = run("/usr/bin/ssh", remoteArguments(targets), timeout: timeout),
              result.status == 0 else { return nil }
        return chunks(fromRemote: result.stdout, targets: targets)
    }

    /// Every target read where it lives, and the machines that answered.
    static func read(_ targets: [Target]) -> (chunks: [Chunk], answered: Set<SessionHost>) {
        let local = targets.filter { $0.host == .mac }.compactMap(readLocal)
        guard let remote = readRemote(targets.filter { $0.host == .iMac }) else { return (local, [.mac]) }
        return (local + remote, [.mac, .iMac])
    }

    /// A process run to its end or to `timeout`, its output collected.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                    stdout: FileHandle? = nil) -> (status: Int32, stdout: Data, stderr: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout ?? output
        process.standardError = errors
        do { try process.run() } catch { return nil }
        let group = DispatchGroup()
        var data = Data(), errorData = Data()
        if stdout == nil {
            DispatchQueue.global(qos: .utility).async(group: group) {
                data = output.fileHandleForReading.readDataToEndOfFile()
            }
        }
        DispatchQueue.global(qos: .utility).async(group: group) {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            group.wait()
        }
        process.waitUntilExit()
        return (process.terminationStatus, data,
                String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - The log

/// What Loupe knows of the files sent: where the reading of each transcript
/// has got to, and the deliveries that have a card. Kept on disk
/// (`FileDeliveryLog.url`), so a relaunch (every install is one) picks each
/// transcript up where it stopped and keeps the cards.
struct FileDeliveryLog: Codable, Equatable {
    struct Tail: Codable, Equatable {
        var offset: Int
        /// When the transcript was last read, for dropping the entry of a
        /// session long gone.
        var read: Date
    }

    /// Keyed by `key(host, sessionId)`.
    var tails: [String: Tail] = [:]
    /// Newest first.
    var deliveries: [FileDelivery] = []
    /// When each machine's transcripts were last read (keyed by the host's
    /// raw value): what a session sent after that is news, even in a
    /// transcript met for the first time (a session started and done while
    /// this Mac slept).
    var watched: [String: Date] = [:]

    /// A card stays this long unless Ben dismisses it, and the newest
    /// `keepCount` at most.
    static let keepFor: TimeInterval = 7 * 86400
    static let keepCount = 40
    static let forgetTailAfter: TimeInterval = 30 * 86400
    /// On a transcript's first read, a call sent more than this long
    /// before its machine was last read is history, not news: it gets no
    /// card. (Before the first read of all, "last read" is now.)
    static let firstReadWindow: TimeInterval = 120

    static func key(_ host: SessionHost, _ sessionId: String) -> String { host.rawValue + ":" + sessionId }

    func offset(_ host: SessionHost, _ sessionId: String) -> Int? { tails[Self.key(host, sessionId)]?.offset }

    /// Take in one read: move the transcript's offset past the whole lines
    /// read, add a card for each call in them, and drop the card of a call
    /// whose result was an error. True when the cards changed.
    mutating func apply(_ chunk: TranscriptFollow.Chunk, sessionName: String = "", now: Date = Date()) -> Bool {
        let whole = TranscriptFollow.wholeLines(in: chunk.bytes, filled: chunk.bytes.count >= TranscriptFollow.readLimit)
        tails[Self.key(chunk.host, chunk.sessionId)] = Tail(offset: chunk.start + whole, read: now)
        guard whole > 0 else { return false }
        let found = FileDeliveryRecord.read(chunk.bytes.prefix(whole))
        let newsSince = (watched[chunk.host.rawValue] ?? now).addingTimeInterval(-Self.firstReadWindow)
        var changed = false
        for call in found.calls where !found.failed.contains(call.id) {
            let sentAt = call.sentAt ?? now
            if chunk.first, sentAt < newsSince { continue }
            guard !deliveries.contains(where: { $0.id == call.id }) else { continue }
            deliveries.append(FileDelivery(id: call.id, sessionId: chunk.sessionId, host: chunk.host,
                                           files: call.files, caption: call.caption, sentAt: sentAt,
                                           sessionName: sessionName))
            changed = true
        }
        let before = deliveries.count
        deliveries.removeAll { found.failed.contains($0.id) }
        changed = changed || deliveries.count != before
        if changed { deliveries.sort { $0.sentAt > $1.sentAt } }
        return changed
    }

    /// Drop the cards past their time or count, and the offsets of
    /// transcripts not read for a month. Returns the ids of the cards dropped.
    mutating func prune(now: Date = Date()) -> [String] {
        var dropped: [String] = []
        var kept: [FileDelivery] = []
        for d in deliveries {
            if kept.count < Self.keepCount, now.timeIntervalSince(d.sentAt) <= Self.keepFor { kept.append(d) }
            else { dropped.append(d.id) }
        }
        deliveries = kept
        tails = tails.filter { now.timeIntervalSince($0.value.read) <= Self.forgetTailAfter }
        return dropped
    }

    mutating func dismiss(_ id: String) {
        deliveries.removeAll { $0.id == id }
    }

    // MARK: On disk

    static func url(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home + "/Library/Application Support/Loupe/file-deliveries.json")
    }

    static func load(from url: URL = url()) -> FileDeliveryLog {
        guard let data = try? Data(contentsOf: url) else { return FileDeliveryLog() }
        return (try? decoder.decode(FileDeliveryLog.self, from: data)) ?? FileDeliveryLog()
    }

    func save(to url: URL = url()) {
        guard let data = try? Self.encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

// MARK: - A local copy to open

/// The file of a delivery as a file on this Mac: the path itself for a
/// MacBook session, and for an iMac session a copy fetched over ssh, afresh
/// each time (the session may have rewritten it), into
/// `~/Library/Caches/Loupe/deliveries/<call id>/<file name>`.
enum FileDeliveryFetch {
    /// Longest a fetch may take, connection included.
    static let timeLimit: TimeInterval = 180

    enum Outcome: Equatable {
        case ready(URL)
        case failed(String)
    }

    static func cacheRoot(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home + "/Library/Caches/Loupe/deliveries", isDirectory: true)
    }

    /// The folder holding the copies of one delivery's files. The call id
    /// names it, with anything but letters, digits, "-" and "_" replaced.
    static func cacheFolder(_ delivery: FileDelivery, home: String = NSHomeDirectory()) -> URL {
        let name = String(delivery.id.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
        return cacheRoot(home: home).appendingPathComponent(name.isEmpty ? "_" : name, isDirectory: true)
    }

    /// Where the copy of `file` goes. Two files of one delivery with the
    /// same name (from two folders) get a folder each, by their place in
    /// the call, so neither overwrites the other.
    static func copyURL(_ delivery: FileDelivery, file: String, home: String = NSHomeDirectory()) -> URL {
        let name = (file as NSString).lastPathComponent
        var folder = cacheFolder(delivery, home: home)
        let same = delivery.files.filter { ($0 as NSString).lastPathComponent == name }
        if same.count > 1, let index = delivery.files.firstIndex(of: file) {
            folder.appendPathComponent(String(index + 1), isDirectory: true)
        }
        return folder.appendingPathComponent(name.isEmpty ? "file" : name)
    }

    /// ssh's arguments for reading `path` on the iMac to standard output.
    static func sshArguments(path: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", IMacLauncher.sshHost,
         "cat -- " + IMacLauncher.shellQuote(path)]
    }

    /// Why a fetch failed, from ssh's exit status and what it wrote to
    /// standard error.
    static func failure(status: Int32, stderr: String) -> String {
        if status == 255 { return "The iMac did not answer" }
        if stderr.contains("No such file or directory") { return "The file is no longer on the iMac" }
        if stderr.contains("Permission denied") { return "The iMac refused to read the file" }
        if stderr.contains("Is a directory") { return "It is a folder on the iMac, not a file" }
        return stderr.isEmpty ? "The copy from the iMac failed (exit \(status))" : stderr
    }

    /// Blocks until the file is here or the fetch has failed: call it off
    /// the main thread.
    static func localCopy(_ delivery: FileDelivery, file: String, home: String = NSHomeDirectory()) -> Outcome {
        let fm = FileManager.default
        switch delivery.host {
        case .mac:
            return fm.fileExists(atPath: file) ? .ready(URL(fileURLWithPath: file))
                                               : .failed("The file is no longer there")
        case .iMac:
            let target = copyURL(delivery, file: file, home: home)
            let partial = target.appendingPathExtension("partial")
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: partial)
                guard fm.createFile(atPath: partial.path, contents: nil) else {
                    return .failed("The copy could not be written to the cache")
                }
                let handle = try FileHandle(forWritingTo: partial)
                let result = TranscriptFollow.run("/usr/bin/ssh", sshArguments(path: file),
                                                  timeout: timeLimit, stdout: handle)
                try? handle.close()
                guard let result else {
                    try? fm.removeItem(at: partial)
                    return .failed("ssh could not start")
                }
                guard result.status == 0 else {
                    try? fm.removeItem(at: partial)
                    return .failed(failure(status: result.status, stderr: result.stderr))
                }
                try? fm.removeItem(at: target)
                try fm.moveItem(at: partial, to: target)
                return .ready(target)
            } catch {
                try? fm.removeItem(at: partial)
                return .failed("The copy could not be written to the cache: \(error.localizedDescription)")
            }
        }
    }

    /// Remove the cached copies of deliveries that no longer have a card:
    /// every folder of the cache not named by one of `kept`.
    static func sweep(keeping kept: [FileDelivery], home: String = NSHomeDirectory()) {
        let fm = FileManager.default
        let keep = Set(kept.map { cacheFolder($0, home: home).lastPathComponent })
        let folders = (try? fm.contentsOfDirectory(at: cacheRoot(home: home), includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !keep.contains(folder.lastPathComponent) {
            try? fm.removeItem(at: folder)
        }
    }
}
