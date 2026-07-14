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
}
