import Foundation

/// Whether CC Status Light's hooks are currently wired into Claude Code.
enum HookStatus {
    /// True if `~/.claude/settings.json` references our hook script.
    static var isInstalled: Bool {
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settings),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("cc-status-light-hook")
    }

    /// Where `install-hooks.sh` stages the script, and what settings.json points at.
    static var stagedHook: URL {
        SessionStore.stateDirectory
            .deletingLastPathComponent()            // …/CCStatusLight
            .appendingPathComponent("hooks/cc-status-light-hook.sh")
    }

    /// The copy shipped inside this build of the app.
    static var bundledHook: URL? {
        Bundle.main.url(forResource: "cc-status-light-hook", withExtension: "sh",
                        subdirectory: "hooks")
    }

    /// True when the staged hook differs from the one this app ships.
    ///
    /// Updating the app does **not** re-stage the hook — settings.json points at
    /// the staged copy — so a fix that spans both halves (like `waiting_since` in
    /// 0.5.2) silently half-applies: the app understands a field nothing is
    /// writing. Compare them so the app can say so instead of misreporting state.
    static var isStale: Bool {
        guard isInstalled,
              let bundled = bundledHook,
              let staged = try? Data(contentsOf: stagedHook),
              let shipped = try? Data(contentsOf: bundled)
        else { return false }
        return staged != shipped
    }

    /// Re-stage the bundled hook over the staged one. Only touches our own file
    /// in our own directory — settings.json already points here, so it needs no
    /// edit and no confirmation prompt.
    @discardableResult
    static func refreshStagedHook() -> Bool {
        guard let bundled = bundledHook else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: stagedHook.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: stagedHook.path) {
                try fm.removeItem(at: stagedHook)
            }
            try fm.copyItem(at: bundled, to: stagedHook)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedHook.path)
            return true
        } catch {
            return false
        }
    }
}
