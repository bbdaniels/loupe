import XCTest

/// How an iMac session's paths read on this Mac (`SessionHost`) and the
/// mirror's rsync call (`IMacMirror`).
final class SessionHostTests: XCTestCase {

    func testIMacProjectsPathsMapOntoTheMacsProjects() {
        let home = "/Users/x"
        XCTAssertEqual(SessionHost.iMac.macPath("/home/bbdaniels/Projects/heat-tv/src", home: home),
                       "/Users/x/Projects/heat-tv/src")
        XCTAssertEqual(SessionHost.iMac.macPath("/home/bbdaniels/Projects", home: home), "/Users/x/Projects")
        XCTAssertEqual(SessionHost.iMac.macPath("/home/bbdaniels", home: home), "/home/bbdaniels",
                       "outside ~/Projects the Mac has no copy, so the path stays the iMac's")
        XCTAssertEqual(SessionHost.iMac.macPath("/home/bbdaniels/ProjectsOld/a", home: home),
                       "/home/bbdaniels/ProjectsOld/a")
        XCTAssertEqual(SessionHost.mac.macPath("/home/bbdaniels/Projects/a", home: home),
                       "/home/bbdaniels/Projects/a", "the Mac's own paths are never mapped")
    }

    func testIMacDirectoryNamesMapToTheMacsEncoding() {
        let home = "/Users/x"
        XCTAssertEqual(SessionHost.iMac.macDirName("-home-bbdaniels-Projects-heat-tv", home: home),
                       "-Users-x-Projects-heat-tv")
        XCTAssertEqual(SessionHost.iMac.macDirName("-home-bbdaniels-Projects", home: home), "-Users-x-Projects")
        XCTAssertNil(SessionHost.iMac.macDirName("-home-bbdaniels", home: home))
        XCTAssertNil(SessionHost.iMac.macDirName("-home-bbdaniels-ProjectsOld", home: home))
        XCTAssertNil(SessionHost.mac.macDirName("-home-bbdaniels-Projects-a", home: home))
        XCTAssertEqual(SessionHost.encodeDirName("/Users/a_b/.claude"), "-Users-a-b--claude")
    }

    func testEachHostHasItsOwnDirectories() {
        let home = "/Users/x"
        XCTAssertEqual(SessionHost.mac.projectsDir(home: home), "/Users/x/.claude/projects")
        XCTAssertEqual(SessionHost.iMac.projectsDir(home: home), "/Users/x/Library/Caches/Loupe/hosts/imac/projects")
        XCTAssertEqual(SessionHost.mac.claimsDir(home: home).path, "/Users/x/.claude/session-projects")
        XCTAssertEqual(SessionHost.iMac.claimsDir(home: home).path,
                       "/Users/x/Library/Caches/Loupe/hosts/imac/session-projects")
    }

