import SwiftUI

extension SessionState {
    /// Status colour. ready=blue, working=yellow, notification=red, idle=green, ended=gray.
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
    @State private var showLegend = false

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
        HStack(spacing: 8) {
            Toggle("Show on all Spaces", isOn: $windowState.showOnAllSpaces)
                .toggleStyle(.checkbox)
            Spacer()
            Text(store.sessions.count == 1 ? "1 session" : "\(store.sessions.count) sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                showLegend.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("What the statuses mean")
            .popover(isPresented: $showLegend, arrowEdge: .bottom) {
                LegendView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A small popover explaining the five statuses.
struct LegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Statuses")
                .font(.headline)
            ForEach(SessionState.legendOrder, id: \.self) { state in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: state.symbolName)
                        .foregroundStyle(state.color)
                        .font(.system(size: 11))
                        .frame(width: 14)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(state.color)
                        Text(state.legend)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            Label("Number of running subagents", systemImage: "person.2.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300)
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
                if let sub = subtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if session.subagentCount > 0 {
                Label("\(session.subagentCount)", systemImage: "person.2.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .help("\(session.subagentCount) subagent(s) running")
            }

            Text(statusLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(session.state.color)
        }
        .padding(.vertical, 2)
        .opacity(session.state == .ended ? 0.6 : 1)
    }

    /// The status text on the right: a friendly activity phrase when working,
    /// else the state label.
    private var statusLabel: String {
        if session.state == .working, !session.activity.isEmpty {
            return Self.friendly(session.activity)
        }
        return session.state.label
    }

    /// Map a raw activity (tool name or internal marker) to a human phrase.
    static func friendly(_ activity: String) -> String {
        switch activity {
        case "subagent":                  return "Subagents"
        case "thinking":                  return "Thinking"
        case "compacting":                return "Compacting"
        case "Bash":                      return "Running command"
        case "Edit", "MultiEdit", "NotebookEdit": return "Editing"
        case "Write":                     return "Writing"
        case "Read":                      return "Reading"
        case "Grep", "Glob":              return "Searching"
        case "WebFetch", "WebSearch":     return "Browsing the web"
        case "ToolSearch":                return "Finding tools"
        case "Task", "Agent":             return "Subagents"
        case "TodoWrite":                 return "Planning"
        case "AskUserQuestion", "ExitPlanMode": return "Asking"
        default:
            // MCP tools look like "mcp__server__tool"; anything else is a tool
            // name we didn't map — fall back to a calm generic.
            return "Working"
        }
    }

    /// Second line: the working directory, home-abbreviated.
    private var subtitle: String? {
        guard let cwd = session.cwd, !cwd.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }
}
