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
    ]
    if let data = try? JSONSerialization.data(withJSONObject: out,
                                              options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    exit(0)
}

// Debug harness: `CCStatusLight --env` prints the account/lifetime-stats panel
// data (read from ~/.claude.json and ~/.claude/stats-cache.json) and exits.
if arguments.contains("--env") {
    let e = EnvironmentStatus.load()
    let out: [String: Any] = [
        "email": e.email ?? "", "displayName": e.displayName ?? "",
        "organization": e.organization ?? "", "role": e.role ?? "",
        "planTier": e.planTier ?? "", "hasSubscription": e.hasSubscription ?? false,
        "totalSessions": e.totalSessions ?? 0, "totalMessages": e.totalMessages ?? 0,
        "longestSessionMessages": e.longestSessionMessages ?? 0,
        "models": e.models.map { ["model": $0.model, "totalTokens": $0.totalTokens] },
    ]
    if let data = try? JSONSerialization.data(withJSONObject: out,
                                              options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    exit(0)
}

// Debug harness: `CCStatusLight --check-update` performs one update check and
// prints the result. Verifies the GitHub lookup and version comparison without
// the GUI (and without touching the automatic-check preference).
if arguments.contains("--check-update") {
    // The result arrives via a @MainActor hop and a main-queue observer, so the
    // run loop has to actually run — a blocking semaphore would deadlock here.
    var finished = false
    MainActor.assumeIsolated {
        let checker = UpdateChecker()
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: .updateCheckFinished, object: nil, queue: .main) { _ in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            MainActor.assumeIsolated {
                let out: [String: Any] = [
                    "current": UpdateChecker.currentVersion,
                    "latest": checker.latestVersion ?? "",
                    "updateAvailable": checker.updateAvailable,
                    "error": checker.lastError ?? "",
                ]
                if let data = try? JSONSerialization.data(withJSONObject: out,
                                                          options: [.prettyPrinted, .sortedKeys]) {
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
            }
            finished = true
        }
        checker.check()
    }
    let deadline = Date().addingTimeInterval(30)
    while !finished && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    if !finished { FileHandle.standardError.write(Data("check timed out\n".utf8)) }
    exit(finished ? 0 : 1)
}

// Debug harness: `CCStatusLight --self-update` runs a real in-app update
// (download → verify → hand off to the swap helper) against this bundle, so the
// updater can be exercised without clicking through the GUI.
if arguments.contains("--self-update") {
    var settled = false
    let updater = MainActor.assumeIsolated { SelfUpdater() }
    MainActor.assumeIsolated {
        let checker = UpdateChecker()
        updater.onHandoff = {
            FileHandle.standardOutput.write(Data("handoff: helper launched\n".utf8))
            settled = true
        }
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: .updateCheckFinished, object: nil, queue: .main) { _ in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            MainActor.assumeIsolated {
                guard let asset = checker.latestAssetURL else {
                    FileHandle.standardError.write(Data("no .zip asset in latest release\n".utf8))
                    settled = true
                    return
                }
                FileHandle.standardOutput.write(Data("""
                    current: \(UpdateChecker.currentVersion)
                    latest:  \(checker.latestVersion ?? "?")
                    asset:   \(asset.lastPathComponent)

                    """.utf8))
                updater.update(from: asset)
            }
        }
        checker.check()
    }

    // Pump the run loop, echoing phase changes so a verification failure is visible.
    let deadline = Date().addingTimeInterval(180)
    var lastPhase: SelfUpdater.Phase = .idle
    while !settled && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        let phase = MainActor.assumeIsolated { updater.phase }
        if phase != lastPhase {
            lastPhase = phase
            switch phase {
            case .working(let s):
                FileHandle.standardOutput.write(Data("  \(s)\n".utf8))
            case .failed(let m):
                FileHandle.standardError.write(Data("FAILED: \(m)\n".utf8))
                settled = true
                exit(1)
            case .idle:
                break
            }
        }
    }
    exit(settled ? 0 : 1)
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
