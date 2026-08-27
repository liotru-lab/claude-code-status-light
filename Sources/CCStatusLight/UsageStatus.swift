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

    /// The cached token has expired and no session has been active recently, so we
    /// deliberately did *not* read the Keychain in the background (that would
    /// prompt out of the blue). The numbers are frozen at the last fetch; a look
    /// with ↻, or a session becoming active, refreshes them.
    @Published private(set) var isPaused = false

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { scheduleTimer(); refresh(interactive: true) }
            else {
                timer?.invalidate(); timer = nil
                snapshot = UsageSnapshot(); lastError = nil
                needsReauth = false; isPaused = false; backoffUntil = nil
                cachedToken = nil; tokenExpiresAt = nil
            }
        }
    }

    /// How often the footer numbers refresh, in minutes. A *network* refresh using
    /// the in-memory token — it doesn't touch the Keychain, so cadence never means
    /// prompts. User-chosen from `intervalChoices`.
    @Published var intervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(intervalMinutes, forKey: Self.intervalKey)
            if enabled { scheduleTimer() }
        }
    }

    static let enabledKey = "showPlanUsage"
    static let intervalKey = "planUsageIntervalMinutes"
    static let intervalChoices = [2, 4, 8, 15]
    /// How long after a session was last active we still treat you as "engaged" —
    /// the window in which a background refresh may read the Keychain (and so may
    /// prompt). Outside it, background refreshes never touch the Keychain.
    static let activityWindowKey = "usageActivityWindowMinutes"
    static let activityWindowChoices = [15, 30, 45, 60]
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    private var timer: Timer?
    /// Set from a 429's Retry-After — don't call the endpoint again until then.
    private var backoffUntil: Date?
    /// Last time any session was non-idle — fed from the session list. Used to
    /// decide whether a background Keychain read is in-context (you're working) or
    /// out of the blue (you've stepped away).
    private var lastSessionActiveAt: Date?

    /// Was a session active within the user's activity window?
    private var recentlyActive: Bool {
        guard let t = lastSessionActiveAt else { return false }
        let mins = UserDefaults.standard.object(forKey: Self.activityWindowKey) as? Int
        let window = (mins.map { Self.activityWindowChoices.contains($0) } ?? false) ? mins! : 15
        return Date().timeIntervalSince(t) < TimeInterval(window) * 60
    }

    /// Called from the app whenever the session list changes.
    func noteSessionsActive(_ active: Bool) {
        if active { lastSessionActiveAt = Date() }
    }

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

    /// Usage can't refresh until you act — login expired, or you denied Keychain
    /// access. Drives the orange alert (distinct from a quiet activity-pause).
    var needsAttention: Bool { needsReauth || keychainDenied }

    init() {
        // didSet does not fire during init, so enabling at launch does not read
        // the Keychain here. The timer runs, but its background ticks only make a
        // network call once a token exists — the first Keychain read waits until
        // you actually look at usage (open the popover).
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)   // default false
        let saved = UserDefaults.standard.integer(forKey: Self.intervalKey)
        intervalMinutes = Self.intervalChoices.contains(saved) ? saved : 4   // default 4
        if enabled { scheduleTimer() }
    }

    deinit { timer?.invalidate() }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: TimeInterval(intervalMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(interactive: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Hide the current error notice. It returns if the next fetch fails again.
    func dismissError() { lastError = nil }

    /// User asked to re-read the login (e.g. after signing back into Claude Code).
    func reconnect() {
        cachedToken = nil; tokenExpiresAt = nil
        needsReauth = false; lastError = nil
        refresh(interactive: true)
    }

    /// In-memory token + its expiry, learned from the Keychain blob. Held so
    /// background refreshes reuse it (a network call, no prompt) and we can tell
    /// when it has expired without hitting the Keychain again.
    private var cachedToken: String?
    private var tokenExpiresAt: Date?
    /// You denied the Keychain prompt. Stop reading it in the background (no more
    /// prompts every interval); only an explicit ↻ / re-enable retries.
    private var keychainDenied = false

    private var tokenUsable: Bool {
        guard cachedToken != nil else { return false }
        if let exp = tokenExpiresAt { return Date() < exp }
        return true   // no expiry info — assume usable, let a 401 correct it
    }

    /// Refresh the numbers.
    ///
    /// A valid cached token means a **silent network call** — no Keychain, no
    /// prompt — so that always runs (usage is account-wide and moves even when
    /// Code is idle). Only when the token has expired do we need the Keychain, and
    /// that read can prompt: we do it when `interactive` (you clicked ↻ / enabled)
    /// or when a session was active recently (in-context). Otherwise we **skip the
    /// Keychain** and flag the numbers paused — never an out-of-the-blue prompt.
    func refresh(interactive: Bool) {
        guard enabled, !isLoading else { return }
        // Honour a 429 back-off — don't hammer the endpoint while it's asked us to
        // wait. Applies to the timer and the manual "Try again" alike.
        if let until = backoffUntil, Date() < until {
            let secs = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
            lastError = "Usage checks are rate-limited — try again in \(secs)s."
            return
        }
        backoffUntil = nil

        if tokenUsable, let token = cachedToken {
            isLoading = true; lastError = nil
            fetch(bearer: token, fresh: false)          // silent, always OK
        } else if interactive {
            // You clicked ↻ / enabled: read the Keychain, and drop a prior deny.
            isLoading = true; lastError = nil; keychainDenied = false
            readTokenThenFetch()
        } else if recentlyActive && !keychainDenied {
            isLoading = true; lastError = nil
            readTokenThenFetch()                        // may prompt — but in-context
        } else {
            // Token expired and either you've stepped away or you denied the
            // prompt: don't read the Keychain (no repeat prompts). Stay paused.
            isPaused = true
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
        case .token(let t, let expiresAt):
            cachedToken = t; tokenExpiresAt = expiresAt
            fetch(bearer: t, fresh: true)
        case .notFound:
            isLoading = false
            needsReauth = true
            lastError = "Not logged into Claude Code. Sign in there, then Reconnect."
        case .denied:
            isLoading = false
            keychainDenied = true
            isPaused = true
            lastError = "Keychain access denied — paused. Use ↻ to retry."
        case .malformed:
            isLoading = false
            lastError = "Couldn't read the Claude Code login."
        }
    }

    /// `fresh` = the token was just read from the Keychain, so a 401 means the
    /// stored login itself is dead → Reconnect. A 401 on the *cached* token just
    /// means it rotated → drop it and read the Keychain once for a new one.
    private func fetch(bearer: String, fresh: Bool) {
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
            var retryAfter: TimeInterval?
            if let error {
                failure = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                unauthorized = true
                failure = "Login expired — open Claude Code once to refresh it."
            } else if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                // Rate-limited. Respect Retry-After if present, else a sane default.
                retryAfter = (http.value(forHTTPHeaderField: "Retry-After"))
                    .flatMap(Self.parseRetryAfter) ?? 60
                failure = "Usage checks are rate-limited — try again shortly."
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                failure = "Anthropic returned HTTP \(http.statusCode)."
            } else if let data {
                limits = Self.parse(data)
                if limits == nil { failure = "Couldn't read the usage response." }
            }
            Task { @MainActor in
                guard let self else { return }
                if unauthorized {
                    self.cachedToken = nil; self.tokenExpiresAt = nil
                    if fresh {
                        // A just-read token was still rejected → the login is dead.
                        self.isLoading = false
                        self.needsReauth = true
                        self.lastError = "Claude Code login expired. Sign in there, then Reconnect."
                    } else {
                        // Cached token rotated — read the Keychain once for a new one.
                        self.readTokenThenFetch()   // stays loading through the retry
                    }
                    return
                }
                self.isLoading = false
                if let retryAfter {
                    self.backoffUntil = Date().addingTimeInterval(retryAfter)
                }
                if let limits {
                    self.snapshot = UsageSnapshot(limits: limits, fetchedAt: Date())
                    self.lastError = nil
                    self.needsReauth = false
                    self.isPaused = false
                    self.keychainDenied = false
                    self.backoffUntil = nil
                } else {
                    self.lastError = failure
                }
            }
        }.resume()
    }

    /// Retry-After is either seconds (an integer) or an HTTP date.
    private static func parseRetryAfter(_ s: String) -> TimeInterval? {
        if let secs = TimeInterval(s.trimmingCharacters(in: .whitespaces)) { return max(1, secs) }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = fmt.date(from: s) { return max(1, d.timeIntervalSinceNow) }
        return nil
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

    enum TokenResult { case token(String, expiresAt: Date?), notFound, denied, malformed }

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
                // expiresAt is epoch-millis; keep a small safety margin so we
                // refresh from the Keychain just *before* the token actually dies.
                var expiry: Date?
                if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
                    expiry = Date(timeIntervalSince1970: ms / 1000).addingTimeInterval(-60)
                }
                return .token(token, expiresAt: expiry)
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
