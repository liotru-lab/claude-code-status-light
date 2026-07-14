import Foundation

/// User-defined callback config: maps an aggregate state key to a shell command.
/// Lives in our own Application Support dir so uninstall stays clean. Disabled by
/// default; the shipped file pre-fills a busylight example the user can enable.
struct CallbackConfig: Codable, Equatable {
    var enabled: Bool = false
    /// state key ("notification"|"working"|"ready"|"idle"|"none") → command.
    var commands: [String: String] = [:]

    /// Default {color} per state — matches the states' UI colours.
    static let colors: [String: String] = [
        "notification": "red", "working": "yellow",
        "ready": "blue", "idle": "green", "none": "off",
    ]

    /// The example written on first run: an app-driven busylight, off by default.
    static let example = CallbackConfig(enabled: false, commands: [
        "notification": "busylight on red",
        "working": "busylight on yellow",
        "ready": "busylight on blue",
        "idle": "busylight on green",
        "none": "busylight off",
    ])
}

/// Runs a user-defined command when the *aggregate* session state changes, so a
/// single indicator (a busylight) reflects the most urgent live session. The
/// aggregate uses its own urgency order — Attention > Working > Ready > Idle >
/// none — deliberately distinct from the list-sort priority.
@MainActor
final class CallbackEngine {
    /// ~/Library/Application Support/CCStatusLight/callbacks.json
    static var configURL: URL {
        SessionStore.stateDirectory
            .deletingLastPathComponent()            // …/CCStatusLight
            .appendingPathComponent("callbacks.json")
    }

    private var config = CallbackConfig()
    private var configMTime: Date?
    private var lastFired: String?
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label: "net.liotru.ccstatuslight.callbacks")

    init() {
        writeExampleIfMissing()
        reloadIfChanged()
    }

    /// Aggregate urgency order for a single indicator.
    static func aggregate(_ sessions: [Session]) -> String {
        let live = sessions.filter { $0.live && $0.state != .ended }
        if live.isEmpty { return "none" }
        for s in [SessionState.notification, .working, .ready, .idle]
        where live.contains(where: { $0.state == s }) {
            return s.rawValue
        }
        return "none"
    }

    /// Called by the store whenever the session list changes.
    func update(_ sessions: [Session]) {
        reloadIfChanged()
        guard config.enabled else { return }
        let agg = Self.aggregate(sessions)
        guard agg != lastFired else { return }
        let count = sessions.filter { $0.live && $0.state != .ended }.count
        let name = sessions.first(where: { $0.state.rawValue == agg })?.displayName ?? ""

        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.fire(agg, count: count, name: name) }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Fire the clear/"none" command (e.g. on quit) so the light doesn't stay lit.
    func fireClear() {
        reloadIfChanged()
        guard config.enabled else { return }
        fire("none", count: 0, name: "")
    }

    private func fire(_ agg: String, count: Int, name: String) {
        lastFired = agg
        guard var cmd = config.commands[agg], !cmd.isEmpty else { return }
        let color = CallbackConfig.colors[agg] ?? agg
        for (token, value) in [("{state}", agg), ("{color}", color),
                               ("{count}", "\(count)"), ("{name}", name)] {
            cmd = cmd.replacingOccurrences(of: token, with: value)
        }
        run(cmd)
    }

    private func run(_ command: String) {
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            // GUI apps inherit a minimal PATH; expose ~/.local/bin (busylight) etc.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    // MARK: - Config file

    private func reloadIfChanged() {
        let url = Self.configURL
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if mtime == configMTime { return }
        configMTime = mtime
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(CallbackConfig.self, from: data) {
            config = cfg
        }
    }

    private func writeExampleIfMissing() {
        let url = Self.configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(CallbackConfig.example) {
            try? data.write(to: url)
        }
    }
}
