import AppKit
import SwiftUI
import Combine

/// Owns the "Show on all Spaces" preference and applies it to the window's
/// collection behaviour. Persisted in UserDefaults so it survives relaunch.
@MainActor
final class WindowState: ObservableObject {
    private static let defaultsKey = "showOnAllSpaces"

    @Published var showOnAllSpaces: Bool {
        didSet {
            UserDefaults.standard.set(showOnAllSpaces, forKey: Self.defaultsKey)
            apply()
        }
    }

    private weak var window: NSWindow?

    init() {
        showOnAllSpaces = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    /// Attach the real window and apply the current preference.
    func bind(_ window: NSWindow) {
        self.window = window
        apply()
    }

    private func apply() {
        guard let window else { return }
        if showOnAllSpaces {
            window.collectionBehavior.insert(.canJoinAllSpaces)
        } else {
            window.collectionBehavior.remove(.canJoinAllSpaces)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SessionStore()
    private let environmentStore = EnvironmentStore()
    private let windowState = WindowState()
    private let callbackEngine = CallbackEngine()
    private var cancellables = Set<AnyCancellable>()
    private var window: NSWindow?

    // Kept so the app submenu's `menuNeedsUpdate` can reflect live hook status.
    private var installHooksItem: NSMenuItem?
    private var uninstallHooksItem: NSMenuItem?

    private let appName = "CC Status Light"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        makeWindow()
        showWindow()

        // Drive user-defined callbacks (e.g. a busylight) from the aggregate
        // session state. Emits on the main actor (SessionStore is @MainActor).
        store.$sessions
            .sink { [weak self] sessions in
                MainActor.assumeIsolated { self?.callbackEngine.update(sessions) }
            }
            .store(in: &cancellables)
    }

    // Turn the indicator off (fire the "none" callback) when quitting.
    func applicationWillTerminate(_ notification: Notification) {
        callbackEngine.fireClear()
    }

    // Closing the window must not quit the app — it keeps reading state in the
    // background and can be reopened from the dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Dock-icon click (with no visible window) reopens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindow() }
        return true
    }

    private func makeWindow() {
        let root = ContentView()
            .environmentObject(store)
            .environmentObject(environmentStore)
            .environmentObject(windowState)

        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "CC Status Light"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 420, height: 460))
        window.contentMinSize = NSSize(width: 200, height: 200)   // allow narrow resize
        window.isReleasedWhenClosed = false   // keep the instance for reopen
        window.setFrameAutosaveName("MainWindow")
        window.center()

