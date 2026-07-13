# CC Status Light — code conventions

Code-level conventions for this repo only. Scope, anti-patterns, and constraints
live in the hub `CLAUDE.md` one directory up (`../CLAUDE.md`) — this file must
not contradict it.

## Project shape

- Swift + SwiftUI, minimum macOS 14. Language mode: Swift 5 (`SWIFT_VERSION 5.0`).
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

## Session state

- Source of truth on disk: `~/Library/Application Support/CCStatusLight/state/<session-id>.json`,
  one single-object JSON file per session, written by our hook.
- Five states only: `ready`, `working`, `notification`, `idle`, `ended`
  (`SessionState`). The event→state mapping lives in `hooks/cc-status-light-hook.sh`
  and its installer — keep those and `SessionState` in sync.
- `SessionStore` reads the directory (hooks-only discovery — no process scan, no
  JSONL parsing) and polls once a second. On-disk field names are snake_case;
  decode with `.convertFromSnakeCase` + `.iso8601`.

## Hooks

- `install-hooks.sh` is the only thing that writes `~/.claude/settings.json`, and
  only after showing a diff, backing up, and confirming. It must stay idempotent
  and its `--uninstall` must remove only our own entries. Never write
  `~/.claude.json`, never register a plugin, never install a LaunchAgent.
