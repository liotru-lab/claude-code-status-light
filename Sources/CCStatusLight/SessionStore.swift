import Foundation
import Combine

/// Scans the hook marker directory + tails each live transcript, off the main
/// thread. Owns one TranscriptParser per session (incremental cursor preserved
/// across scans). All disk work happens on `queue`; results are delivered on main.
final class SessionScanner {
    private let directory: URL
    private let queue = DispatchQueue(label: "net.liotru.ccstatuslight.scanner")
    private var parsers: [String: TranscriptParser] = [:]

    /// Grace period before a stale (ended / crashed) marker is pruned.
    private static let staleGrace: TimeInterval = 600

    init(directory: URL) { self.directory = directory }

    func scan(completion: @escaping ([Session]) -> Void) {
        queue.async {
            let sessions = self.scanSync()
            DispatchQueue.main.async { completion(sessions) }
        }
    }

    private func scanSync() -> [Session] {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let now = Date()

        let files = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        var result: [Session] = []
        var seen = Set<String>()

        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let marker = try? decoder.decode(Marker.self, from: data) else { continue }
            seen.insert(marker.sessionId)

            let ended = marker.state == .ended
            let alive = Self.isAlive(marker.pid)

            // Prune stale markers (cleanly ended, or crashed) past the grace period.
            if (ended || !alive), let ts = marker.timestamp,
               now.timeIntervalSince(ts) > Self.staleGrace {
                try? fm.removeItem(at: url)
                continue
            }

            // Resolve + tail the transcript.
            var parser: TranscriptParser?
            if let transcript = resolveTranscript(marker, fm: fm) {
                if let existing = parsers[marker.sessionId], existing.url == transcript {
                    parser = existing
                } else {
                    let fresh = TranscriptParser(url: transcript)
                    parsers[marker.sessionId] = fresh
                    parser = fresh
                }
                parser?.update()
            }

            // Compose state.
            let state: SessionState
            let activity: String
            let subagents: Int
            let live: Bool
            if ended {
                state = .ended; activity = ""; subagents = 0; live = false
            } else if !alive {
                state = .ended; activity = "exited"; subagents = 0; live = false
            } else if let p = parser {
                state = p.sessionState; activity = p.activity
                subagents = p.subagentCount; live = true
            } else {
                state = marker.state ?? .idle; activity = marker.event ?? ""
                subagents = 0; live = true
            }

            let name = parser?.nameFromTranscript ?? Session.shortId(marker.sessionId)

            result.append(Session(id: marker.sessionId, displayName: name,
                                  state: state, activity: activity,
                                  cwd: marker.cwd, subagentCount: subagents, live: live))
        }

        // Drop parsers for sessions that vanished.
        parsers = parsers.filter { seen.contains($0.key) }

        result.sort { lhs, rhs in
            if lhs.state.priority != rhs.state.priority {
                return lhs.state.priority < rhs.state.priority
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return result
    }

    /// Marker's transcript_path if it exists, else search ~/.claude/projects/*/<id>.jsonl.
    private func resolveTranscript(_ marker: Marker, fm: FileManager) -> URL? {
        if let path = marker.transcriptPath, !path.isEmpty, fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let projects = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(marker.sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// A pid of 0/unknown is treated as alive (don't hide a session we can't check).
    private static func isAlive(_ pid: Int32?) -> Bool {
        guard let pid, pid > 0 else { return true }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Publishes the current session list for the UI. Hooks-only discovery of *which*
/// sessions are live; the transcript supplies accurate state, names, and subagents.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    nonisolated static var stateDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base
            .appendingPathComponent("CCStatusLight", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
    }

    private let scanner: SessionScanner
    private var timer: Timer?

    init(directory: URL = SessionStore.stateDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scanner = SessionScanner(directory: directory)
        refresh()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    func refresh() {
        scanner.scan { [weak self] sessions in
            self?.sessions = sessions
        }
    }
}
