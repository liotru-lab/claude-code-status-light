import Foundation

/// The five states shown in the UI.
///
/// Derived primarily from the transcript (see TranscriptParser); `ready` and
/// `ended` come from the session lifecycle (hook marker / liveness).
enum SessionState: String, Codable, CaseIterable {
    case ready
    case working
    case notification
    case idle
    case ended

    var label: String {
        switch self {
        case .ready:        return "Ready"
        case .working:      return "Working"
        case .notification: return "Attention"
        case .idle:         return "Idle"
        case .ended:        return "Ended"
        }
    }

    var symbolName: String {
        switch self {
        case .ready:        return "circle.fill"
        case .working:      return "circle.fill"
        case .notification: return "exclamationmark.circle.fill"
        case .idle:         return "checkmark.circle.fill"
        case .ended:        return "moon.fill"
        }
    }

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

/// The hook-written marker at `<state-dir>/<session-id>.json`. It provides
/// liveness and a pointer to the transcript; the app derives real state from the
/// transcript. `state` is a coarse fallback used only when the transcript can't
/// be read.
struct Marker: Codable {
    let sessionId: String
    var state: SessionState?
    var cwd: String?
    var transcriptPath: String?
    var pid: Int32?
    var event: String?
    var timestamp: Date?
}

/// A session as shown in the window — composed from a marker plus the parsed
/// transcript.
struct Session: Identifiable {
    let id: String            // session id
    var displayName: String
    var state: SessionState
    var activity: String      // e.g. "Edit", "subagent", "thinking", "compacting"
    var cwd: String?
    var subagentCount: Int
    var live: Bool

    /// First 8 chars of the id, for when the session has no name.
    static func shortId(_ id: String) -> String { String(id.prefix(8)) }
}
