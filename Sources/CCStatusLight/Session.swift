import Foundation

/// The five POC states. These map 1:1 to Claude Code hook events via the
/// installed hook script (see hooks/cc-status-light-hook.sh):
///
///   SessionStart      -> ready
///   UserPromptSubmit  -> working
///   PostToolUse       -> working
///   Notification      -> notification
///   Stop              -> idle
///   SessionEnd        -> ended
enum SessionState: String, Codable, CaseIterable {
    case ready
    case working
    case notification
    case idle
    case ended

    /// Human label shown in the row.
    var label: String {
        switch self {
        case .ready:        return "Ready"
        case .working:      return "Working"
        case .notification: return "Notification"
        case .idle:         return "Idle"
        case .ended:        return "Ended"
        }
    }

    /// SF Symbol for the leading status dot.
    var symbolName: String {
        switch self {
        case .ready:        return "circle.fill"
        case .working:      return "circle.fill"
        case .notification: return "exclamationmark.circle.fill"
        case .idle:         return "checkmark.circle.fill"
        case .ended:        return "moon.fill"
        }
    }

    /// Sort weight: most "interesting" states float to the top.
    var priority: Int {
        switch self {
        case .working:      return 0
        case .notification: return 1
        case .ready:        return 2
        case .idle:         return 3
        case .ended:        return 4
        }
    }
}

/// One Claude Code session, decoded from a `<session-id>.json` state file.
/// Field names use snake_case on disk; the decoder is configured with
/// `.convertFromSnakeCase`, so `session_id` -> `sessionId`, etc.
struct Session: Identifiable, Codable {
    let sessionId: String
    let state: SessionState
    var sessionName: String?
    var cwd: String?
    var event: String?
    var timestamp: Date?

    var id: String { sessionId }

    /// First 8 chars of the id, for when the session has no name.
    var shortId: String { String(sessionId.prefix(8)) }

    /// Row title: the session name if the user set one, else the short id.
    var displayName: String {
        if let name = sessionName, !name.isEmpty { return name }
        return shortId
    }
}
