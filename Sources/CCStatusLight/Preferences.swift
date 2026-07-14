import SwiftUI
import AppKit

/// Editable view of the callback config, backed by callbacks.json. Auto-saves on
/// every change; the running engine picks changes up via its mtime reload.
@MainActor
final class CallbackSettings: ObservableObject {
    @Published var enabled: Bool { didSet { if !loading { save() } } }
    @Published var commands: [String: String] { didSet { if !loading { save() } } }
    private var loading = true

    init() {
        let cfg = CallbackConfig.load()
        enabled = cfg.enabled
        commands = cfg.commands
        loading = false
    }

    /// Re-read from disk (e.g. when the window opens), without triggering a save.
    func reload() {
        loading = true
        let cfg = CallbackConfig.load()
        enabled = cfg.enabled
        commands = cfg.commands
        loading = false
    }

    func save() {
        var cfg = CallbackConfig()
        cfg.enabled = enabled
        cfg.commands = commands
        cfg.write()
    }

    func command(for state: String) -> Binding<String> {
        Binding(get: { self.commands[state] ?? "" },
                set: { self.commands[state] = $0 })
    }

    /// Run a state's command once with sample placeholder values.
    func test(_ state: String) {
        let template = commands[state] ?? ""
        guard !template.isEmpty else { return }
        CallbackCommand.run(CallbackConfig.substitute(template, state: state, count: 1, name: "Test"))
    }

    func applyPreset(_ preset: [String: String]) { commands = preset }

    func reveal(_ url: URL) {
        let target = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

/// Preferences window content: enable toggle, per-state command editor with a
/// Test button, presets, and reveal-in-Finder. The commands are arbitrary shell
/// — a busylight is just one preset; notification/sound presets suit anyone.
struct PreferencesView: View {
    @ObservedObject var settings: CallbackSettings

    private static let rows: [(state: String, label: String, color: Color)] = [
        ("notification", "Attention", .red),
        ("working", "Working", .yellow),
        ("ready", "Ready", .blue),
        ("idle", "Idle", .green),
        ("none", "No sessions", .gray),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Run a command when the overall state changes", isOn: $settings.enabled)
                    .font(.headline)
                Text("The most urgent live session drives it — Attention beats Working beats Ready beats Idle. Any shell command works (a busylight, a notification, a sound, a webhook…).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text("Presets:").font(.caption).foregroundStyle(.secondary)
                Menu("Load example…") {
                    ForEach(CallbackConfig.presets, id: \.name) { preset in
                        Button(preset.name) { settings.applyPreset(preset.commands) }
                    }
                }
                .fixedSize()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.rows, id: \.state) { row in
                    HStack(spacing: 8) {
                        Circle().fill(row.color).frame(width: 8, height: 8)
                        Text(row.label).frame(width: 78, alignment: .leading)
                        TextField("command", text: settings.command(for: row.state))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                        Button("Test") { settings.test(row.state) }
                            .disabled((settings.commands[row.state] ?? "").isEmpty)
                    }
                }
            }

            Text("Placeholders: {state} {color} {count} {name}")
                .font(.caption2).foregroundStyle(.tertiary)

            Divider()

            HStack {
                Button("Reveal config") { settings.reveal(CallbackEngine.configURL) }
                Button("Reveal log") { settings.reveal(CallbackEngine.logURL) }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { settings.reload() }
    }
}
