#!/usr/bin/env bash
#
# CC Status Light — opt-in hook installer.
#
#   ./install-hooks.sh            install (or refresh) the hooks
#   ./install-hooks.sh --uninstall  remove them
#   ./install-hooks.sh --print      print the merged settings.json, change nothing
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

mode="install"
case "${1:-}" in
  "")           mode="install" ;;
  --uninstall)  mode="uninstall" ;;
  --print)      mode="print" ;;
  -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)            die "unknown argument: $1 (try --help)" ;;
esac

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
  command="${HOOK} ${state}"

  if [ "$mode" = "uninstall" ]; then
    # Drop any of our entries; then drop the event key if it went empty.
    new="$(jq \
      --arg ev "$event" --arg hook "$HOOK" '
      if (.hooks[$ev]?) then
        .hooks[$ev] |= map(select([ (.hooks // [])[].command ]
                            | any(startswith($hook)) | not))
      else . end
      | if (.hooks[$ev]? | length) == 0 then del(.hooks[$ev]) else . end
    ' <<<"$new")"
  else
    # Idempotent add: strip our previous entry for this event, then append.
    new="$(jq \
      --arg ev "$event" --arg hook "$HOOK" --arg cmd "$command" '
      .hooks[$ev] = ((.hooks[$ev] // [])
        | map(select([ (.hooks // [])[].command ]
                     | any(startswith($hook)) | not)))
        + [ { matcher: "", hooks: [ { type: "command", command: $cmd } ] } ]
    ' <<<"$new")"
  fi
done

# Tidy up an empty hooks object left by uninstall.
new="$(jq 'if (.hooks? // {}) == {} then del(.hooks) else . end' <<<"$new")"

if [ "$mode" = "print" ]; then
  printf '%s\n' "$new"
  exit 0
fi

if [ "$current" = "$new" ]; then
  echo "Nothing to change — settings already in the desired state."
  exit 0
fi

echo "Target file: $SETTINGS"
echo "Changes:"
echo "----------------------------------------------------------------------"
# Pretty-print both sides for a readable diff; never fail the script on diff's
# exit status (it returns 1 when files differ).
diff -u <(printf '%s\n' "$current" | jq -S .) <(printf '%s\n' "$new" | jq -S .) || true
echo "----------------------------------------------------------------------"

printf 'Apply these changes? [y/N] '
read -r reply
case "$reply" in
  y|Y|yes|YES) ;;
  *) echo "Aborted. No changes made."; exit 0 ;;
esac

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
