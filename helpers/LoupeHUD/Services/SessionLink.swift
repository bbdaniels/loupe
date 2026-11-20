import Foundation

/// A link to a live gate session, `topaz://session/<host>/<name>` (Ben,
/// 2026-11-15: the morning email links the sessions it names). `<host>` is
/// `imac` or `mac`, the machine whose gate runs it; `<name>` is pi-gate's
/// NAME, which the gate runs in the tmux session `rc-<name>` of its own
/// server (`tmux -L pi-gate`). Loupe registers the `topaz` scheme
/// (Info.plist, `CFBundleURLTypes`); a click on the link reaches
/// `AppDelegate.application(_:open:)`, which hands it to
/// `AgentsService.open(sessionLink:)`, the path a click on that session's
/// line takes.
///
/// One form only: no user, port, query or fragment, no percent escapes,
/// exactly two path parts and no trailing slash, so a link is either
/// exactly a session or refused. Foundation only, so the tests compile it
/// directly.
struct SessionLink: Equatable {
    enum Host: String {
        case iMac = "imac"
        case mac
    }

    static let scheme = "loupe"
    /// The URL's host: the kind of thing the link names.
    static let kind = "session"

    let host: Host
    let name: String

    /// The tmux session the gate runs it in, the row's `gateTmux`.
    var tmuxSession: String { "rc-" + name }

    /// The machine whose gate runs it.
    var sessionHost: SessionHost { host == .iMac ? .iMac : .mac }

    /// What the alert says when no line of `sessionHost` holds the session:
    /// its gate did not answer (`answered` false), or it answered and the
    /// session is not among its live ones.
    func notFound(answered: Bool) -> (message: String, detail: String) {
        let machine = sessionHost.machine
        if !answered {
            return ("The \(machine) did not answer",
                    sessionHost == .iMac
                        ? "It is asleep, offline, or refused ssh, so \(tmuxSession) could not be found."
                        : "Its gate (~/bin/pi-gate) did not run or answer, so \(tmuxSession) could not be found.")
        }
        return ("The session is not running on the \(machine)",
                "No live session \(tmuxSession): it has ended, or the link names one that never ran.")
    }

    /// The session `url` names; nil for anything else.
    static func parse(_ url: URL) -> SessionLink? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == scheme, c.host == kind,
              c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil
        else { return nil }
        let path = c.percentEncodedPath
        guard !path.contains("%") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty,
              let host = Host(rawValue: String(parts[1])),
              IMacLauncher.isGateName(parts[2]) else { return nil }
        return SessionLink(host: host, name: String(parts[2]))
    }
}
