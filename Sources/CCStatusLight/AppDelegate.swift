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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
}
