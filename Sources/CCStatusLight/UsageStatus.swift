import Foundation
import Security

/// One plan-usage bar, as shown in Claude's own Settings ▸ Usage.
struct UsageLimit: Identifiable {
    enum Severity: String { case normal, warning, critical, unknown }

    let id = UUID()
    let title: String          // "Current session", "Weekly · All models", "Weekly · Fable"
    let percent: Int           // 0…100+
    let resetsAt: Date?
    let severity: Severity
    let group: String          // "session" | "weekly"
}

/// The full snapshot the panel renders.
struct UsageSnapshot {
    var limits: [UsageLimit] = []
    var fetchedAt: Date?
}

/// Reads plan usage from Claude's own `/api/oauth/usage` endpoint — the exact
/// data behind Settings ▸ Usage (5-hour session %, weekly %, per-model weekly),
/// which the transcript and local caches don't carry.
///
/// This is the one place the app leaves the machine and touches a credential, so
/// it is deliberately fenced:
/// - **Off by default** (`showPlanUsage`), like the update check. No toggle → no
///   Keychain read and no network call, ever.
/// - The bearer token is **read, never written**. We don't refresh it (that would
///   mean writing the credential back — an anti-pattern); Claude Code keeps it
///   fresh as you use it. An expired token surfaces as a hint, not a silent
///   refresh.
/// - The token goes to exactly one host — `api.anthropic.com` — and nowhere else.
///   It is never logged, never shown, never persisted by us.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot()
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    /// True once a fetch fails auth even after re-reading the Keychain — the login
    /// needs refreshing in Claude Code. The panel shows a Reconnect button instead
    /// of anything popping up on its own.
    @Published private(set) var needsReauth = false

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            // Turning it on is a deliberate action, so a one-off Keychain read
            // here is expected. Turning it off forgets everything held in memory.
            if enabled { refresh() }
            else { snapshot = UsageSnapshot(); lastError = nil; needsReauth = false; cachedToken = nil }
        }
    }

    static let enabledKey = "showPlanUsage"
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    /// Highest severity across the bars — drives an at-a-glance footer tint.
    var worstSeverity: UsageLimit.Severity {
        if snapshot.limits.contains(where: { $0.severity == .critical }) { return .critical }
        if snapshot.limits.contains(where: { $0.severity == .warning }) { return .warning }
        return .normal
    }

    /// The session bar's percent, for a compact footer readout (nil if unknown).
    var sessionPercent: Int? {
        snapshot.limits.first(where: { $0.group == "session" })?.percent
    }

    init() {
        // didSet does not fire during init, so this never reads the Keychain on
        // launch — reads happen only when you look at usage (open the popover) or
        // toggle the feature on. No background timer means no surprise prompt
        // while you're working on something else.
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)   // default false
    }

    /// User asked to re-read the login (e.g. after signing back into Claude Code).
    /// Drops the cached token so the next fetch goes to the Keychain.
    func reconnect() {
        cachedToken = nil
        needsReauth = false
        lastError = nil
        refresh()
    }

    /// Token held in memory after the first successful Keychain read, so routine
    /// refreshes don't re-hit the Keychain — which, if the user granted only
    /// "Allow" (not "Always Allow"), would re-prompt on every 5-minute tick. We
    /// only go back to the Keychain on first load or after a 401 (rotated token).
    private var cachedToken: String?

    func refresh() {
        guard enabled, !isLoading else { return }
        isLoading = true
        lastError = nil

        if let token = cachedToken {
            fetch(bearer: token, allowKeychainRetry: true)
        } else {
            readTokenThenFetch()
        }
    }

    /// The Keychain read can block — reading an item another app owns puts up the
    /// macOS consent dialog and `SecItemCopyMatching` waits on it — so it must
    /// never run on the main thread, or the UI freezes while the prompt is up.
    private func readTokenThenFetch() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.readToken()
            Task { @MainActor in self?.useToken(result) }
        }
    }

    private func useToken(_ result: TokenResult) {
        switch result {
        case .token(let t):
            cachedToken = t
            fetch(bearer: t, allowKeychainRetry: false)
        case .notFound:
            isLoading = false
            needsReauth = true
            lastError = "Not logged into Claude Code. Sign in there, then Reconnect."
        case .denied:
            isLoading = false
            lastError = "Keychain access denied. Allow it for CC Status Light, or turn this off."
        case .malformed:
            isLoading = false
            lastError = "Couldn't read the Claude Code login."
        }
    }

    /// `allowKeychainRetry` is true only when `bearer` came from the in-memory
    /// cache: a 401 then means the cached token rotated, so we drop it and re-read
    /// the Keychain once. A 401 on a freshly-read token is a real auth failure.
    private func fetch(bearer: String, allowKeychainRetry: Bool) {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 12
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("CCStatusLight (usage panel)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            var limits: [UsageLimit]?
            var failure: String?
            var unauthorized = false
            if let error {
                failure = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                unauthorized = true
                failure = "Login expired — open Claude Code once to refresh it."
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                failure = "Anthropic returned HTTP \(http.statusCode)."
            } else if let data {
                limits = Self.parse(data)
                if limits == nil { failure = "Couldn't read the usage response." }
            }
            Task { @MainActor in
                guard let self else { return }
                // A 401 on a cached token means it rotated — drop it and re-read
                // the Keychain once. `allowKeychainRetry` guards against a loop.
                if unauthorized, allowKeychainRetry {
                    self.cachedToken = nil
                    self.readTokenThenFetch()   // keeps isLoading true through the retry
                    return
                }
                self.isLoading = false
                if let limits {
                    self.snapshot = UsageSnapshot(limits: limits, fetchedAt: Date())
                    self.lastError = nil
                    self.needsReauth = false
                } else {
                    // A 401 that survived the Keychain re-read means the stored
                    // login itself is stale — sign in to Claude Code, then Reconnect.
                    if unauthorized {
                        self.cachedToken = nil
                        self.needsReauth = true
                        self.lastError = "Claude Code login expired. Sign in there, then Reconnect."
                    } else {
                        self.lastError = failure
                    }
                }
            }
        }.resume()
    }

    // MARK: - Parsing

    /// Parse the `limits` array — the same list Settings ▸ Usage renders.
    private static func parse(_ data: Data) -> [UsageLimit]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["limits"] as? [[String: Any]] else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        return raw.compactMap { entry -> UsageLimit? in
            guard let kind = entry["kind"] as? String else { return nil }
            let percent = (entry["percent"] as? NSNumber)?.intValue ?? 0
            let group = entry["group"] as? String ?? kind
            let severity = UsageLimit.Severity(rawValue: entry["severity"] as? String ?? "") ?? .unknown

            var resets: Date?
            if let s = entry["resets_at"] as? String {
                resets = iso.date(from: s) ?? isoPlain.date(from: s)
            }

            let title: String
            switch kind {
            case "session":       title = "Current session"
            case "weekly_all":    title = "Weekly · All models"
            case "weekly_scoped":
                let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                title = "Weekly · \(model ?? "model")"
            default:              title = kind.replacingOccurrences(of: "_", with: " ").capitalized
            }
            return UsageLimit(title: title, percent: percent, resetsAt: resets,
                              severity: severity, group: group)
        }
    }

    // MARK: - Keychain

    enum TokenResult { case token(String), notFound, denied, malformed }

    /// Read Claude Code's stored OAuth access token.
    ///
    /// The login keychain is already per-macOS-user, so we only ever see the
    /// running user's items. We pin the lookup to `account == NSUserName()` — the
    /// label Claude Code writes — so that if more than one credentials item ever
    /// existed we pick *this* user's deterministically rather than an arbitrary
    /// one. If that precise match isn't found (e.g. a future build labels the
    /// account differently), fall back to a service-only match before giving up.
    ///
    /// Reading an item another app created triggers a one-time macOS consent
    /// prompt — that dialog, not us, is what gates access to the credential.
    private static func readToken() -> TokenResult {
        func attempt(pinAccount: Bool) -> TokenResult {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if pinAccount { query[kSecAttrAccount as String] = NSUserName() }

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let oauth = obj["claudeAiOauth"] as? [String: Any],
                      let token = oauth["accessToken"] as? String,
                      !token.isEmpty
                else { return .malformed }
                return .token(token)
            case errSecItemNotFound:      return .notFound
            case errSecAuthFailed,
                 errSecUserCanceled,
                 errSecInteractionNotAllowed: return .denied
            default:                      return .notFound
            }
        }

        let pinned = attempt(pinAccount: true)
        if case .notFound = pinned { return attempt(pinAccount: false) }
        return pinned
    }
}
