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

    /// One-line explanation, shown in the in-app legend.
    var legend: String {
        switch self {
        case .ready:        return "Session started; no activity yet."
        case .working:      return "Actively working — the label shows the current tool, Thinking, Subagents, or Compacting."
        case .notification: return "Waiting for you — it asked a question or needs a permission/decision."
        case .idle:         return "Finished its turn; waiting quietly for your next prompt."
        case .ended:        return "Session closed, or its process exited."
        }
    }

    /// Lifecycle order, used for the legend.
    static let legendOrder: [SessionState] = [.ready, .working, .notification, .idle, .ended]
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

/// `/status`-style detail derived from the transcript, shown when a row is
/// expanded. All fields optional — only what the transcript has surfaced so far.
///
/// A cumulative *cost* estimate was tried and removed: Claude Code writes one
/// message as several JSONL lines (inflating naive token sums) and bills from a
/// source the transcript doesn't reproduce, so it couldn't be reconciled with
/// `/status`. `contextTokens` is a point-in-time gauge, not a billing figure.
struct SessionDetail: Equatable {
    var model: String?          // raw id, e.g. "claude-opus-4-8"
    var ccVersion: String?      // Claude Code version, e.g. "2.1.208"
    var gitBranch: String?
    var permissionMode: String? // e.g. "default", "acceptEdits", "plan"
    var contextTokens: Int?     // approx context window in use (last message)

    /// True when there's at least one field worth showing.
    var hasAny: Bool {
        model != nil || ccVersion != nil || gitBranch != nil
            || permissionMode != nil || contextTokens != nil
    }
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
    var detail: SessionDetail?

    /// First 8 chars of the id, for when the session has no name.
    static func shortId(_ id: String) -> String { String(id.prefix(8)) }
}
