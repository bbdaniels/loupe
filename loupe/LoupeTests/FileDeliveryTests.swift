import XCTest

/// The files a session sends with SendUserFile: reading the calls from
/// transcript records (`FileDeliveryRecord`), following a transcript as it
/// grows (`TranscriptFollow`), the cards kept (`FileDeliveryLog`) and where a
/// copy of an iMac file goes (`FileDeliveryFetch`).
final class FileDeliveryTests: XCTestCase {

    // MARK: Records

    /// A call as Claude Code 2.1.325 wrote it on 2026-11-18 (the usage and
    /// request fields cut), and the result that followed it.
    private let realCall = #"{"parentUuid":"ea7b89ec","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_011C","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01CBKCevgqGWE9kTBHSmk3Di","name":"SendUserFile","input":{"files":["/tmp/scratchpad/packet-sticker-draft.pdf","/tmp/scratchpad/syllabus-sticker-draft.pdf"],"caption":"Sticker-theme drafts: the packet and the syllabus","status":"normal","display":"render"},"caller":{"type":"direct"}}],"stop_reason":"tool_use"},"requestId":"req_01","type":"assistant","uuid":"1565b160","timestamp":"2026-11-18T04:18:58.801Z","userType":"external","entrypoint":"cli","cwd":"/home/bbdaniels/Projects/ppol-6818-instructor","sessionId":"91389ce6-7b92-409e-8391-9f8d4e52465e","version":"2.1.325","gitBranch":"main"}"#
    private let realResult = #"{"parentUuid":"ee2c24d4","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01CBKCevgqGWE9kTBHSmk3Di","type":"tool_result","content":"2 files delivered to user.\n  /tmp/scratchpad/packet-sticker-draft.pdf → file_uuid: 1d47e088"}]},"uuid":"3246f320","timestamp":"2026-11-18T04:18:59.107Z"}"#

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func call(id: String, files: [String], caption: String? = "A caption",
                      timestamp: String = "2026-11-20T15:00:00.000Z", cwd: String = "/home/bbdaniels/Projects/a",
                      tool: String = "SendUserFile") -> String {
        var input: [String: Any] = ["files": files, "status": "normal"]
        if let caption { input["caption"] = caption }
        return line(["type": "assistant", "timestamp": timestamp, "cwd": cwd,
                     "message": ["role": "assistant",
                                 "content": [["type": "text", "text": "Here it is."],
                                             ["type": "tool_use", "id": id, "name": tool, "input": input]]]])
    }

    private func result(of id: String, error: Bool) -> String {
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": "x"]
        if error { block["is_error"] = true }
        return line(["type": "user", "message": ["role": "user", "content": [block]]])
    }

    private func data(_ lines: [String], partial: String = "") -> Data {
        Data((lines.map { $0 + "\n" }.joined() + partial).utf8)
    }

    func testASendUserFileCallIsRead() {
        let found = FileDeliveryRecord.read(data([realCall, realResult]))
        XCTAssertEqual(found.failed, [])
        XCTAssertEqual(found.calls.count, 1)
        let call = found.calls[0]
        XCTAssertEqual(call.id, "toolu_01CBKCevgqGWE9kTBHSmk3Di")
        XCTAssertEqual(call.files, ["/tmp/scratchpad/packet-sticker-draft.pdf", "/tmp/scratchpad/syllabus-sticker-draft.pdf"])
        XCTAssertEqual(call.caption, "Sticker-theme drafts: the packet and the syllabus")
        XCTAssertEqual(call.sentAt.map { Int($0.timeIntervalSince1970) }, 1_794_975_538)
    }

    func testAnyFileTypeAndSeveralCallsInOneRecordAreRead() {
        let two = line(["type": "assistant", "cwd": "/w",
                        "message": ["content": [
                            ["type": "tool_use", "id": "a", "name": "SendUserFile",
                             "input": ["files": ["/x/report.docx", "/x/data.csv", "/x/no-extension"]]],
                            ["type": "tool_use", "id": "b", "name": "SendUserFile",
                             "input": ["files": ["/x/page.html"], "caption": "  spaced  "]]]]])
        let found = FileDeliveryRecord.read(data([two]))
        XCTAssertEqual(found.calls.map(\.id), ["a", "b"])
        XCTAssertEqual(found.calls[0].files, ["/x/report.docx", "/x/data.csv", "/x/no-extension"])
        XCTAssertEqual(found.calls[0].caption, "", "a call without a caption has an empty one")
        XCTAssertNil(found.calls[0].sentAt)
        XCTAssertEqual(found.calls[1].caption, "spaced")
    }

