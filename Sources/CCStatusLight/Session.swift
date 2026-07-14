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

/// Public list price per **million** tokens, by model family. Used only for a
/// clearly-labelled *estimate* — subscription accounts don't pay per token, and
/// these rates go stale. Update when Anthropic changes pricing.
/// Source: Anthropic public pricing, as of 2026-07.
struct ModelPricing {
    let input: Double        // $ / MTok
    let output: Double
    let cacheWrite: Double   // 5-minute cache write ≈ 1.25× input
    let cacheRead: Double    // ≈ 0.1× input

    /// Match by family token in the model id ("claude-opus-4-8" → opus). Returns
    /// nil for families we don't have prices for (so we show tokens, not a number).
    static func forModel(_ id: String?) -> ModelPricing? {
        guard let id = id?.lowercased() else { return nil }
        if id.contains("opus")   { return .init(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.50) }
        if id.contains("sonnet") { return .init(input: 3,  output: 15, cacheWrite: 3.75,  cacheRead: 0.30) }
        if id.contains("haiku")  { return .init(input: 1,  output: 5,  cacheWrite: 1.25,  cacheRead: 0.10) }
        return nil
    }
}

/// `/status`-style detail derived from the transcript, shown when a row is
/// expanded. All fields optional — only what the transcript has surfaced so far.
struct SessionDetail: Equatable {
    var model: String?          // raw id, e.g. "claude-opus-4-8"
    var ccVersion: String?      // Claude Code version, e.g. "2.1.208"
    var gitBranch: String?
    var permissionMode: String? // e.g. "default", "acceptEdits", "plan"
    var contextTokens: Int?     // approx context window in use (last message)
    var outputTokens: Int?      // output tokens of the last assistant message

    // Cumulative session totals, for the cost estimate.
    var totalInput = 0
    var totalOutput = 0
    var totalCacheCreate = 0
    var totalCacheRead = 0

    /// True when there's at least one field worth showing.
    var hasAny: Bool {
        model != nil || ccVersion != nil || gitBranch != nil
            || permissionMode != nil || contextTokens != nil
    }

    /// Total tokens processed this session (all types).
    var totalTokens: Int { totalInput + totalOutput + totalCacheCreate + totalCacheRead }

    /// Estimated session cost in USD (list price). Nil when we can't price the
    /// model or no tokens were counted yet.
    var estimatedCostUSD: Double? {
        guard let p = ModelPricing.forModel(model), totalTokens > 0 else { return nil }
        return (Double(totalInput) * p.input
                + Double(totalOutput) * p.output
                + Double(totalCacheCreate) * p.cacheWrite
                + Double(totalCacheRead) * p.cacheRead) / 1_000_000
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