    func testTheMirrorCopiesOnlyTopLevelTranscriptsAndClaimsReadOnly() {
        let args = IMacMirror.rsyncArguments(root: "/m")
        XCTAssertEqual(Array(args.suffix(2)), ["imac:.claude/", "/m/"], "from the iMac, into the mirror; never the other way")
        XCTAssertTrue(args.contains("--delete"))
        XCTAssertTrue(args.contains("--include=/projects/*/*.jsonl"))
        XCTAssertTrue(args.contains("--include=/session-projects/*.json"))
        XCTAssertEqual(args.filter { $0.hasPrefix("--include") || $0.hasPrefix("--exclude") }.last, "--exclude=*",
                       "everything not included is excluded, including subagent folders")
        XCTAssertFalse(args.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("z") },
                       "no compression: openrsync's -z stalls against the iMac's rsync")
        XCTAssertTrue(args.contains("ssh -o BatchMode=yes -o ConnectTimeout=10"))
    }

    func testAMissingIMacGivesAFailureNotAHang() throws {
        // A root the run cannot even create fails at once and leaves nothing behind.
        if case .failed = IMacMirror.run(root: "/dev/null/mirror") {} else { XCTFail("expected a failure") }
    }

    /// The gate's `live` answer reads into records; tmux and the bridge survive.
    func testGateLiveReadsTheGatesAnswer() {
        let json = """
        {"ok": true, "live": [
          {"pid": 4242, "sessionId": "59dc567e-0000-0000-0000-000000000000", "cwd": "/home/bbdaniels/Projects/personal",
           "kind": "interactive", "entrypoint": "cli", "status": "waiting", "waitingFor": "approve Bash",
           "bridgeSessionId": "session_01ABC", "tmux": "handoff:@4.%4", "procStart": "9765587"}
        ]}
        """
        let records = GateLive.records(from: Data(json.utf8))
        XCTAssertEqual(records?.count, 1)
        XCTAssertEqual(records?.first?.tmux, "handoff:@4.%4")
        XCTAssertEqual(records?.first?.waitingFor, "approve Bash")
        XCTAssertEqual(records?.first?.remoteControlURL?.absoluteString, "https://claude.ai/code/session_01ABC")
        XCTAssertEqual(SessionHost.iMac.macPath(records!.first!.cwd, home: "/Users/x"), "/Users/x/Projects/personal")
    }

    /// A refusal or a non-gate answer is nil, never an empty "nothing runs".
    func testGateLiveRejectsAFailedAnswer() {
        XCTAssertNil(GateLive.records(from: Data(#"{"ok": false, "error": "no"}"#.utf8)))
        XCTAssertNil(GateLive.records(from: Data("not json".utf8)))
    }

    // MARK: Which records get a line

    private func record(_ id: String, kind: String = "interactive", tmux: String? = nil,
                        server: String? = nil, service: String? = nil,
                        entrypoint: String = "cli") -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: 1, sessionId: id, cwd: "/Users/x/Projects/loupe", kind: kind,
                            entrypoint: entrypoint, name: nil, bridgeSessionId: "session_01", jobId: nil,
                            status: "busy", waitingFor: nil, startedAt: nil, updatedAt: nil, procStart: nil,
                            tmux: tmux, tmuxServer: server, service: service)
    }

    /// The MacBook gate's answer as it stood on 2026-11-18, one session:
    /// the server and the tmux session are read, and it gets a line.
    func testAMacBookGateSessionGetsALine() throws {
        let json = """
        {"ok": true, "live": [{"pid": 77680, "sessionId": "c7a4dc85-c1a6-4836-beed-d18176647b09",
          "cwd": "/Users/bbdaniels/Projects/loupe", "kind": "interactive", "entrypoint": "cli", "name": "loupe-71",
          "bridgeSessionId": "session_01PZ", "status": "busy", "startedAt": 1795032284650,
          "procStart": "Wed Nov 18 20:04:44 2026", "tmux": "rc-loupe-mac-gate:@37.%37", "tmuxServer": "pi-gate",
          "attach": "tmux -L pi-gate attach -t =rc-loupe-mac-gate"}]}
        """
        let records = try XCTUnwrap(GateLive.records(from: Data(json.utf8)))
        XCTAssertEqual(records.first?.tmuxServer, "pi-gate")
        XCTAssertEqual(records.first?.tmuxSession, "rc-loupe-mac-gate")
        XCTAssertEqual(GateLive.rows(host: .mac, records: records).map(\.sessionId),
                       ["c7a4dc85-c1a6-4836-beed-d18176647b09"])
    }

    /// On the MacBook only the gate's own sessions are listed from `live`:
    /// its other sessions have their own sources or a terminal in front of Ben.
    func testOnlyTheGatesOwnSessionsAreListedOnTheMacBook() {
        let records = [
            record("gate", tmux: "rc-land-1118:@1.%1", server: "pi-gate"),
            record("terminal"),                                              // claude typed in a tab
            record("phone", entrypoint: "sdk-cli"),                          // Remote Control's child
            record("other-server", tmux: "rc-x:@1.%1", server: "default"),
            record("other-name", tmux: "pi-gate-keep:@0.%0", server: "pi-gate"),
            record("job", kind: "bg", tmux: "rc-job:@2.%2", server: "pi-gate"),
            record("duet", tmux: "rc-duet:@3.%3", server: "pi-gate", service: "duet"),
        ]
        XCTAssertEqual(GateLive.rows(host: .mac, records: records).map(\.sessionId), ["gate"])
    }

    /// A session another source already gave a live line is not listed again,
    /// and one the gate answers twice is listed once.
    func testNoSessionIsListedTwice() {
        let records = [
            record("a", tmux: "rc-a:@1.%1", server: "pi-gate"),
            record("b", tmux: "rc-b:@2.%2", server: "pi-gate"),
            record("b", tmux: "rc-b:@2.%2", server: "pi-gate"),
        ]
        XCTAssertEqual(GateLive.rows(host: .mac, records: records, listed: ["a"]).map(\.sessionId), ["b"])
        XCTAssertEqual(GateLive.rows(host: .iMac, records: records).map(\.sessionId), ["a", "b"])
    }

    /// The iMac's lines are as before: every interactive session that is not
    /// a service, with a tmux session or without (a phone-started one).
    func testTheIMacListsEveryInteractiveSessionButAService() {
        let records = [
            record("gate", tmux: "rc-land-1118:@1.%1", server: "pi-gate"),
            record("phone", entrypoint: "sdk-cli"),
            record("handoff", tmux: "handoff:@4.%4", server: "default"),
            record("job", kind: "bg"),
            record("duet", tmux: "rc-duet:@3.%3", server: "pi-gate", service: "duet"),
        ]
        XCTAssertEqual(GateLive.rows(host: .iMac, records: records).map(\.sessionId), ["gate", "phone", "handoff"])
    }

    func testEachMachineHasItsName() {
        XCTAssertEqual(SessionHost.mac.machine, "MacBook")
        XCTAssertEqual(SessionHost.iMac.machine, "iMac")
    }
}
