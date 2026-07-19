import SwiftUI
import AppKit

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
    @EnvironmentObject var environment: EnvironmentStore
    @EnvironmentObject var windowState: WindowState
    @EnvironmentObject var updates: UpdateChecker
    @State private var showLegend = false
    @State private var showEnvironment = false
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if store.sessions.isEmpty {
                emptyState
            } else {
                List(store.sessions) { session in
                    SessionRow(session: session,
                               isExpanded: expandedBinding(session.id),
                               onRefresh: { store.refresh() })
                }
                .listStyle(.inset)
            }
            if updates.shouldNotify, let latest = updates.latestVersion {
                Divider()
                updateBanner(latest)
            }
            Divider()
            footer
        }
        .frame(minWidth: 200, minHeight: 200)
    }

    /// Quiet, dismissible notice — informational, never a modal interruption.
    private func updateBanner(_ latest: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
            Text("Version \(latest) available")
                .font(.caption.weight(.medium))
            Link("Release notes", destination: UpdateChecker.releasesPage)
                .font(.caption)
            Spacer()
            Button {
                updates.dismissCurrent()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss until the next version")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { on in if on { expanded.insert(id) } else { expanded.remove(id) } }
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if store.hooksInstalled {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No active sessions")
                    .font(.headline)
                Text("Start a Claude Code session and it'll appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Hooks not installed")
                    .font(.headline)
                Text("Wire up Claude Code so it reports its sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Install Hooks…") {
                    NSApp.sendAction(#selector(AppDelegate.installHooks(_:)), to: nil, from: nil)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle("All Spaces", isOn: $windowState.showOnAllSpaces)
                .toggleStyle(.checkbox)
                .lineLimit(1)
                .fixedSize()
                .help("Show the window on all Spaces")
            Spacer(minLength: 6)
            Text(store.sessions.count == 1 ? "1 session" : "\(store.sessions.count) sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Button {
                if !showEnvironment { environment.refresh() }
                showEnvironment.toggle()
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .buttonStyle(.borderless)
            .help("Claude Code account & lifetime usage")
            .popover(isPresented: $showEnvironment, arrowEdge: .bottom) {
                EnvironmentView(status: environment.status)
            }
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

/// Account identity + lifetime usage (from ~/.claude.json + stats-cache.json).
/// The live rate-limit bars from `/status` aren't shown — that data isn't
/// stored locally (see `EnvironmentStatus`).
struct EnvironmentView: View {
    let status: EnvironmentStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !status.hasAny {
                Text("No account data").font(.headline)
                Text("Sign in to Claude Code so `~/.claude.json` is populated.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                account
                Divider()
                lifetime
                if !status.models.isEmpty {
                    Divider()
                    byModel
                }
                Text("Live rate-limit usage isn't shown — Claude Code fetches it from Anthropic and it isn't stored on disk.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(status.displayName ?? status.email ?? "Account").font(.headline)
            if status.displayName != nil, let e = status.email {
                Text(e).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let o = status.organization { row("Organization", o) }
            if let r = status.role { row("Role", r.capitalized) }
            if let p = status.planLabel { row("Plan", p) }
        }
    }

    private var lifetime: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Lifetime").font(.subheadline.weight(.semibold))
            if let s = status.totalSessions { row("Sessions", "\(s)") }
            if let m = status.totalMessages { row("Messages", SessionDetailView.fmt(m)) }
            if let d = status.memberSince { row("Since", Self.month.string(from: d)) }
            if let l = status.longestSessionMessages { row("Longest", "\(l) messages") }
        }
    }

    private var byModel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Tokens by model").font(.subheadline.weight(.semibold))
            ForEach(status.models.prefix(5)) { m in
                row(SessionDetailView.friendlyModel(m.model), SessionDetailView.fmt(m.totalTokens))
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value).font(.caption)
            Spacer(minLength: 0)
        }
    }

    static let month: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"; return f
    }()
}

struct SessionRow: View {
    let session: Session
    @Binding var isExpanded: Bool
    /// Force an immediate re-parse when tapped — a manual escape hatch when a row
    /// looks stuck between the 1s poll ticks. Works on any row, not just expandable.
    var onRefresh: () -> Void = {}

    /// Whether there's detail worth expanding to.
    private var expandable: Bool { session.detail?.hasAny == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(expandable ? 1 : 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                onRefresh()
                if expandable { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }
            }

            if isExpanded, let detail = session.detail {
                SessionDetailView(detail: detail)
                    .padding(.leading, 22)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
        }
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

/// The expandable per-session `/status`-style detail: model, CC version, branch,
/// context/output tokens, permission mode. Only rows with a value are shown.
struct SessionDetailView: View {
    let detail: SessionDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let m = detail.model { field("Model", Self.friendlyModel(m)) }
            if let v = detail.ccVersion { field("Claude Code", v) }
            if let b = detail.gitBranch { field("Branch", Self.friendlyBranch(b)) }
            if let pm = detail.permissionMode { field("Mode", Self.friendlyMode(pm)) }
            if let c = detail.contextTokens { field("Context", "~\(Self.fmt(c)) in use") }
        }
        .font(.caption)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// 193591 → "194k", 2859 → "2.9k", 640 → "640", 1_200_000 → "1.2M".
    static func fmt(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 {
            let k = Double(n) / 1000
            return k < 10 ? String(format: "%.1fk", k) : "\(Int(k.rounded()))k"
        }
        if n < 1_000_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        return String(format: "%.1fB", Double(n) / 1_000_000_000)
    }

    /// "claude-opus-4-8" → "Opus 4.8"; falls back to a title-cased id.
    static func friendlyModel(_ id: String) -> String {
        var s = id
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        // Drop trailing date stamps like "20251001".
        let comps: [String] = s.split(separator: "-").map(String.init)
            .filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        guard let family = comps.first else { return id }
        let version = comps.dropFirst().joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    static func friendlyBranch(_ b: String) -> String {
        b == "HEAD" ? "detached HEAD" : b
    }

    static func friendlyMode(_ m: String) -> String {
        switch m {
        case "default":           return "Default"
        case "acceptEdits":       return "Accept edits"
        case "plan":              return "Plan mode"
        case "bypassPermissions": return "Bypass permissions"
        default:                  return m
        }
    }
}
