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

    /// State keys in aggregate-urgency order, for a stable editor layout.
    static let orderedStates = ["notification", "working", "ready", "idle", "none"]

    /// Ready-made command sets the Preferences UI can load. Busylight lights every
    /// state; the notification/sound presets fire only on Attention (so you're
    /// nudged when a session needs you, not on every transition).
    static let presets: [(name: String, commands: [String: String])] = [
        ("Busylight (all states)", example.commands),
        ("macOS notification on Attention", [
            "notification": "osascript -e 'display notification \"A session needs you\" with title \"Claude Code\"'",
        ]),
        ("Sound on Attention", [
            "notification": "afplay /System/Library/Sounds/Glass.aiff",
        ]),
    ]

    /// Replace {state} {color} {count} {name} in a command template.
    static func substitute(_ command: String, state: String, count: Int, name: String) -> String {
        var c = command
        let color = colors[state] ?? state
        for (t, v) in [("{state}", state), ("{color}", color), ("{count}", "\(count)"), ("{name}", name)] {
            c = c.replacingOccurrences(of: t, with: v)
        }
        return c
    }

    static func load() -> CallbackConfig {
        guard let data = try? Data(contentsOf: CallbackEngine.configURL),
              let cfg = try? JSONDecoder().decode(CallbackConfig.self, from: data)
        else { return CallbackConfig() }
        return cfg
    }

    func write() {
        let url = CallbackEngine.configURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: url) }
    }
}

/// Spawns a callback command via `/bin/bash -c`, with a PATH that includes
/// ~/.local/bin (busylight) and Homebrew. Shared by the engine and the
/// Preferences "Test" button. Runs off the main thread; `completion` gets the
/// exit code (or -1 on launch failure) on an arbitrary queue.
enum CallbackCommand {
    static func run(_ command: String, completion: (@Sendable (Int32) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var code: Int32 = -1
            do { try p.run(); p.waitUntilExit(); code = p.terminationStatus } catch { code = -1 }
            completion?(code)
        }
    }
}

/// Runs a user-defined command when the *aggregate* session state changes, so a
/// single indicator (a busylight) reflects the most urgent live session. The
/// aggregate uses its own urgency order — Attention > Working > Ready > Idle >
/// none — deliberately distinct from the list-sort priority.
@MainActor
final class CallbackEngine {
    /// ~/Library/Application Support/CCStatusLight/callbacks.json
    nonisolated static var configURL: URL {
        SessionStore.stateDirectory
            .deletingLastPathComponent()            // …/CCStatusLight
            .appendingPathComponent("callbacks.json")
    }

    /// ~/Library/Application Support/CCStatusLight/callbacks.log — a rolling trace
    /// of every fire (with the command's exit code) so behaviour is inspectable.
    nonisolated static var logURL: URL {
        configURL.deletingLastPathComponent().appendingPathComponent("callbacks.log")
    }

    private var config = CallbackConfig()
    private var configMTime: Date?
    private var lastFired: String?
    private var debounce: DispatchWorkItem?

    init() {
        writeExampleIfMissing()
        reloadIfChanged()
        log("engine init — enabled=\(config.enabled)")
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
        guard let template = config.commands[agg], !template.isEmpty else {
            log("state=\(agg): no command configured — nothing to run")
            return
        }
        run(CallbackConfig.substitute(template, state: agg, count: count, name: name), state: agg)
    }

    private func run(_ command: String, state: String) {
        CallbackCommand.run(command) { [weak self] code in
            self?.log("fired [\(state)] `\(command)` — exit \(code)")
        }
    }

    /// Rotate once the log passes this size, keeping the most recent lines.
    private static let logMaxBytes = 128 * 1024
    private static let logKeepLines = 400

    /// Append a timestamped line to callbacks.log. Nonisolated: safe to call from
    /// the command queue; each call opens/appends/closes. Self-rotating: when the
    /// file exceeds `logMaxBytes` it's trimmed to the last `logKeepLines`.
    nonisolated private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp)  \(message)\n".data(using: .utf8) else { return }
        let url = Self.logURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Rotate: keep only the recent tail once the file grows past the cap.
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > Self.logMaxBytes,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let tail = text.split(separator: "\n", omittingEmptySubsequences: false)
                .suffix(Self.logKeepLines).joined(separator: "\n")
            try? tail.data(using: .utf8)?.write(to: url)
        }

        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
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
            let wasEnabled = config.enabled
            config = cfg
            if wasEnabled != config.enabled {
                log("config reloaded — enabled=\(config.enabled)")
            }
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
