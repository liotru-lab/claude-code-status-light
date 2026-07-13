import SwiftUI

extension SessionState {
    /// Status colour. Matches the busylight convention:
    /// ready=blue, working=yellow, notification=red, idle=green, ended=gray.
    var color: Color {
        switch self {
        case .ready:        return .blue
        case .working:      return .yellow
        case .notification: return .red
        case .idle:         return .green
        case .ended:        return .gray
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var windowState: WindowState

    var body: some View {
        VStack(spacing: 0) {
            if store.sessions.isEmpty {
                emptyState
            } else {
                List(store.sessions) { session in
                    SessionRow(session: session)
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .frame(minWidth: 360, minHeight: 300)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No sessions yet")
                .font(.headline)
            Text("Install the hooks, then start a Claude Code session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack {
            Toggle("Show on all Spaces", isOn: $windowState.showOnAllSpaces)
                .toggleStyle(.checkbox)
            Spacer()
            Text(store.sessions.count == 1 ? "1 session" : "\(store.sessions.count) sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.state.symbolName)
                .foregroundStyle(session.state.color)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName)
                    .font(.body)
                    .lineLimit(1)
                if let cwd = session.cwd, !cwd.isEmpty {
                    Text(abbreviate(cwd))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()

            Text(session.state.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(session.state.color)
        }
        .padding(.vertical, 2)
    }

    /// Replace the home directory prefix with `~` for a shorter path.
    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
