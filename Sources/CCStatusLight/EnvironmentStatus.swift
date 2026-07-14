import Foundation

/// Global, account-level status read (read-only) from Claude Code's own files:
/// identity from `~/.claude.json` (`oauthAccount`) and lifetime stats from
/// `~/.claude/stats-cache.json` (the `/status` **Stats** tab). Never writes;
/// surfaces only display fields, never tokens.
///
/// The live rate-limit "% used" bars from `/status` are deliberately absent:
/// that data isn't stored locally (it comes from Anthropic's servers via
/// rate-limit response headers), and the account token lives in the macOS
/// Keychain — scoped to Claude Code, unreadable by this app.
struct EnvironmentStatus: Equatable {
    // Identity — ~/.claude.json → oauthAccount
    var email: String?
    var displayName: String?
    var organization: String?
    var role: String?
    var planTier: String?      // organizationRateLimitTier
    var hasSubscription: Bool?

    // Lifetime stats — ~/.claude/stats-cache.json
    var totalSessions: Int?
    var totalMessages: Int?
    var memberSince: Date?
    var longestSessionMessages: Int?
    var models: [ModelUsage] = []

    struct ModelUsage: Equatable, Identifiable {
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreateTokens: Int
        var id: String { model }
        var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens }
    }

    var hasAny: Bool { email != nil || totalSessions != nil || !models.isEmpty }

    /// "default_claude_max_5x" → "Max 5×"; "default_claude_pro" → "Pro".
    var planLabel: String? {
        guard var s = planTier, !s.isEmpty else { return nil }
        for p in ["default_claude_", "default_"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        s = s.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "5x", with: "5×")
            .replacingOccurrences(of: "20x", with: "20×")
        return s.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Read both files (best-effort, all fields optional). Call off the main
    /// thread — it does blocking disk I/O.
    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> EnvironmentStatus {
        var env = EnvironmentStatus()

        // Identity
        let claudeJson = home.appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: claudeJson),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let acct = obj["oauthAccount"] as? [String: Any] {
                env.email = acct["emailAddress"] as? String
                env.displayName = acct["displayName"] as? String
                env.organization = acct["organizationName"] as? String
                env.role = acct["organizationRole"] as? String
                env.planTier = acct["organizationRateLimitTier"] as? String
            }
            env.hasSubscription = obj["hasAvailableSubscription"] as? Bool
        }

        // Lifetime stats
        let statsJson = home.appendingPathComponent(".claude/stats-cache.json")
        if let data = try? Data(contentsOf: statsJson),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            env.totalSessions = obj["totalSessions"] as? Int
            env.totalMessages = obj["totalMessages"] as? Int
            env.memberSince = parseDate(obj["firstSessionDate"] as? String)
            if let longest = obj["longestSession"] as? [String: Any] {
                env.longestSessionMessages = longest["messageCount"] as? Int
            }
            if let mu = obj["modelUsage"] as? [String: Any] {
                env.models = mu.compactMap { model, v in
                    guard let d = v as? [String: Any] else { return nil }
                    return ModelUsage(
                        model: model,
                        inputTokens: d["inputTokens"] as? Int ?? 0,
                        outputTokens: d["outputTokens"] as? Int ?? 0,
                        cacheReadTokens: d["cacheReadInputTokens"] as? Int ?? 0,
                        cacheCreateTokens: d["cacheCreationInputTokens"] as? Int ?? 0)
                }
                .sorted { $0.totalTokens > $1.totalTokens }
            }
        }
        return env
    }
}

/// Publishes the account/lifetime-stats panel data. Reads the two JSON files off
/// the main thread and refreshes on a slow timer (this data changes rarely).
@MainActor
final class EnvironmentStore: ObservableObject {
    @Published private(set) var status = EnvironmentStatus()

    private let queue = DispatchQueue(label: "net.liotru.ccstatuslight.env")
    private var timer: Timer?

    init() {
        refresh()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    func refresh() {
        queue.async { [weak self] in
            let loaded = EnvironmentStatus.load()
            DispatchQueue.main.async { self?.status = loaded }
        }
    }
}
