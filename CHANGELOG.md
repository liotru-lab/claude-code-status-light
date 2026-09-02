# Changelog

All notable changes to CC Status Light. Format follows
[Keep a Changelog](https://keepachangelog.com/); this project uses
[semantic-ish versioning](https://semver.org/) (minor = features, patch = fixes).

## [0.6.0] — 2026-09-02

### Added
- **Plan usage panel.** A footer gauge shows your plan's **session and weekly
  limit bars** — the same numbers as Claude's Settings ▸ Usage (Pro, Max, or
  Team), which nothing local otherwise exposes. Off by default; the gauge doubles
  as the on-switch, with a disclosure of exactly what enabling does before it
  reads anything. It reads your Claude Code login from the keychain (read-only)
  and talks only to `api.anthropic.com`. Background refreshes are silent while the
  token is valid; the keychain is re-read (which can prompt) only when a session
  has been active recently — otherwise it pauses rather than interrupting you.
  Declining the prompt stops it re-asking. Refresh interval and activity window
  are configurable.
- **Session cleanup.** Right-click a row → **Remove from List**, and auto-clean
  idle sessions after a delay (default 1 day; configurable). Working and
  waiting-on-you sessions are never removed, and a hidden session reappears the
  moment it becomes active again.
- **Tabbed Settings** — Callbacks · Sessions · Usage · Updates.

### Fixed
- A session whose last action was an inline `!` bash command (or a slash command)
  could be stuck reading **"thinking"** forever — those terminal echoes are no
  longer mistaken for prompts.

## [0.5.4] — 2026-07-20

### Fixed
- A session stayed **"waiting for you"** (red) after you answered a permission
  prompt, until its next message — now clears as soon as work resumes.

## [0.5.3] — 2026-07-20

### Added
- Detects when the installed hook is **out of date** and offers a one-click
  refresh, so app-and-hook fixes don't silently half-apply.

## [0.5.2] — 2026-07-20

### Fixed
- A session running **background agents** was wrongly shown as idle instead of
  working.

## [0.5.1] — 2026-07-19

### Fixed
- The app didn't relaunch after an in-app update (it swapped correctly but stayed
  closed).

## [0.5.0] — 2026-07-19

### Added
- **In-app update.** "Update Now" downloads the release, **verifies its signature
  and Apple notarization**, then swaps the app and restarts. The install
  one-liner also doubles as a safe updater.

## [0.4.0] — 2026-07-19

### Added
- **Opt-in update check** — asks GitHub whether a newer release exists. Off by
  default; notify-only, no telemetry.

## [0.3.2] — 2026-07-19

### Fixed
- A session stayed in **Attention** after you'd answered its question.

## [0.3.1] — 2026-07-18

### Fixed
- Background (async) subagents were cleared too early, so a session with agents
  still running read as **idle**.

## [0.3.0] — 2026-07-16

### Added
- **Event-driven state** — the list updates within ~0.15s of a hook event instead
  of on a slow poll. Click a row to force an immediate re-parse.

## [0.2.0] — 2026-07-14

### Added
- **Per-session detail** in an expandable row — model, Claude Code version, git
  branch, permission mode, and context-window tokens in use.
- **Account & lifetime-usage panel** in the footer.
- **Callbacks** — run any command when the aggregate state changes (busylight,
  notification, sound, webhook…), edited in Preferences, with a rotating fire log.

## [0.1.3] — 2026-07-14

### Fixed
- Releases reported the wrong version number.

## [0.1.2] — 2026-07-14

### Changed
- Rewrote the README and added a `curl | bash` installer; minimum macOS bumped to
  15 (guarantees `jq`).

### Fixed
- A hook command path containing spaces broke in `settings.json`.

## [0.1.1] — 2026-07-14

### Added
- In-app **"Install Hooks…"** with a hook-installed status indicator.

### Fixed
- Hook uninstall matches by script name; the menu checkmark reflects real status.

## [0.1.0] — 2026-07-14

### Added
- Initial release: a single window of running Claude Code sessions with accurate,
  subagent-aware state from each JSONL transcript, real session names, a live
  activity phrase, and the working directory. Opt-in hooks, About panel, and a
  local notarized-release pipeline.
