# CC Status Light

A tiny native macOS app that shows what your running Claude Code sessions are
doing — one row each, in a single window. Proof of concept.

Native Swift + SwiftUI (AppKit-managed window), signed with a Developer ID and
notarized.

## What it shows

One row per session: its name, live state, the current activity when working
(Editing, Reading, Running command, Thinking, Subagents, Compacting…), a subagent
count, and the working directory.

| State | Meaning |
| ------ | ------- |
| **Ready** | Session started, waiting for you |
| **Working** | Actively running (tools, thinking, subagents, compacting) |
| **Attention** | Needs you — a permission or elicitation prompt |
| **Idle** | Finished its turn, nothing pending |
| **Ended** | Session closed |

State comes from tailing each session's JSONL transcript — including subagent
awareness (a session with running subagents reads as *working*) and the real
session name (`custom-title` › `ai-title` › `slug`). Lightweight hooks just mark
which sessions are live.

Closing the window keeps the app running in the background; the dock icon reopens
it. There's an optional **Show on all Spaces** toggle.

## Install

Requires **macOS 15+**.

**1. Get the app.** Download the latest `CC Status Light *.zip` from
[Releases](https://github.com/liotru-lab/claude-code-status-light/releases), unzip,
and move **CCStatusLight.app** to `/Applications`. It's signed and notarized, so it
opens with no Gatekeeper warning. (Or build it yourself — see below.)

**2. Wire up the hooks.** Run the installer — it shows exactly what will change in
`~/.claude/settings.json`, backs the file up, and asks before writing:

```sh
./hooks/install-hooks.sh          # --uninstall to remove · --diff to preview · -y to skip the prompt
```

No terminal handy? Use the app's **CC Status Light ▸ Install Hooks…** menu instead
— same diff-and-confirm flow, with the scripts bundled inside the app.

**3. Start (or restart) a Claude Code session** — it appears in the window.

## Build from source

Requires macOS 15+, Xcode 16+ (tested on 26), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate            # regenerate CCStatusLight.xcodeproj from project.yml
xcodebuild -project CCStatusLight.xcodeproj -target CCStatusLight -configuration Debug build
```

Or open the generated `CCStatusLight.xcodeproj` in Xcode and press Run. The
`.xcodeproj` is generated and git-ignored — re-run `xcodegen generate` after
cloning or editing `project.yml`.

By default it builds **ad-hoc** ("sign to run locally"), so no Apple Developer
account is needed. To sign with your own team, add a git-ignored `Local.xcconfig`
next to `Signing.xcconfig`:

```
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = XXXXXXXXXX
CODE_SIGNING_REQUIRED = YES
```

Maintainers cut notarized releases with `./scripts/release.sh` — see
[RELEASE.md](RELEASE.md).

## How the hooks work

`install-hooks.sh` wires these Claude Code events to `cc-status-light-hook.sh`,
which writes one marker file per session to
`~/Library/Application Support/CCStatusLight/state/<session-id>.json`:

| Hook event | Fallback state |
| ---------- | -------------- |
| `SessionStart` | `ready` |
| `UserPromptSubmit`, `PostToolUse` | `working` |
| `Notification` | `idle` for a waiting nudge; `notification` for a permission/elicitation prompt |
| `PermissionRequest` | `notification` |
| `Stop` | `idle` |
| `SessionEnd` | `ended` |

These per-event states are only a fallback — the app prefers the transcript. The
`Notification` event is overloaded (Claude Code fires it both when just waiting for
you and when it genuinely needs attention), so the hook inspects the payload's
`notification_type`: a plain waiting nudge stays calm `idle`, and only real
permission/elicitation prompts turn the row red.

`install-hooks.sh` is the only thing that writes `~/.claude/settings.json`. It's
idempotent, backs up first, and `--uninstall` removes only our own entries —
leaving any other hooks (e.g. a busylight) untouched. It never writes
`~/.claude.json`, never registers a plugin, never installs a LaunchAgent.

## Uninstall — leaves zero residue

```sh
./hooks/install-hooks.sh --uninstall                        # remove our hook entries
rm -rf "$HOME/Library/Application Support/CCStatusLight"     # state + staged scripts
rm -rf /Applications/CCStatusLight.app
```

That's everything.

## License

MIT — see [LICENSE](LICENSE).