        windowState.bind(window)
        self.window = window
    }

    private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu & About

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        // We drive Install/Uninstall enablement + the checkmark ourselves in
        // menuNeedsUpdate, so turn off automatic item enabling for this submenu.
        appMenu.autoenablesItems = false
        appMenu.delegate = self

        let about = appMenu.addItem(withTitle: "About \(appName)",
                                    action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        let installItem = appMenu.addItem(withTitle: "Install Hooks…",
                                          action: #selector(installHooks(_:)), keyEquivalent: "")
        installItem.target = self
        installHooksItem = installItem
        let uninstallItem = appMenu.addItem(withTitle: "Uninstall Hooks…",
                                            action: #selector(uninstallHooks(_:)), keyEquivalent: "")
        uninstallItem.target = self
        uninstallHooksItem = uninstallItem
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // A minimal Window menu so standard window commands work.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Hook installation

    @objc func installHooks(_ sender: Any?) { runHookInstaller(uninstall: false) }
    @objc func uninstallHooks(_ sender: Any?) { runHookInstaller(uninstall: true) }

    /// Refresh the hook menu items just before the app submenu opens: a live
    /// checkmark on "Install Hooks…" when installed, and "Uninstall Hooks…"
    /// disabled when there's nothing to remove. Runs on the main thread (AppKit
    /// menu delegate callback).
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            let installed = HookStatus.isInstalled
            installHooksItem?.state = installed ? .on : .off
            uninstallHooksItem?.isEnabled = installed
        }
    }

    /// Writable copy of the bundled hook scripts:
    /// ~/Library/Application Support/CCStatusLight/hooks
    private var hooksDir: URL {
        SessionStore.stateDirectory
            .deletingLastPathComponent()                       // …/CCStatusLight
            .appendingPathComponent("hooks", isDirectory: true)
    }

    /// Copy the bundled scripts to the writable hooks dir (executable). Returns
    /// the path to install-hooks.sh, or nil if the bundled scripts are missing.
    private func stageHookScripts() -> URL? {
        guard let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("hooks", isDirectory: true) else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        for name in ["install-hooks.sh", "cc-status-light-hook.sh"] {
            let src = bundled.appendingPathComponent(name)
            let dst = hooksDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { return nil }
            try? fm.removeItem(at: dst)
            do { try fm.copyItem(at: src, to: dst) } catch { return nil }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }
        return hooksDir.appendingPathComponent("install-hooks.sh")
    }

    /// Run install-hooks.sh with args; returns (exit code, combined output).
    private func runInstaller(_ script: URL, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + args
        var env = ProcessInfo.processInfo.environment
        // GUI apps inherit a minimal PATH; make common tool locations (jq) visible.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return (-1, "Failed to launch installer: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // drains until EOF
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func runHookInstaller(uninstall: Bool) {
        guard let script = stageHookScripts() else {
            showAlert(.critical, "Hook scripts not found",
                      "Couldn't locate the bundled hook scripts to install.")
            return
        }
        let verb = uninstall ? "Uninstall" : "Install"
        let base = uninstall ? ["--uninstall"] : []

        // 1) Compute the diff without writing.
        let (_, diffOut) = runInstaller(script, base + ["--diff"])
        let diff = diffOut.trimmingCharacters(in: .whitespacesAndNewlines)
        if diff.isEmpty || diff.contains("Nothing to change") {
            showAlert(.informational, "Nothing to change",
                      uninstall ? "The hooks aren't installed."
                                : "The hooks are already installed and up to date.")
            return
        }

        // 2) Confirm, showing exactly what changes.
        let alert = NSAlert()
        alert.messageText = "\(verb) CC Status Light hooks?"
        alert.informativeText = "This edits ~/.claude/settings.json "
            + "(a timestamped backup is made first). Review the change:"
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = diffView(diff)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 3) Apply.
        let (code, out) = runInstaller(script, base + ["--yes"])
        if code == 0 {
            showAlert(.informational, "\(verb) complete",
                      uninstall ? "Hooks removed. Ended sessions will clear shortly."
                                : "Hooks installed. Start (or restart) a Claude Code "
                                  + "session and it will appear here.")
        } else {
            showAlert(.critical, "\(verb) failed",
                      out.isEmpty ? "The installer exited with code \(code)." : out)
        }
    }

    private func diffView(_ text: String) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isVerticallyResizable = true
        tv.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.string = text
        scroll.documentView = tv
        return scroll
    }

    private func showAlert(_ style: NSAlert.Style, _ title: String, _ text: String) {
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: appName,
            .credits: Self.aboutCredits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"):
                "© 2026 liotru-lab · MIT License",
        ])
    }

    /// Description + credits + license shown in the standard About panel.
    private static let aboutCredits: NSAttributedString = {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 6

        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
        let dim: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]

        func link(_ text: String, _ url: String, _ base: [NSAttributedString.Key: Any]) -> NSAttributedString {
            var attrs = base
            attrs[.link] = URL(string: url)
            attrs[.foregroundColor] = NSColor.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return NSAttributedString(string: text, attributes: attrs)
        }

        let s = NSMutableAttributedString()
        s.append(NSAttributedString(
            string: "Shows the status of running Claude Code sessions.\n",
            attributes: body))
        s.append(NSAttributedString(
            string: "Reads session state locally — no telemetry, no cloud.\n\n",
            attributes: dim))
        s.append(NSAttributedString(string: "Created by liotru-lab.\n", attributes: body))
        s.append(NSAttributedString(
            string: "Released under the MIT License.\n\n",
            attributes: body))
        s.append(link("liotrulab.com", "https://www.liotrulab.com", dim))
        s.append(NSAttributedString(string: "   ·   ", attributes: dim))
        s.append(link("Source on GitHub", "https://github.com/liotru-lab/claude-code-status-light", dim))
        return s
    }()
}
