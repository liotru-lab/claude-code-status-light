import AppKit

// Debug harness: `CCStatusLight --parse <transcript.jsonl>` runs the transcript
// parser over a file and prints the derived state as JSON, then exits. Lets the
// state machine be verified against real transcripts without the GUI.
let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--parse"), i + 1 < arguments.count {
    let parser = TranscriptParser(url: URL(fileURLWithPath: arguments[i + 1]))
    parser.update()
    let d = parser.detail
    let out: [String: Any] = [
        "state": parser.sessionState.rawValue,
        "activity": parser.activity,
        "subagents": parser.subagentCount,
        "name": parser.nameFromTranscript ?? "",
        "started": parser.hasStarted,
        "lastLineTime": parser.lastLineTime.map { ISO8601DateFormatter().string(from: $0) } ?? "",
        "model": d.model ?? "",
        "ccVersion": d.ccVersion ?? "",
        "gitBranch": d.gitBranch ?? "",
        "permissionMode": d.permissionMode ?? "",
        "contextTokens": d.contextTokens ?? 0,
        "outputTokens": d.outputTokens ?? 0,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: out,
                                              options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    exit(0)
}

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
