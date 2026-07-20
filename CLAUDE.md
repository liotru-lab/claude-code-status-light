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
- **"Waiting on the user" is sticky, and lives in the marker, not the transcript**
  (`waiting_since`). Every hook event overwrites the marker and the last writer
  wins, so a *background agent's* `PostToolUse` used to erase the fact that the
  main thread was blocked on a prompt — leaving the row `working` indefinitely,
  since no later event corrects it (fixed in 0.5.2). The transcript cannot rescue
  this: **Claude Code doesn't flush a pending `AskUserQuestion` tool_use until it
  is answered**, so a currently-open question is simply absent from the JSONL.
  The hook therefore carries `waiting_since` across unrelated events and clears it
  only on `UserPromptSubmit`/`Stop`/`SessionEnd`/`SessionStart`. Never expire it on
  a timer — answering can take many minutes. In the app it **outranks the
  transcript state**: waiting beats agent activity, because the user is the
  bottleneck (agents finish on their own; nothing proceeds until you answer).
- **A pending question is cleared by its own tool_result** (`pendingQuestionId`).
  `AskUserQuestion`/`ExitPlanMode` set `.waiting`; the matching tool_result means
  the user answered, so the parser moves to `working`/"thinking". Without it the
  row stayed red until the *next assistant message* — and Claude's thinking phase
  writes nothing to the transcript, so that could be minutes (fixed in 0.3.2).
  Note the general shape of this class of bug: **a silent transcript is not an
  idle session**, so never infer state from absence of lines.
- **Async agents are tracked separately** (`asyncAgents ⊆ activeAgents`). A
  background agent's tool_result arrives *immediately* at launch carrying
  `toolUseResult.isAsync` — it's a launch ack, not a completion — so it must not
  clear the agent. Critically, the `turn_duration` safety net may only drop **sync**
  agents (`formIntersection(asyncAgents)`): background agents outlive the
  orchestrator's turn, and wiping them there made a session with three running
  agents read `idle` (fixed in 0.3.1). Only a completion notification clears them.
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

## Update check

- `UpdateChecker` (@MainActor) GETs the public GitHub *latest release* endpoint and
  compares `tag_name` with `CFBundleShortVersionString`. Comparison is
  **component-wise numeric** (`isNewer`), so 0.3.10 > 0.3.9 — a string compare gets
  that backwards. Verify with `CCStatusLight --check-update`.
- **Automatic checking is off by default** (`UserDefaults` `checkForUpdatesAutomatically`);
  when enabled it checks on launch then daily. The **Check for Updates…** menu item
  always works, since the user asked for it explicitly.
- The check itself sends no identifiers, counters, or query params — a one-way
  version lookup, which is why it isn't the "telemetry / phone-home" the
  constraints forbid.

## In-app update (`SelfUpdater`)

- **Update Now** (banner, Preferences, and the Check-for-Updates alert) installs
  the release in place. An app can't overwrite its own running bundle, so it does
  what `install.sh` does: download → verify → write a one-shot helper script →
  quit → the helper waits for the process to exit, swaps the bundle, relaunches,
  and deletes itself. **Nothing persistent is installed** — no LaunchAgent, no
  daemon, no login item — so clean-uninstall still holds.
- **Verification is load-bearing and must never be weakened.** Downloaded code is
  only safe if we prove its origin, so the payload must satisfy a designated
  requirement pinned to the team (`certificate leaf[subject.OU] = 38LKT4ZSN5`)
  *and* pass `spctl` as a **Notarized Developer ID**. Both run before anything on
  disk is touched; either failing aborts with the install untouched.
  Note the team pin alone is **not** sufficient — an Apple Development build
  carries the same team OU, so it's the notarization check that rejects non-release
  builds. Tampering trips the sealed-resource check; a third-party re-sign trips
  the requirement. All three cases are verified.
- **Re-register with LaunchServices after swapping the bundle.** Replacing an app
  at an existing path leaves LaunchServices holding a stale record, and `open`
  then fails *silently with rc=0* — the update succeeds but the app never comes
  back (fixed in 0.5.1). Both the helper and `install.sh` run `lsregister -f` on
  the destination, then verify the process actually appears and fall back to
  launching the executable directly. Any future code that replaces the bundle in
  place must do the same.
- Exercise the whole path headlessly with `CCStatusLight --self-update`
  (`SelfUpdater.onHandoff` is the seam that lets it run without an NSApplication).

## Hooks

- `install-hooks.sh` is the only thing that writes `~/.claude/settings.json`, and
  only after showing a diff, backing up, and confirming. It must stay idempotent
  and its `--uninstall` must remove only our own entries. Never write
  `~/.claude.json`, never register a plugin, never install a LaunchAgent.
