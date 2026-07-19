import Foundation

extension Notification.Name {
    /// Posted after every check settles (success or failure) — used by the
    /// `--check-update` harness to know when to print and exit.
    static let updateCheckFinished = Notification.Name("CCStatusLightUpdateCheckFinished")
}

/// Checks whether a newer release exists on GitHub.
///
/// Deliberately narrow: it issues one unauthenticated GET to the public releases
/// endpoint and reads a version string out of the response. Nothing about the
/// user, the machine, or their sessions is transmitted — no identifiers, no
/// counters, no query parameters. It never downloads or installs anything; the
/// most it does is point you at the release page. That keeps it on the right side
/// of the project's "no telemetry, no cloud" rule: a one-way version lookup, not
/// a beacon.
///
/// Automatic checking is **off by default** and lives behind a preference; the
/// manual "Check for Updates…" path always works because the user asked for it.
@MainActor
final class UpdateChecker: ObservableObject {
    /// Newest published version (e.g. "0.4.0"), once a check has succeeded.
    @Published private(set) var latestVersion: String?
    /// The .zip asset for that release — what an in-app update downloads.
    @Published private(set) var latestAssetURL: URL?
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?
    /// Set when the user dismisses a notice, so we don't nag for that version.
    @Published private(set) var dismissedVersion: String?

    /// Whether to check automatically (launch + daily). Off by default.
    @Published var automatic: Bool {
        didSet {
            UserDefaults.standard.set(automatic, forKey: Self.automaticKey)
            if automatic { scheduleTimer(); check() } else { timer?.invalidate(); timer = nil }
        }
    }

    static let automaticKey = "checkForUpdatesAutomatically"
    private static let dismissedKey = "dismissedUpdateVersion"
    private static let releasesAPI =
        URL(string: "https://api.github.com/repos/liotru-lab/claude-code-status-light/releases/latest")!
    static let releasesPage =
        URL(string: "https://github.com/liotru-lab/claude-code-status-light/releases/latest")!
    /// Once a day is plenty; it also keeps well inside GitHub's unauthenticated
    /// rate limit even if several copies run behind one IP.
    private static let interval: TimeInterval = 24 * 60 * 60

    private var timer: Timer?

    /// This build's version, from the bundle (falls back to "0" outside a bundle).
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True when a successful check found something strictly newer than this build.
    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return Self.isNewer(latest, than: Self.currentVersion)
    }

    /// An update the user hasn't already dismissed — what the UI should surface.
    var shouldNotify: Bool {
        updateAvailable && latestVersion != dismissedVersion
    }

    init() {
        automatic = UserDefaults.standard.bool(forKey: Self.automaticKey)   // default false
        dismissedVersion = UserDefaults.standard.string(forKey: Self.dismissedKey)
        if automatic { scheduleTimer(); check() }
    }

    deinit { timer?.invalidate() }

    func dismissCurrent() {
        guard let latest = latestVersion else { return }
        dismissedVersion = latest
        UserDefaults.standard.set(latest, forKey: Self.dismissedKey)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Fetch the latest release tag. Failures are recorded, never fatal — being
    /// offline is normal and must not disturb the app.
    func check() {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil

        var request = URLRequest(url: Self.releasesAPI)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // A plain product UA. GitHub wants one; it carries no user information.
        request.setValue("CCStatusLight/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            var version: String?
            var asset: URL?
            var failure: String?
            if let error {
                failure = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                failure = "GitHub returned HTTP \(http.statusCode)"
            } else if let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String {
                version = Self.normalize(tag)
                if let assets = obj["assets"] as? [[String: Any]] {
                    asset = assets
                        .compactMap { $0["browser_download_url"] as? String }
                        .first { $0.hasSuffix(".zip") }
                        .flatMap(URL.init(string:))
                }
            } else {
                failure = "Unexpected response from GitHub"
            }
            Task { @MainActor in
                guard let self else { return }
                self.isChecking = false
                self.lastChecked = Date()
                if let version { self.latestVersion = version }
                if let asset { self.latestAssetURL = asset }
                self.lastError = failure
                NotificationCenter.default.post(name: .updateCheckFinished, object: nil)
            }
        }.resume()
    }

    // MARK: - Version handling

    /// "v0.4.0" → "0.4.0".
    static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Numeric component-wise compare, so 0.3.10 correctly beats 0.3.9 (a plain
    /// string compare would get that backwards). Missing components read as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func components(_ v: String) -> [Int] {
        // Drop any pre-release/build suffix ("0.4.0-beta.1" → "0.4.0").
        let core = v.split(separator: "-", maxSplits: 1).first.map(String.init) ?? v
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
}
