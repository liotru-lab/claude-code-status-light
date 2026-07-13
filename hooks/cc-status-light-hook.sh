#!/usr/bin/env bash
#
# CC Status Light — session state hook.
#
# Invoked by Claude Code hooks with a single state argument:
#
#     cc-status-light-hook.sh <state>
#
# where <state> is one of: ready working notification idle ended
#
# Reads the hook JSON payload on stdin (session_id, cwd, hook_event_name, ...)
# and writes a per-session file that the CC Status Light app reads:
#
#     ~/Library/Application Support/CCStatusLight/state/<session-id>.json
#
# The write is atomic (temp file + rename) and mode 0600. Requires `jq`.

set -euo pipefail

state="${1:-}"
case "$state" in
  ready|working|notification|idle|ended) ;;
  *) echo "cc-status-light-hook: invalid state '${state}'" >&2; exit 2 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "cc-status-light-hook: jq not found on PATH" >&2
  exit 127
fi

payload="$(cat || true)"
session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)"

# No session id to key on — nothing we can record. Exit cleanly so we never
# interfere with the session.
[ -n "$session_id" ] || exit 0

cwd="$(printf '%s' "$payload"   | jq -r '.cwd // empty'             2>/dev/null || true)"
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

dir="${HOME}/Library/Application Support/CCStatusLight/state"
mkdir -p "$dir"

tmp="$(mktemp "${dir}/.${session_id}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

jq -n \
  --arg session_id "$session_id" \
  --arg state "$state" \
  --arg cwd "$cwd" \
  --arg event "$event" \
  --arg timestamp "$timestamp" \
  '{session_id:$session_id, state:$state, cwd:$cwd, event:$event, timestamp:$timestamp}' \
  > "$tmp"

chmod 600 "$tmp"
mv -f "$tmp" "${dir}/${session_id}.json"
trap - EXIT
