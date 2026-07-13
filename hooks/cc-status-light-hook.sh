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
# Special case: the Notification event is overloaded — Claude Code fires it both
# for "waiting for your input" (calm) and for real attention (permission /
# elicitation prompts). When called for a Notification, this script inspects the
# payload's notification_type and downgrades a mere waiting nudge to `idle`,
# reserving the red `notification` state for genuine attention.
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

cwd="$(printf '%s' "$payload"        | jq -r '.cwd // empty'             2>/dev/null || true)"
event="$(printf '%s' "$payload"      | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null || true)"

# PID of the owning Claude Code process, for liveness checks by the app.
# CLAUDE_PID is set by Claude Code when available; otherwise the hook's parent
# is the process that spawned it.
pid="${CLAUDE_PID:-$PPID}"
case "$pid" in ''|*[!0-9]*) pid=0 ;; esac

# Resolve the overloaded Notification event by its sub-type. A waiting session
# ("idle_prompt", or an unrecognised/absent type) should read as the calm `idle`,
# not the attention-grabbing red `notification`. Real permission/elicitation
# prompts keep `notification`. (Permission prompts also arrive via the separate
# PermissionRequest hook, which stays mapped to `notification`.)
if [ "$event" = "Notification" ]; then
  ntype="$(printf '%s' "$payload" | jq -r '.notification_type // empty' 2>/dev/null || true)"
  case "$ntype" in
    permission_prompt|elicitation_dialog) state="notification" ;;
    *)                                     state="idle" ;;
  esac
  [ -n "$ntype" ] && event="Notification/${ntype}"
fi

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
  --arg transcript_path "$transcript" \
  --argjson pid "$pid" \
  --arg timestamp "$timestamp" \
  '{session_id:$session_id, state:$state, cwd:$cwd, event:$event,
    transcript_path:$transcript_path, pid:$pid, timestamp:$timestamp}' \
  > "$tmp"

chmod 600 "$tmp"
mv -f "$tmp" "${dir}/${session_id}.json"
trap - EXIT
