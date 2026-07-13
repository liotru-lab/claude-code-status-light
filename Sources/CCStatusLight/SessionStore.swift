import Foundation
import Combine

/// Reads per-session state files from the shared state directory and republishes
/// them as a sorted list. POC discovery is "hooks only": the app never scans
/// processes or parses JSONL — it only reads what the hook script writes.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    /// ~/Library/Application Support/CCStatusLight/state
    nonisolated static var stateDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base
            .appendingPathComponent("CCStatusLight", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
    }

    private let directory: URL
    private var timer: Timer?
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(directory: URL = SessionStore.stateDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        reload()
        // POC: poll once a second. Cheap for the handful of files involved;
        // a directory watcher is future work.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        var result: [Session] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(Session.self, from: data)
            else { continue }
            result.append(session)
        }

        result.sort { lhs, rhs in
            if lhs.state.priority != rhs.state.priority {
                return lhs.state.priority < rhs.state.priority
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        sessions = result
    }
}
