#!/usr/bin/env bash
#
# CC Status Light — opt-in hook installer.
#
#   ./install-hooks.sh            install (or refresh) the hooks
#   ./install-hooks.sh --uninstall  remove them
#   ./install-hooks.sh --print      print the merged settings.json, change nothing
#   ./install-hooks.sh --diff       print the diff of what would change, no write
#   ./install-hooks.sh -y|--yes     apply without the interactive prompt (still backs up)
#
# Flags combine, e.g. `--uninstall --diff` or `--uninstall -y`. The app's
# "Install Hooks…" menu drives it with --diff then -y.
#
# It edits ~/.claude/settings.json ONLY. Before writing it:
#   * makes a timestamped backup next to the file,
#   * shows a diff of exactly what changes,
#   * asks for confirmation.
#
# It never touches ~/.claude.json, never installs a plugin, never installs a
# LaunchAgent. Uninstalling removes only the entries pointing at this script's
# hook. Requires `jq`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/cc-status-light-hook.sh"
SETTINGS="${CLAUDE_SETTINGS:-${HOME}/.claude/settings.json}"

# We identify our own hook entries by the script name, not the full path, so
# uninstall/refresh works regardless of where the hook was installed from (dev
# repo checkout vs. the app-staged ~/Library copy). Matches HookStatus.isInstalled.
MARKER="cc-status-light-hook"

# hook event -> state written
EVENTS=(
  "SessionStart:ready"
  "UserPromptSubmit:working"
  "PostToolUse:working"
  "Notification:notification"
  "PermissionRequest:notification"
  "Stop:idle"
  "SessionEnd:ended"
)

die() { echo "install-hooks: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
[ -f "$HOOK" ] || die "hook script not found at $HOOK"
chmod +x "$HOOK" 2>/dev/null || true

mode="install"      # install | uninstall
do_print=0          # --print: emit merged settings JSON, no write
do_diff=0           # --diff:  emit the diff only, no write
assume_yes=0        # -y/--yes: apply without the interactive prompt
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) mode="uninstall" ;;
    --print)     do_print=1 ;;
    --diff)      do_diff=1 ;;
    -y|--yes)    assume_yes=1 ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# Current settings (default to empty object if missing).
if [ -f "$SETTINGS" ]; then
  current="$(cat "$SETTINGS")"
  jq -e . >/dev/null 2>&1 <<<"$current" || die "$SETTINGS is not valid JSON"
else
  current="{}"
fi

new="$current"

for pair in "${EVENTS[@]}"; do
  event="${pair%%:*}"
  state="${pair##*:}"
  # Quote the script path: Claude Code runs the command through a shell, and the
  # app-staged path contains a space ("Application Support"). Without quotes the
  # shell splits it and the hook fails to launch.
  command="\"${HOOK}\" ${state}"

  if [ "$mode" = "uninstall" ]; then
    # Drop any of our entries; then drop the event key if it went empty.
    new="$(jq \
      --arg ev "$event" --arg marker "$MARKER" '
      if (.hooks[$ev]?) then
        .hooks[$ev] |= map(select([ (.hooks // [])[].command ]
                            | any(contains($marker)) | not))
      else . end
      | if (.hooks[$ev]? | length) == 0 then del(.hooks[$ev]) else . end
    ' <<<"$new")"
  else
    # Idempotent add: strip any prior entry of ours for this event (regardless
    # of where it was installed from), then append the current path.
    new="$(jq \
      --arg ev "$event" --arg marker "$MARKER" --arg cmd "$command" '
      .hooks[$ev] = ((.hooks[$ev] // [])
        | map(select([ (.hooks // [])[].command ]
                     | any(contains($marker)) | not)))
        + [ { matcher: "", hooks: [ { type: "command", command: $cmd } ] } ]
    ' <<<"$new")"
  fi
done

# Tidy up an empty hooks object left by uninstall.
new="$(jq 'if (.hooks? // {}) == {} then del(.hooks) else . end' <<<"$new")"

if [ "$do_print" = "1" ]; then
  printf '%s\n' "$new"
  exit 0
fi

if [ "$current" = "$new" ]; then
  echo "Nothing to change — settings already in the desired state."
  exit 0
fi

# The diff of exactly what changes (sorted JSON for readability).
diff_text="$(diff -u <(printf '%s\n' "$current" | jq -S .) <(printf '%s\n' "$new" | jq -S .) || true)"

if [ "$do_diff" = "1" ]; then
  printf '%s\n' "$diff_text"
  exit 0
fi

echo "Target file: $SETTINGS"
echo "Changes:"
echo "----------------------------------------------------------------------"
printf '%s\n' "$diff_text"
echo "----------------------------------------------------------------------"

if [ "$assume_yes" != "1" ]; then
  printf 'Apply these changes? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted. No changes made."; exit 0 ;;
  esac
fi

mkdir -p "$(dirname "$SETTINGS")"
if [ -f "$SETTINGS" ]; then
  backup="${SETTINGS}.bak.$(date -u +%Y%m%d%H%M%S)"
  cp -p "$SETTINGS" "$backup"
  echo "Backup written: $backup"
fi

tmp="$(mktemp)"
printf '%s\n' "$new" | jq . > "$tmp"
mv -f "$tmp" "$SETTINGS"
echo "Done."
