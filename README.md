# CC Status Light

A tiny native macOS app that shows the status of your running Claude Code
sessions in a single window. Proof of concept.

- Native macOS (Swift + SwiftUI, AppKit-managed window)
- One window listing every known session with its name and current state
- Closing the window does **not** quit the app — it keeps running and the
  dock icon reopens the window
- Optional **"Show on all Spaces"** toggle
- **Hybrid discovery:** lightweight hooks mark which sessions are live (and point
  at each transcript); the app tails the session's JSONL transcript to derive
  accurate state — including **subagent awareness** (a session with running
  subagents reads as *working*, not *idle*) and the real **session name**
  (`custom-title` › `ai-title` › `slug`). The right-hand label shows live
  activity (the current tool, `Thinking`, `Subagents`, `Compacting`, …).

> Status: POC. Not signed, not notarized, not distributed.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16+ (built and tested with Xcode 26)
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- [`jq`](https://jqlang.github.io/jq/) — `brew install jq` (used by the hook)

## Build & run

```sh
xcodegen generate                 # regenerates CCStatusLight.xcodeproj from project.yml
xcodebuild -project CCStatusLight.xcodeproj \
           -target CCStatusLight -configuration Debug build
open "$(xcodebuild -project CCStatusLight.xcodeproj -target CCStatusLight \
        -configuration Debug -showBuildSettings \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}')"
```

Or just open `CCStatusLight.xcodeproj` in Xcode and press Run.

`CCStatusLight.xcodeproj` is generated and git-ignored — always run
`xcodegen generate` after cloning or editing `project.yml`.

## Hooks

The app only shows what the hooks report. Install them **opt-in**:

```sh
./hooks/install-hooks.sh          # shows a diff of ~/.claude/settings.json,
                                  # backs it up, then asks before writing
```

This wires six Claude Code hook events to `hooks/cc-status-light-hook.sh`:

| Hook event         | State written  |
| ------------------ | -------------- |
| `SessionStart`     | `ready`        |
| `UserPromptSubmit` | `working`      |
| `PostToolUse`      | `working`      |
| `Notification`     | `idle` if it's a waiting nudge (`idle_prompt`); `notification` for permission/elicitation prompts |
| `PermissionRequest`| `notification` |
| `Stop`             | `idle`         |

The `Notification` event is overloaded — Claude Code fires it both when a session
is just waiting for you and when it genuinely needs attention. The hook inspects
the payload's `notification_type` so a plain waiting nudge reads as calm `idle`,
and only real permission/elicitation prompts turn the row red.
| `SessionEnd`       | `ended`        |

The hook writes one file per session:

```
~/Library/Application Support/CCStatusLight/state/<session-id>.json
```

```json
{
  "session_id": "e901f0eb-…",
  "state": "working",
  "cwd": "/Users/you/Projects/foo",
  "event": "UserPromptSubmit",
  "timestamp": "2026-07-13T20:39:55Z"
}
```

Prefer to wire it by hand? Add command hooks in `~/.claude/settings.json` that
run `.../cc-status-light-hook.sh <state>` for each event above. Run
`./hooks/install-hooks.sh --print` to see the exact JSON it would produce.

## Uninstall — leaves zero residue

```sh
./hooks/install-hooks.sh --uninstall            # removes only our hook entries
rm -rf "$HOME/Library/Application Support/CCStatusLight"   # state + prefs dir
rm -rf CCStatusLight.app                         # or wherever you copied it
```

That's everything. No plugin, no LaunchAgent, no writes to `~/.claude.json`.

## License

MIT — see [LICENSE](LICENSE).
