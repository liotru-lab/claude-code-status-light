import Foundation

/// Derives a session's live state by incrementally tailing its JSONL transcript.
///
/// This is a Swift port of the upstream `claude-status` state machine, adapted to
/// the current on-disk schema (subagents live in separate `subagents/*.jsonl`
/// files, async agents complete via a `queue-operation` task-notification).
///
/// The machine's load-bearing invariant: a `Set` of `Agent` tool_use ids pins the
/// state to `.active` even after the orchestrator's turn ends — so a session with
/// running subagents reads as *working*, not *idle*. Sync agents are removed on
/// their `completed` tool_result; async agents survive their immediate
/// `async_launched` result and are removed only by a later completion notification.
final class TranscriptParser {
    /// Internal 4-state model (mapped to the app's 5 states below).
    enum State { case active, waiting, idle, compacting }

    let url: URL

    private(set) var state: State = .idle
    private(set) var activity: String = ""
    private(set) var lastLineTime: Date?   // newest envelope timestamp seen
    private var activeAgents: Set<String> = []
    private var compacting = false
    private var sawAssistant = false

    // Status detail (last value wins), surfaced in the per-session detail view.
    private var model: String?
    private var ccVersion: String?
    private var gitBranch: String?
    private var permissionMode: String?
    private var contextTokens: Int?   // point-in-time: context window in use (last msg)

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? iso.date(from: s)
    }

    // Name candidates (last value wins). Preference: custom (user) > ai > slug.
    private var customTitle: String?
    private var aiTitle: String?
    private var slug: String?

    // Incremental read cursor.
    private var offset: UInt64 = 0
    private var partial = Data()

    /// Cap the very first read so a huge transcript can't stall discovery. We lose
    /// some early context (recovered as the tail replays repeated name/slug lines).
    private static let maxInitialBytes: UInt64 = 20 * 1024 * 1024

    init(url: URL) { self.url = url }

    var subagentCount: Int { activeAgents.count }
    var hasStarted: Bool { sawAssistant }
    var nameFromTranscript: String? { customTitle ?? aiTitle ?? slug }

    /// `/status`-style detail derived from the transcript.
    var detail: SessionDetail {
        SessionDetail(model: model, ccVersion: ccVersion, gitBranch: gitBranch,
                      permissionMode: permissionMode, contextTokens: contextTokens)
    }

    /// State mapped into the app's five-state model.
    var sessionState: SessionState {
        switch state {
        case .active:     return .working
        case .compacting: return .working
        case .waiting:    return .notification   // a real question / permission = needs you
        case .idle:       return sawAssistant ? .idle : .ready
        }
    }

    // MARK: - Incremental read

    func update() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size == offset { return }            // nothing new
        if size < offset { resetMachine() }     // truncated / rotated

        if offset == 0, size > Self.maxInitialBytes {
            // Skip to a bounded tail and drop the first (partial) line.
            offset = size - Self.maxInitialBytes
            try? handle.seek(toOffset: offset)
            if let head = try? handle.readToEnd() {
                var d = head
                if let nl = d.firstIndex(of: 0x0A) {
                    d = d.subdata(in: d.index(after: nl)..<d.endIndex)
                }
                offset = size
                consume(d)
            }
            return
        }

        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.readToEnd() else { return }
        offset = size
        consume(chunk)
    }

    private func consume(_ chunk: Data) {
        var data = partial + chunk
        partial = Data()
        while let nl = data.firstIndex(of: 0x0A) {
            let line = data.subdata(in: data.startIndex..<nl)
            data = data.subdata(in: data.index(after: nl)..<data.endIndex)
            processLine(line)
        }
        partial = data
    }

    private func resetMachine() {
        offset = 0; partial = Data()
        state = .idle; activity = ""; lastLineTime = nil
        activeAgents.removeAll(); compacting = false; sawAssistant = false
        customTitle = nil; aiTitle = nil; slug = nil
        model = nil; ccVersion = nil; gitBranch = nil; permissionMode = nil
        contextTokens = nil
    }

    // MARK: - Line dispatch

    private func processLine(_ data: Data) {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let type = dict["type"] as? String
        else { return }

        if let ts = dict["timestamp"] as? String, let d = Self.parseDate(ts) {
            if lastLineTime == nil || d > lastLineTime! { lastLineTime = d }
        }

        // Status detail carried on most envelopes (last non-empty value wins).
        if let v = dict["version"] as? String, !v.isEmpty { ccVersion = v }
        if let b = dict["gitBranch"] as? String, !b.isEmpty { gitBranch = b }
        if let pm = dict["permissionMode"] as? String, !pm.isEmpty { permissionMode = pm }

        // Standalone name lines carry almost no envelope.
        switch type {
        case "custom-title": if let s = dict["customTitle"] as? String, !s.isEmpty { customTitle = s }; return
        case "ai-title":     if let s = dict["aiTitle"] as? String, !s.isEmpty { aiTitle = s }; return
        default: break
        }
        if let s = dict["slug"] as? String, !s.isEmpty { slug = s }

        if dict["isMeta"] as? Bool == true { return }

        switch type {
        case "assistant":       processAssistant(dict)
        case "user":            if !compacting { processUser(dict) }
        case "system":          processSystem(dict)
        case "queue-operation": processQueueOperation(dict)
        default:                break
        }
    }

    private func processAssistant(_ dict: [String: Any]) {
        compacting = false
        sawAssistant = true
        guard let message = dict["message"] as? [String: Any] else { return }
        let content = message["content"] as? [[String: Any]] ?? []

        if let m = message["model"] as? String, !m.isEmpty { model = m }
        if let usage = message["usage"] as? [String: Any] {
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
            let input = usage["input_tokens"] as? Int ?? 0
            // Point-in-time context window in use (last message wins). Deliberately
            // not summed across messages: a cumulative cost estimate couldn't be
            // reconciled with /status (Claude Code writes one message as several
            // lines, and its billing source differs from the transcript), so only
            // this gauge is surfaced.
            contextTokens = cacheRead + cacheCreate + input
        }

        // Record subagent spawns.
        for block in content where block["type"] as? String == "tool_use" {
            if block["name"] as? String == "Agent", let id = block["id"] as? String {
                activeAgents.insert(id)
            }
        }

        switch message["stop_reason"] as? String {
        case .some("tool_use"):
            if let last = content.reversed().first(where: { $0["type"] as? String == "tool_use" }) {
                let name = last["name"] as? String ?? ""
                if name == "AskUserQuestion" || name == "ExitPlanMode" {
                    state = .waiting; activity = "question"
                } else {
                    state = .active; activity = name
                }
            } else {
                state = .active; activity = ""
            }
        case .some("end_turn"):
            // A finished turn is idle — even if the text ends with a question.
            // Only a formal AskUserQuestion / ExitPlanMode (a tool_use, handled
            // above) counts as "waiting on you"; a conversational "want me to…?"
            // does not.
            if !activeAgents.isEmpty {
                state = .active; activity = "subagent"
            } else {
                state = .idle; activity = ""
            }
        case .some("stop_sequence"), .some("max_tokens"):
            state = .idle; activity = ""
        case .some(""), .none:
            state = .active; activity = ""      // streaming
        default:
            break
        }
    }

    private func processUser(_ dict: [String: Any]) {
        guard let message = dict["message"] as? [String: Any] else { return }
        let toolUseResult = dict["toolUseResult"] as? [String: Any]
        let isAsync = (toolUseResult?["isAsync"] as? Bool == true)
            || (toolUseResult?["status"] as? String == "async_launched")

        var hasText = false
        var hasToolResult = false

        if let content = message["content"] as? [[String: Any]] {
            for block in content {
                switch block["type"] as? String {
                case "tool_result":
                    hasToolResult = true
                    if !isAsync, let id = block["tool_use_id"] as? String {
                        activeAgents.remove(id)   // sync agent finished
                    }
                case "text":
                    if let s = block["text"] as? String, !s.isEmpty { hasText = true }
                case "image":
                    hasText = true
                default:
                    break
                }
            }
        } else if let s = message["content"] as? String, !s.isEmpty {
            hasText = true
        }

        // A fresh real prompt (not a tool_result) starts a new turn.
        let isRealPrompt = dict["promptId"] != nil
        if hasText && !hasToolResult && isRealPrompt {
            activeAgents.removeAll()
            state = .active; activity = "thinking"
        }
    }

    private func processSystem(_ dict: [String: Any]) {
        switch dict["subtype"] as? String {
        case .some("compact_boundary"):
            compacting = true; state = .compacting; activity = "compacting"
        case .some("turn_duration"):
            activeAgents.removeAll()
            if state == .active { state = .idle; activity = "" }
        default:
            break
        }
    }

    /// Async subagent completion arrives as a task-notification enqueued into the
    /// session. Its `<tool-use-id>` matches the launch's `Agent` tool_use id.
    private func processQueueOperation(_ dict: [String: Any]) {
        guard dict["operation"] as? String == "enqueue",
              let content = dict["content"] as? String,
              let toolUseId = tag("tool-use-id", in: content) else { return }
        switch tag("status", in: content) {
        case .some("completed"), .some("killed"), .some("failed"):
            activeAgents.remove(toolUseId)
            // If the orchestrator had already ended its turn and was only kept
            // `active` by this now-finished background agent, settle to idle.
            if activeAgents.isEmpty, state == .active, activity == "subagent" {
                state = .idle; activity = ""
            }
        default:
            break
        }
    }

    // MARK: - Helpers

    private func tag(_ name: String, in s: String) -> String? {
        guard let open = s.range(of: "<\(name)>"),
              let close = s.range(of: "</\(name)>"),
              open.upperBound <= close.lowerBound else { return nil }
        return String(s[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
