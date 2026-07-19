import Foundation
import AppKit

/// Installs a newer release in place, on explicit user request.
///
/// An app cannot overwrite its own bundle while running, so this does what
/// `install.sh` does and hands the swap to a one-shot helper: download → verify →
/// write a small script → quit → the script waits for us to exit, replaces the
/// bundle, relaunches, and deletes itself. Nothing persistent is installed — no
/// LaunchAgent, no daemon, no login item — so the clean-uninstall rule still
/// holds, and none of it runs unless the user clicks Update.
///
/// **The verification step is the load-bearing part.** Downloading code and
/// executing it is only safe if we prove where it came from, so the payload must
/// satisfy a designated requirement pinned to this project's Apple team *and*
/// carry a notarization ticket. Either check failing aborts before anything on
/// disk is touched.
@MainActor
final class SelfUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    var isBusy: Bool { if case .working = phase { return true } else { return false } }
    var failure: String? { if case .failed(let m) = phase { return m } else { return nil } }

    /// Apple Developer team that legitimately signs CC Status Light. The download
    /// must chain to this — "is signed" alone would accept anyone's signature.
    private static let teamID = "38LKT4ZSN5"

    private struct Failure: Error { let message: String }

    /// What to do once the helper is launched. Overridable so `--self-update`
    /// can exercise the real path without an NSApplication running.
    var onHandoff: () -> Void = { NSApp.terminate(nil) }

    func reset() { phase = .idle }

    /// Download `assetURL`, verify it, then restart into the new version.
    func update(from assetURL: URL) {
        guard !isBusy else { return }
        phase = .working("Downloading…")
        let destination = Bundle.main.bundleURL

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let temp = try Self.makeTempDirectory()
                let zip = temp.appendingPathComponent("update.zip")
                let payload = try Data(contentsOf: assetURL)
                try payload.write(to: zip)

                Task { @MainActor in self?.phase = .working("Verifying signature…") }

                let unpacked = temp.appendingPathComponent("unpacked")
                let (unzipCode, _) = Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
                guard unzipCode == 0 else { throw Failure(message: "Couldn't unpack the download.") }

                guard let newApp = Self.findApp(in: unpacked) else {
                    throw Failure(message: "The download didn't contain CCStatusLight.app.")
                }
                try Self.verify(newApp)

                let helper = try Self.writeHelper(source: newApp,
                                                  destination: destination,
                                                  temp: temp)
                Task { @MainActor in
                    self?.phase = .working("Restarting…")
                    Self.launchDetached(helper)
                    // Let the helper start watching before we go away.
                    let handoff = self?.onHandoff
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { handoff?() }
                }
            } catch {
                let message = (error as? Failure)?.message ?? error.localizedDescription
                Task { @MainActor in self?.phase = .failed(message) }
            }
        }
    }

    // MARK: - Verification

    /// Reject anything not signed by this project's team and notarized by Apple.
    /// Runs before a single byte of the existing install is touched.
    private static func verify(_ app: URL) throws {
        let requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        let (signCode, signOut) = run("/usr/bin/codesign",
                                      ["--verify", "--strict", "-R", requirement, app.path])
        guard signCode == 0 else {
            throw Failure(message: """
                Signature check failed — the download isn't signed by CC Status Light's \
                developer, so it was discarded. Your installed copy is untouched.
                \(signOut.trimmingCharacters(in: .whitespacesAndNewlines))
                """)
        }

        let (gateCode, gateOut) = run("/usr/sbin/spctl", ["-a", "-t", "exec", "-vv", app.path])
        guard gateCode == 0, gateOut.contains("Notarized Developer ID") else {
            throw Failure(message: """
                Notarization check failed — the download isn't a notarized release, \
                so it was discarded. Your installed copy is untouched.
                """)
        }
    }

    // MARK: - Handoff

    /// The swap script. It waits for this process to exit before replacing the
    /// bundle, because overwriting a running .app leaves the live process on a
    /// stale inode.
    private static func writeHelper(source: URL, destination: URL, temp: URL) throws -> URL {
        let script = """
        #!/bin/bash
        # One-shot CC Status Light updater. Deletes itself when done.
        src=\(shellQuote(source.path))
        dst=\(shellQuote(destination.path))
        tmp=\(shellQuote(temp.path))

        # Wait for the old app to exit (up to ~30s), then swap.
        for _ in $(seq 1 150); do
          /usr/bin/pgrep -f "$dst/Contents/MacOS/" >/dev/null 2>&1 || break
          sleep 0.2
        done

        /bin/rm -rf "$dst" || exit 1
        /usr/bin/ditto "$src" "$dst" || exit 1

        # Replacing the bundle at an existing path leaves LaunchServices holding a
        # stale record for it, and `open` then fails (silently, with rc=0) against
        # the entry that no longer matches. Re-register before relaunching.
        lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
        [ -x "$lsregister" ] && "$lsregister" -f "$dst" >/dev/null 2>&1

        # Relaunch, and verify it actually came up — a failed relaunch would leave
        # the user staring at nothing after a successful update.
        /usr/bin/open "$dst" || /usr/bin/open -a "$dst" || true
        for _ in $(seq 1 25); do
          /usr/bin/pgrep -f "$dst/Contents/MacOS/" >/dev/null 2>&1 && break
          sleep 0.2
        done
        if ! /usr/bin/pgrep -f "$dst/Contents/MacOS/" >/dev/null 2>&1; then
          # Last resort: launch the executable directly.
          "$dst/Contents/MacOS/CCStatusLight" >/dev/null 2>&1 &
        fi

        /bin/rm -rf "$tmp"
        """
        let url = temp.appendingPathComponent("update-helper.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Start the helper so it outlives us — once we terminate it is reparented
    /// and keeps running long enough to finish the swap.
    private static func launchDetached(_ helper: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helper.path]
        try? process.run()
    }

    // MARK: - Helpers

    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCStatusLightUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func findApp(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: nil) else { return nil }
        if let direct = entries.first(where: { $0.lastPathComponent == "CCStatusLight.app" }) {
            return direct
        }
        // Some archives nest the app one level down.
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let nested = findApp(in: entry) { return nested }
        }
        return nil
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
