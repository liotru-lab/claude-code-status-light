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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let windowState = WindowState()
    private var window: NSWindow?

    private let appName = "CC Status Light"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        makeWindow()
        showWindow()
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

        let about = appMenu.addItem(withTitle: "About \(appName)",
                                    action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
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
        s.append(NSAttributedString(string: "Created by ", attributes: body))
        s.append(link("liotru-lab", "https://www.liotrulab.com", body))
        s.append(NSAttributedString(string: ".\n", attributes: body))
        s.append(NSAttributedString(
            string: "Released under the MIT License.\n\n",
            attributes: body))
        s.append(link("liotrulab.com", "https://www.liotrulab.com", dim))
        s.append(NSAttributedString(string: "   ·   ", attributes: dim))
        s.append(link("Source on GitHub", "https://github.com/liotru-lab/claude-code-status-light", dim))
        return s
    }()
}