    func testOtherToolCallsAndMentionsOfTheToolAreIgnored() {
        let lines = [
            // Another tool's call, with files of its own.
            call(id: "r1", files: ["/x/a.pdf"], tool: "Read"),
            // The tool listed in a request's shape, and in a deferred-tools
            // attachment: its name, but no call.
            line(["type": "api-request-shape", "shape": ["tools": [["name": "SendUserFile", "description": "Send files"]]]]),
            line(["isSidechain": false, "attachment": ["type": "deferred_tools_record",
                                                         "entries": [["name": "SendUserFile"]]]]),
            // A logged request body that repeats a call: not an assistant record.
            line(["type": "api-request-blob",
                  "message": ["role": "assistant",
                              "content": [["type": "tool_use", "id": "blob", "name": "SendUserFile",
                                           "input": ["files": ["/x/b.pdf"]]]]]]),
            // A person's message that quotes the call.
            line(["type": "user", "message": ["role": "user", "content": #"{"type":"tool_use","name":"SendUserFile"}"#]]),
            // Text of the assistant that names the tool.
            line(["type": "assistant", "message": ["content": [["type": "text", "text": #"I call "name":"SendUserFile" next"#]]]]),
            // A call with no usable file.
            call(id: "empty", files: []),
            // Not JSON at all.
            #"garbage "name":"SendUserFile" {"#,
        ]
        XCTAssertEqual(FileDeliveryRecord.read(data(lines)), FileDeliveryRecord.Found())
    }

    func testARelativePathIsResolvedAgainstTheRecordsDirectory() {
        let found = FileDeliveryRecord.read(data([call(id: "a", files: ["out/fig.png", "/abs/b.pdf", ""], cwd: "/home/b/Projects/p")]))
        XCTAssertEqual(found.calls.first?.files, ["/home/b/Projects/p/out/fig.png", "/abs/b.pdf"])
        XCTAssertNil(FileDeliveryRecord.absolute("out/fig.png", cwd: nil))
        XCTAssertEqual(FileDeliveryRecord.absolute("fig.png", cwd: "/w/"), "/w/fig.png")
    }

    func testAFailedCallIsReported() {
        let found = FileDeliveryRecord.read(data([call(id: "bad", files: ["/x/missing.pdf"]), result(of: "bad", error: true),
                                                   call(id: "good", files: ["/x/there.pdf"]), result(of: "good", error: false)]))
        XCTAssertEqual(found.calls.map(\.id), ["bad", "good"])
        XCTAssertEqual(found.failed, ["bad"])
    }

    // MARK: Following

    func testOnlyWholeLinesAreTaken() {
        XCTAssertEqual(TranscriptFollow.wholeLines(in: Data("ab\ncd\nef".utf8), filled: false), 6)
        XCTAssertEqual(TranscriptFollow.wholeLines(in: Data("ab\n".utf8), filled: false), 3)
        XCTAssertEqual(TranscriptFollow.wholeLines(in: Data("no newline yet".utf8), filled: false), 0)
        XCTAssertEqual(TranscriptFollow.wholeLines(in: Data("no newline".utf8), filled: true), 10,
                       "a record longer than a whole read is passed over, not read again forever")
        XCTAssertEqual(TranscriptFollow.wholeLines(in: Data(), filled: false), 0)
        let slice = Data("xx\nab\ncd".utf8).dropFirst(3)
        XCTAssertEqual(TranscriptFollow.wholeLines(in: slice, filled: false), 3, "counted from the slice's own start")
    }

    func testAPartialLastLineWaitsForItsEnd() {
        let first = call(id: "one", files: ["/x/one.pdf"])
        let second = call(id: "two", files: ["/x/two.pdf"])
        let cut = second.index(second.startIndex, offsetBy: second.count / 2)
        let now = Date(timeIntervalSince1970: 1_795_100_000)
        var log = FileDeliveryLog()
        log.tails[FileDeliveryLog.key(.iMac, "s")] = .init(offset: 100, read: now)

        // The transcript ends inside the second call's record.
        let head = data([first], partial: String(second[..<cut]))
        XCTAssertTrue(log.apply(.init(host: .iMac, sessionId: "s", size: 100 + head.count, start: 100, bytes: head, first: false), now: now))
        XCTAssertEqual(log.deliveries.map(\.id), ["one"])
        let offset = log.offset(.iMac, "s")
        XCTAssertEqual(offset, 100 + first.utf8.count + 1, "the offset stops after the last whole line")

        // The next read starts there and has the record whole.
        let rest = data([second])
        XCTAssertTrue(log.apply(.init(host: .iMac, sessionId: "s", size: offset! + rest.count, start: offset!, bytes: rest, first: false), now: now))
        XCTAssertEqual(Set(log.deliveries.map(\.id)), ["one", "two"])
        XCTAssertEqual(log.offset(.iMac, "s"), offset! + rest.count)

        // Read again from the same place (the ssh was cut before the offset
        // was kept): no second card.
        XCTAssertFalse(log.apply(.init(host: .iMac, sessionId: "s", size: offset! + rest.count, start: offset!, bytes: rest, first: false), now: now))
        XCTAssertEqual(log.deliveries.count, 2)
    }

    func testWhereAReadStarts() {
        let small = TranscriptFollow.firstReadLimit, big = small + 1
        XCTAssertTrue(TranscriptFollow.span(size: small, offset: nil) == (0, small), "a new session's transcript is read whole")
        XCTAssertTrue(TranscriptFollow.span(size: big, offset: nil) == (big, 0), "a long one is followed from its end")
        XCTAssertTrue(TranscriptFollow.span(size: 500, offset: 200) == (200, 300))
        XCTAssertTrue(TranscriptFollow.span(size: 500, offset: 500) == (500, 0))
        XCTAssertTrue(TranscriptFollow.span(size: 100, offset: 500) == (100, 0), "a replaced transcript is followed from its end")
        let limit = TranscriptFollow.readLimit
        XCTAssertTrue(TranscriptFollow.span(size: limit * 3, offset: 10) == (10, limit), "a backlog is read a limit at a time")
    }

    func testTheMacBooksTranscriptIsReadFromItsOffset() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.jsonl").path
        try Data("first\nsecond\n".utf8).write(to: URL(fileURLWithPath: path))

        var target = TranscriptFollow.Target(host: .mac, sessionId: "s", offset: nil, localPath: path)
        let whole = try XCTUnwrap(TranscriptFollow.readLocal(target))
        XCTAssertEqual(whole, .init(host: .mac, sessionId: "s", size: 13, start: 0, bytes: Data("first\nsecond\n".utf8), first: true))
        target.offset = 6
        XCTAssertEqual(TranscriptFollow.readLocal(target),
                       .init(host: .mac, sessionId: "s", size: 13, start: 6, bytes: Data("second\n".utf8), first: false))
        target.offset = 13
        XCTAssertEqual(TranscriptFollow.readLocal(target)?.bytes, Data())
        target.localPath = dir.appendingPathComponent("missing.jsonl").path
        XCTAssertNil(TranscriptFollow.readLocal(target))
    }

    func testTheIMacsAnswerIsReadHeaderByHeader() {
        let a = "11111111-aaaa-4bbb-8ccc-000000000001", b = "11111111-aaaa-4bbb-8ccc-000000000002"
        let targets = [TranscriptFollow.Target(host: .iMac, sessionId: a, offset: 4),
                       TranscriptFollow.Target(host: .iMac, sessionId: b, offset: nil)]
        var out = Data("transcript \(a) 10 4 6\n".utf8)
        out.append(Data("ab\ncd\n".utf8))
        out.append(Data("transcript \(b) 9000000 9000000 0\n".utf8))
        XCTAssertEqual(TranscriptFollow.chunks(fromRemote: out, targets: targets), [
            .init(host: .iMac, sessionId: a, size: 10, start: 4, bytes: Data("ab\ncd\n".utf8), first: false),
            .init(host: .iMac, sessionId: b, size: 9_000_000, start: 9_000_000, bytes: Data(), first: true),
        ])

        // Bytes that begin with the word of a header are still bytes.
        var tricky = Data("transcript \(a) 30 4 26\n".utf8)
        tricky.append(Data("transcript x 1 1 1\nyy\nzz\n\n".utf8))
        XCTAssertEqual(TranscriptFollow.chunks(fromRemote: tricky, targets: targets).map(\.bytes),
                       [Data("transcript x 1 1 1\nyy\nzz\n\n".utf8)])

        // An answer cut short keeps what was whole before the cut.
        var short = Data("transcript \(a) 10 4 6\nab\ncd\n".utf8)
        short.append(Data("transcript \(b) 50 0 50\nonly this much".utf8))
        XCTAssertEqual(TranscriptFollow.chunks(fromRemote: short, targets: targets).map(\.sessionId), [a])
        XCTAssertEqual(TranscriptFollow.chunks(fromRemote: Data("bash: no such thing\n".utf8), targets: targets), [])
        XCTAssertEqual(TranscriptFollow.chunks(fromRemote: Data("transcript other 1 0 0\n".utf8), targets: targets), [],
                       "a transcript that was not asked for ends the reading")
    }

    func testOnlySessionIdsReachTheIMacsCommandLine() {
        let good = "11111111-aaaa-4bbb-8ccc-000000000001"
        XCTAssertTrue(TranscriptFollow.isSessionId(good))
        for bad in ["", "short", "a; rm -rf ~", "$(reboot)-aaaa-bbbb", "11111111/../x", "11111111 aaaa", "*-*-*-*-*******"] {
            XCTAssertFalse(TranscriptFollow.isSessionId(bad), bad)
        }
        let args = TranscriptFollow.remoteArguments([
            .init(host: .iMac, sessionId: good, offset: 42),
            .init(host: .iMac, sessionId: "x'; reboot; '", offset: 1),
            .init(host: .iMac, sessionId: good.replacingOccurrences(of: "1", with: "2"), offset: nil),
        ])
        XCTAssertEqual(Array(args.prefix(5)), ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "imac"])
        let command = args[5]
        XCTAssertTrue(command.hasPrefix("'sh' '-c' '"))
        XCTAssertTrue(command.hasSuffix("' 'loupe-follow' '\(good):42' '22222222-aaaa-4bbb-8ccc-000000000002:-1'"))
        XCTAssertFalse(command.contains("reboot"))
        XCTAssertTrue(TranscriptFollow.remoteScript.contains("-le \(TranscriptFollow.firstReadLimit) "))
        XCTAssertTrue(TranscriptFollow.remoteScript.contains("n=\(TranscriptFollow.readLimit)"))
    }

    // MARK: The log

    func testAFirstReadGivesCardsOnlyToWhatIsNew() {
        let now = Date(timeIntervalSince1970: 1_795_100_000)
        func stamp(_ secondsAgo: TimeInterval) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: now.addingTimeInterval(-secondsAgo))
        }
        let bytes = data([call(id: "yesterday", files: ["/x/a.pdf"], timestamp: stamp(86_400)),
                          call(id: "an-hour-ago", files: ["/x/b.pdf"], timestamp: stamp(3_600)),
                          call(id: "just-now", files: ["/x/c.pdf"], timestamp: stamp(20))])
        func chunk(first: Bool) -> TranscriptFollow.Chunk {
            .init(host: .iMac, sessionId: "s", size: bytes.count, start: 0, bytes: bytes, first: first)
        }

        // Loupe has never read the iMac: only what was sent just now is news.
        var fresh = FileDeliveryLog()
        XCTAssertTrue(fresh.apply(chunk(first: true), sessionName: "Week 2 sheets", now: now))
        XCTAssertEqual(fresh.deliveries.map(\.id), ["just-now"])
        XCTAssertEqual(fresh.deliveries[0].sessionName, "Week 2 sheets")
        XCTAssertEqual(fresh.deliveries[0].host, .iMac)
        XCTAssertEqual(fresh.offset(.iMac, "s"), bytes.count)

        // It last read the iMac two hours ago (this Mac slept since): a
        // session started and done meanwhile still gets its cards.
        var slept = FileDeliveryLog()
        slept.watched[SessionHost.iMac.rawValue] = now.addingTimeInterval(-7_200)
        XCTAssertTrue(slept.apply(chunk(first: true), now: now))
        XCTAssertEqual(slept.deliveries.map(\.id), ["just-now", "an-hour-ago"], "newest first")

        // A transcript already followed is never filtered by age.
        var followed = FileDeliveryLog()
        XCTAssertTrue(followed.apply(chunk(first: false), now: now))
        XCTAssertEqual(followed.deliveries.count, 3)
    }

    func testAFailedCallGetsNoCardAndLosesTheOneItHad() {
        let now = Date(timeIntervalSince1970: 1_795_100_000)
        var log = FileDeliveryLog()
        // The call and its error in one read: never a card.
        let both = data([call(id: "bad", files: ["/x/missing.pdf"]), result(of: "bad", error: true)])
        XCTAssertFalse(log.apply(.init(host: .mac, sessionId: "s", size: both.count, start: 0, bytes: both, first: false), now: now))
        XCTAssertEqual(log.deliveries, [])
        // The call in one read, its error in the next: the card goes.
        let callOnly = data([call(id: "late", files: ["/x/missing.pdf"])])
        XCTAssertTrue(log.apply(.init(host: .mac, sessionId: "s", size: 0, start: both.count, bytes: callOnly, first: false), now: now))
        XCTAssertEqual(log.deliveries.map(\.id), ["late"])
        let error = data([result(of: "late", error: true)])
        XCTAssertTrue(log.apply(.init(host: .mac, sessionId: "s", size: 0, start: both.count + callOnly.count, bytes: error, first: false), now: now))
        XCTAssertEqual(log.deliveries, [])
    }

    func testOldCardsAndOffsetsAreDropped() {
        let now = Date(timeIntervalSince1970: 1_795_100_000)
        var log = FileDeliveryLog()
        func card(_ id: String, age: TimeInterval) -> FileDelivery {
            FileDelivery(id: id, sessionId: "s", host: .mac, files: ["/x"], caption: "", sentAt: now.addingTimeInterval(-age))
        }
        log.deliveries = [card("new", age: 60), card("week", age: FileDeliveryLog.keepFor - 1), card("old", age: FileDeliveryLog.keepFor + 1)]
        log.tails = ["mac:a": .init(offset: 1, read: now), "mac:b": .init(offset: 2, read: now.addingTimeInterval(-FileDeliveryLog.forgetTailAfter - 1))]
        XCTAssertEqual(log.prune(now: now), ["old"])
        XCTAssertEqual(log.deliveries.map(\.id), ["new", "week"])
        XCTAssertEqual(Array(log.tails.keys), ["mac:a"])

        log.deliveries = (0..<FileDeliveryLog.keepCount + 5).map { card("c\($0)", age: Double($0)) }
        XCTAssertEqual(log.prune(now: now).count, 5)
        XCTAssertEqual(log.deliveries.last?.id, "c\(FileDeliveryLog.keepCount - 1)", "the newest are the ones kept")

        log.dismiss("c0")
        XCTAssertFalse(log.deliveries.contains { $0.id == "c0" })
    }

    func testTheLogSurvivesARelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Loupe/file-deliveries.json")
        XCTAssertEqual(FileDeliveryLog.load(from: url), FileDeliveryLog(), "no file yet: an empty log")

        let now = Date(timeIntervalSince1970: 1_795_100_000)
        var log = FileDeliveryLog()
        log.tails["imac:s"] = .init(offset: 252_003_873, read: now)
        log.watched["imac"] = now
        log.deliveries = [FileDelivery(id: "toolu_1", sessionId: "s", host: .iMac, files: ["/home/bbdaniels/a b.pdf"],
                                       caption: "Two \"quoted\" lines\nand more", sentAt: now, sessionName: "Name")]
        log.save(to: url)
        XCTAssertEqual(FileDeliveryLog.load(from: url), log)
        XCTAssertEqual(FileDeliveryLog.url(home: "/Users/x").path, "/Users/x/Library/Application Support/Loupe/file-deliveries.json")

        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(FileDeliveryLog.load(from: url), FileDeliveryLog(), "an unreadable file is an empty log, never a crash")
    }

    // MARK: The copy

    func testWhereAnIMacFilesCopyGoes() {
        let d = FileDelivery(id: "toolu_01AB/../x", sessionId: "s", host: .iMac,
                             files: ["/a/report.pdf", "/b/report.pdf", "/a/data.csv"], caption: "", sentAt: Date())
        XCTAssertEqual(FileDeliveryFetch.cacheFolder(d, home: "/Users/x").path,
                       "/Users/x/Library/Caches/Loupe/deliveries/toolu_01AB____x", "the call id cannot name a folder elsewhere")
        XCTAssertEqual(FileDeliveryFetch.copyURL(d, file: "/a/data.csv", home: "/Users/x").path,
                       "/Users/x/Library/Caches/Loupe/deliveries/toolu_01AB____x/data.csv", "the copy keeps its name, so its type")
        XCTAssertEqual(FileDeliveryFetch.copyURL(d, file: "/a/report.pdf", home: "/Users/x").path,
                       "/Users/x/Library/Caches/Loupe/deliveries/toolu_01AB____x/1/report.pdf")
        XCTAssertEqual(FileDeliveryFetch.copyURL(d, file: "/b/report.pdf", home: "/Users/x").path,
                       "/Users/x/Library/Caches/Loupe/deliveries/toolu_01AB____x/2/report.pdf",
                       "two files of one name do not overwrite each other")
    }

    func testTheFetchReadsTheFileOverSshAndSaysWhyItFailed() {
        XCTAssertEqual(FileDeliveryFetch.sshArguments(path: "/home/b/it's here/a b.pdf"),
                       ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "imac", #"cat -- '/home/b/it'\''s here/a b.pdf'"#])
        XCTAssertEqual(FileDeliveryFetch.failure(status: 255, stderr: "ssh: connect to host imac: Operation timed out"),
                       "The iMac did not answer")
        XCTAssertEqual(FileDeliveryFetch.failure(status: 1, stderr: "cat: /x/a.pdf: No such file or directory"),
                       "The file is no longer on the iMac")
        XCTAssertEqual(FileDeliveryFetch.failure(status: 1, stderr: "cat: /x: Is a directory"), "It is a folder on the iMac, not a file")
        XCTAssertEqual(FileDeliveryFetch.failure(status: 2, stderr: ""), "The copy from the iMac failed (exit 2)")
    }

    func testAMacBookFileIsOpenedWhereItIs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.html").path
        try Data("<p>x</p>".utf8).write(to: URL(fileURLWithPath: file))
        let d = FileDelivery(id: "t", sessionId: "s", host: .mac, files: [file, file + ".gone"], caption: "", sentAt: Date())
        XCTAssertEqual(FileDeliveryFetch.localCopy(d, file: file, home: dir.path), .ready(URL(fileURLWithPath: file)))
        XCTAssertEqual(FileDeliveryFetch.localCopy(d, file: file + ".gone", home: dir.path), .failed("The file is no longer there"))
    }

    func testCopiesWithoutACardAreSwept() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let kept = FileDelivery(id: "kept", sessionId: "s", host: .iMac, files: ["/a/x.pdf"], caption: "", sentAt: Date())
        let gone = FileDelivery(id: "gone", sessionId: "s", host: .iMac, files: ["/a/y.pdf"], caption: "", sentAt: Date())
        for d in [kept, gone] {
            let url = FileDeliveryFetch.copyURL(d, file: d.files[0], home: home)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        FileDeliveryFetch.sweep(keeping: [kept], home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: FileDeliveryFetch.copyURL(kept, file: "/a/x.pdf", home: home).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileDeliveryFetch.cacheFolder(gone, home: home).path))
    }
}
