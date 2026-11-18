import XCTest

/// `SessionLink`: the `topaz://session/<host>/<name>` links of the morning
/// email, read into the machine and the gate session they name, and every
/// other form refused.
final class SessionLinkTests: XCTestCase {

    func parse(_ s: String) -> SessionLink? {
        URL(string: s).flatMap(SessionLink.parse)
    }

    func testAnIMacLinkNamesItsGateSession() {
        let link = parse("topaz://session/imac/triage-1116")
        XCTAssertEqual(link, SessionLink(host: .iMac, name: "triage-1116"))
        XCTAssertEqual(link?.tmuxSession, "rc-triage-1116")
    }

    func testAMacLinkNamesItsGateSession() {
        XCTAssertEqual(parse("topaz://session/mac/personal-1115-0812"),
                       SessionLink(host: .mac, name: "personal-1115-0812"))
    }

    func testTheLongestNameAndAOneCharacterNameAreNames() {
        let long = String(repeating: "a", count: 40)
        XCTAssertEqual(parse("topaz://session/imac/" + long)?.name, long)
        XCTAssertEqual(parse("topaz://session/imac/7")?.name, "7")
    }

    func testAnotherSchemeIsRefused() {
        for s in ["https://session/imac/triage-1116", "topazz://session/imac/triage-1116",
                  "file:///session/imac/triage-1116"] {
            XCTAssertNil(parse(s), s)
        }
    }

    func testAnotherHostWordIsRefused() {
        for s in ["topaz://sessions/imac/triage-1116", "topaz://imac/triage-1116",
                  "topaz://session/pi/triage-1116", "topaz://session/iMac/triage-1116",
                  "topaz://session/macbook/triage-1116", "topaz:session/imac/triage-1116",
                  "topaz:///imac/triage-1116"] {
            XCTAssertNil(parse(s), s)
        }
    }

    func testANameThatIsNotAGateNameIsRefused() {
        for name in ["", "Triage-1116", "-triage", "triage_1116", "triage.1116", "rc-triage%2D1",
                     "triage%201116", "tri%C3%A9", String(repeating: "a", count: 41)] {
            XCTAssertNil(parse("topaz://session/imac/" + name), name)
        }
    }

    func testExtraPathPartsATrailingSlashAndExtrasAreRefused() {
        for s in ["topaz://session/imac/triage-1116/", "topaz://session/imac/triage-1116/more",
                  "topaz://session/imac", "topaz://session/imac/", "topaz://session/",
                  "topaz://session", "topaz://session//imac/triage-1116",
                  "topaz://session/imac/triage-1116?x=1", "topaz://session/imac/triage-1116#top",
                  "topaz://ben@session/imac/triage-1116", "topaz://session:80/imac/triage-1116"] {
            XCTAssertNil(parse(s), s)
        }
    }

    /// A link's machine is the one whose gate is asked, and what the alert
    /// says when the session has no line there names that machine.
    func testALinkAsksItsOwnMachineAndSaysWhenTheSessionIsNotThere() throws {
        let mac = try XCTUnwrap(parse("topaz://session/mac/land-1118"))
        let iMac = try XCTUnwrap(parse("topaz://session/imac/land-1118"))
        XCTAssertEqual(mac.sessionHost, .mac)
        XCTAssertEqual(iMac.sessionHost, .iMac)
        XCTAssertEqual(mac.notFound(answered: true).message, "The session is not running on the MacBook")
        XCTAssertEqual(iMac.notFound(answered: true).message, "The session is not running on the iMac")
        XCTAssertEqual(mac.notFound(answered: false).message, "The MacBook did not answer")
        XCTAssertEqual(iMac.notFound(answered: false).message, "The iMac did not answer")
        XCTAssertTrue(mac.notFound(answered: true).detail.contains("rc-land-1118"))
        XCTAssertTrue(mac.notFound(answered: false).detail.contains("pi-gate"))
        XCTAssertTrue(iMac.notFound(answered: false).detail.contains("ssh"))
    }
}
