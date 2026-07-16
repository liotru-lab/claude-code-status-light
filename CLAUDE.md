# CC Status Light — code conventions

Code-level conventions for this repo. Higher-level product scope, anti-patterns,
and constraints live in a separate hub document maintained by the maintainers.

> Note: that hub document is **not released** and is **not available to clones or
> forks** — it lives outside this repository. This file must stay consistent with
> it, but you won't find it here.

## Project shape

- Swift + SwiftUI, minimum macOS 15. Language mode: Swift 5 (`SWIFT_VERSION 5.0`).
  (macOS 15 guarantees `/usr/bin/jq`, which the hook scripts rely on.)
- Xcode project is **generated** from `project.yml` via XcodeGen. Never hand-edit
  `CCStatusLight.xcodeproj` — edit `project.yml` and run `xcodegen generate`.
  The `.xcodeproj` and the generated `Info.plist` are git-ignored.
- Bundle id: `com.liotru-lab.claude-code-status-light`. Display name: "CC Status Light".

## App structure

- Classic AppKit entry (`main.swift`) — no SwiftUI `App`/`Scene`. The window is a
  plain `NSWindow` created in `AppDelegate`, hosting SwiftUI via
  `NSHostingController`. This keeps the POC window rules exact:
  - `applicationShouldTerminateAfterLastWindowClosed` → `false`
  - `applicationShouldHandleReopen` reopens the window (dock-click)
  - `isReleasedWhenClosed = false` so the same window instance is reused
  - "Show on all Spaces" flips `NSWindow.collectionBehavior.canJoinAllSpaces`
    (see `WindowState`), persisted in `UserDefaults`.
- Keep view state in small `@MainActor` `ObservableObject`s (`SessionStore`,
  `WindowState`, `EnvironmentStore`, `CallbackSettings`).
- A second `NSWindow` (Preferences, ⌘,) is created lazily in `AppDelegate`,
  hosting `PreferencesView` — same NSHostingController pattern as the main window.

## Session state — hybrid (hooks for liveness, JSONL for state)

- **Hooks provide liveness + a pointer.** `hooks/cc-status-light-hook.sh` writes a
  marker at `~/Library/Application Support/CCStatusLight/state/<session-id>.json`
  containing `session_id`, `transcript_path`, `pid`, `cwd`, a coarse fallback
  `state`, and `timestamp` (`Marker` in `Session.swift`). SessionStart marks a
  session live; SessionEnd marks it `ended`.
- **The transcript is the source of truth for state.** `TranscriptParser`
  incrementally tails `<session-id>.jsonl` and runs the ported state machine:
  track `Agent` tool_use ids → keep `working` while subagents run (sync removed on
  `completed` tool_result; async removed on a `queue-operation` completion
  notification); `end_turn`+question → attention; `turn_duration`/`idle_prompt`
  safety nets. It also reads the display name (`custom-title` › `ai-title` › `slug`).
- `SessionScanner` (off the main thread) reads markers, checks `pid` liveness
  (`kill(pid,0)`), tails transcripts via cached parsers, prunes stale markers, and
  composes `Session`s. `SessionStore` (@MainActor) polls it once a second **and**
  re-scans on demand: a `DispatchSource` vnode watch on the state dir fires
  `refresh()` (debounced ~150ms) on every hook event — each hook writes its marker
  via `mktemp` + `mv -f`, an atomic rename the watch sees — so state tracks hooks in
  ~0.15s instead of up to a poll interval. The poll is the fallback for
  transcript-only changes that fire no hook (e.g. a subagent finishing mid-turn).
  Tapping a row also calls `refresh()` as a manual force-parse.
- Five UI states (`SessionState`): `ready`, `working`, `notification`, `idle`,
  `ended`. `ready`/`ended` come from lifecycle; the rest are derived from the
  transcript. Verify the parser with `CCStatusLight --parse <transcript.jsonl>`.
- The per-event hook `state` values are now only a fallback (used if the transcript
  can't be read). Keep the hook's states and `SessionState` in sync.

## Status detail & account panel

- `TranscriptParser` also captures per-session detail — `model`, Claude Code
  `version`, `gitBranch`, `permissionMode`, `contextTokens` (point-in-time context
  window in use) — exposed as `SessionDetail` (`Session.swift`) and shown in an
  **expandable row** (`SessionDetailView`). A cumulative **cost** estimate was
  tried and removed: Claude Code writes one message as several JSONL lines and
  bills from a source the transcript doesn't reproduce, so it couldn't be
  reconciled with `/status`. Don't re-add a transcript-derived cost.
- `EnvironmentStatus`/`EnvironmentStore` read (**read-only**) `~/.claude.json`
  (`oauthAccount`) and `~/.claude/stats-cache.json` for the footer **account
  panel** (`EnvironmentView`): identity + lifetime usage. Never write those files,
  never surface tokens. The live `/status` rate-limit bars are **not** available
  locally (server-side; the account token is Keychain-locked) — don't attempt them.
- Debug harnesses: `CCStatusLight --parse <transcript.jsonl>` (state + detail) and
  `CCStatusLight --env` (account panel data).

## Callbacks (aggregate state → command)

- `CallbackEngine` (@MainActor) subscribes to `SessionStore.$sessions`, derives one
  **aggregate** state with its own urgency order — **Attention > Working > Ready >
  Idle > none** (distinct from the list-sort priority) — and runs a user command on
  change, debounced ~400ms. `CallbackCommand` is the shared runner (`/bin/bash -c`,
  PATH includes `~/.local/bin` so `busylight` resolves), used by the engine and the
  Preferences **Test** button. Placeholders: `{state} {color} {count} {name}`.
- Config is `CallbackConfig` at
  `~/Library/Application Support/CCStatusLight/callbacks.json` (our dir → clean
  uninstall), **disabled by default**; a rotating fire log sits next to it at
  `callbacks.log`. The engine reloads on mtime change. `CallbackSettings` +
  `PreferencesView` edit it (auto-save). Presets: busylight, notification, sound.
- Same anti-patterns hold: never write `~/.claude.json`/`settings.json`, no
  LaunchAgent. Callback commands are user-defined (like hooks).

## Hooks

- `install-hooks.sh` is the only thing that writes `~/.claude/settings.json`, and
  only after showing a diff, backing up, and confirming. It must stay idempotent
  and its `--uninstall` must remove only our own entries. Never write
  `~/.claude.json`, never register a plugin, never install a LaunchAgent.
