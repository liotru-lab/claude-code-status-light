import AppKit

// Classic AppKit entry point. The app fully owns its NSWindow (created in
// AppDelegate) so the POC's window rules — closing the window does not quit,
// dock-click reopens, "Show on all Spaces" — are exact and not fighting a
// SwiftUI-managed scene.
//
// Program entry always runs on the main thread; assert that isolation so we can
// build the @MainActor AppDelegate and run the app.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)   // normal app: real dock icon, normal window
    app.run()
}
