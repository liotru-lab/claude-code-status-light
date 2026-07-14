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
  `WindowState`).

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
  composes `Session`s. `SessionStore` (@MainActor) polls it once a second.
- Five UI states (`SessionState`): `ready`, `working`, `notification`, `idle`,
  `ended`. `ready`/`ended` come from lifecycle; the rest are derived from the
  transcript. Verify the parser with `CCStatusLight --parse <transcript.jsonl>`.
- The per-event hook `state` values are now only a fallback (used if the transcript
  can't be read). Keep the hook's states and `SessionState` in sync.

## Hooks

- `install-hooks.sh` is the only thing that writes `~/.claude/settings.json`, and
  only after showing a diff, backing up, and confirming. It must stay idempotent
  and its `--uninstall` must remove only our own entries. Never write
  `~/.claude.json`, never register a plugin, never install a LaunchAgent.
