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
    /// A `compacting` read older than this is treated as finished (idle). The
    /// `compact_boundary` line is written when compaction *completes*, so the
    /// session is already done compacting by the time we see it — this short grace
    /// only covers the gap before an auto-compact's resume turn starts writing.
    private static let compactingStale: TimeInterval = 15

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
            var state: SessionState
            var activity: String
            let subagents: Int
            let live: Bool
            if ended {
                state = .ended; activity = ""; subagents = 0; live = false
            } else if !alive {
                state = .ended; activity = "exited"; subagents = 0; live = false
            } else if let p = parser {
                state = p.sessionState; activity = p.activity
                subagents = p.subagentCount; live = true
                // Compaction is bounded (seconds). A session that reads
                // `compacting` but whose transcript has been silent for a while is
                // done — otherwise it sticks at working/yellow (a compact at the
                // end of a transcript with no following turn never settles).
                if p.isCompacting, let last = p.lastLineTime,
                   now.timeIntervalSince(last) > Self.compactingStale {
                    state = .idle; activity = ""
                }
            } else {
                state = marker.state ?? .idle; activity = marker.event ?? ""
                subagents = 0; live = true
            }

            // Overlay: a pending permission / elicitation prompt (which the
            // transcript alone can't reveal) is signalled by the hook writing
            // `notification` into the marker. Surface it as Attention — but only
            // while it's current. If the transcript has produced activity clearly
            // newer than the marker, the prompt was answered and work resumed, so
            // a live state must win over the stale marker. (2s tolerance absorbs
            // the marker's whole-second timestamp truncation.)
            // A sticky wait outranks everything the transcript can say. The user
            // is the bottleneck: background agents will finish on their own, but
            // nothing proceeds until the prompt is answered — so Attention beats
            // agent activity here. Cleared only by UserPromptSubmit/Stop/
            // SessionEnd (see the hook), never by a timeout, because answering
            // can legitimately take many minutes.
            // A permission prompt is resolved by approving it, which fires
            // PostToolUse -- not UserPromptSubmit -- so the hook alone can never
            // learn the wait ended. The transcript can: only the orchestrator
            // writes non-sidechain assistant messages (background agents emit
            // `queue-operation` notifications and their own sidechain files), so
            // a main-thread assistant message newer than the wait means the
            // prompt was answered and work resumed.
            var stillWaiting = false
            if live, let waitingSince = marker.waitingSince {
                if let resumed = parser?.lastMainAssistantTime {
                    stillWaiting = resumed <= waitingSince
                } else {
                    stillWaiting = true
                }
            }
            if stillWaiting {
                state = .notification
                activity = "waiting for you"
            } else if live, marker.state == .notification {
                let transcriptMovedOn: Bool
                if let last = parser?.lastLineTime, let mt = marker.timestamp {
                    transcriptMovedOn = last.timeIntervalSince(mt) > 2
                } else {
                    transcriptMovedOn = false
                }
                if !transcriptMovedOn {
                    state = .notification
                    activity = "permission"
                }
            }

            // Auto-clean: an idle session that's been quiet longer than the user's
            // threshold. Only idle/ready — never something working or waiting on
            // you — and it reappears if the (still-alive) session does anything
            // again, since the hook rewrites the marker.
            if live, state == .idle || state == .ready {
                let hours = SessionStore.autoCleanHours
                let lastActivity = parser?.lastLineTime ?? marker.timestamp
                if hours > 0, let last = lastActivity,
                   now.timeIntervalSince(last) > TimeInterval(hours) * 3600 {
                    try? fm.removeItem(at: url)
                    continue
                }
            }

            let name = parser?.nameFromTranscript ?? Session.shortId(marker.sessionId)
            let detail = live ? parser?.detail : nil

            result.append(Session(id: marker.sessionId, displayName: name,
                                  state: state, activity: activity,
                                  cwd: marker.cwd, subagentCount: subagents,
                                  live: live, detail: detail))
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
    @Published private(set) var hooksInstalled: Bool = HookStatus.isInstalled
    /// Staged hook differs from the one this build ships (see HookStatus.isStale).
    @Published private(set) var hooksStale: Bool = HookStatus.isStale

    nonisolated static var stateDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base
            .appendingPathComponent("CCStatusLight", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
    }

    // Auto-clean an idle session after this many hours of inactivity. 0 = never.
    // Unset defaults to 24h (a day). The scanner reads this each pass.
    nonisolated static let autoCleanHoursKey = "staleSessionHours"
    nonisolated static let autoCleanChoices = [0, 1, 4, 24]   // Never · 1h · 4h · 1 day
    nonisolated static var autoCleanHours: Int {
        UserDefaults.standard.object(forKey: autoCleanHoursKey) == nil
            ? 24 : UserDefaults.standard.integer(forKey: autoCleanHoursKey)
    }

    /// Hide a session from the list by deleting its marker. Non-destructive: it
    /// doesn't touch the session or its transcript, and a still-alive session
    /// reappears the next time it does anything (the hook rewrites the marker).
    func remove(_ sessionId: String) {
        let url = Self.stateDirectory.appendingPathComponent("\(sessionId).json")
        try? FileManager.default.removeItem(at: url)
        refresh()
    }

    private let scanner: SessionScanner
    private var timer: Timer?

    // Event-driven refresh: every hook writes its marker via mktemp + `mv -f`
    // (atomic rename = a directory-content change), so a vnode watch on the state
    // dir fires on every hook event. We re-scan immediately (debounced), instead
    // of waiting up to a full second for the poll. The poll stays as a fallback
    // for transcript-only changes that fire no hook (e.g. a subagent finishing
    // mid-turn).
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var watchDebounce: DispatchWorkItem?

    init(directory: URL = SessionStore.stateDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scanner = SessionScanner(directory: directory)
        refresh()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        startWatching(directory)
    }

    deinit {
        timer?.invalidate()
        dirSource?.cancel()
    }

    func refresh() {
        hooksInstalled = HookStatus.isInstalled
        hooksStale = HookStatus.isStale
        scanner.scan { [weak self] sessions in
            self?.sessions = sessions
        }
    }

    /// Watch the marker directory; coalesce the burst of vnode events a single
    /// `mv` produces into one refresh ~150ms later.
    private func startWatching(_ directory: URL) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.global(qos: .utility))
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleWatchRefresh() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    private func scheduleWatchRefresh() {
        watchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        watchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
