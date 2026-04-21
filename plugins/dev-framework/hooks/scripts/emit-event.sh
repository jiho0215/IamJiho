#!/bin/bash
# emit-event.sh — Append one event to $SESSION_DIR/events.jsonl.
#
# Usage: emit-event.sh <type> [--data JSON] [--actor ACTOR] [--run-id ID]
#
# No-op (exit 0) when session dir does not exist — early-phase invocations
# must not fail. Uses mkdir-based lock on .seq.lock (NTFS-safe).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

TYPE="${1:-}"
if [ -z "$TYPE" ]; then
  echo "emit-event: ERROR — missing event type argument" >&2
  exit 1
fi
shift

DATA='{}'
ACTOR='orchestrator'
RUN_ID_OVERRIDE=''
while [ $# -gt 0 ]; do
  case "$1" in
    --data) DATA="$2"; shift 2 ;;
    --actor) ACTOR="$2"; shift 2 ;;
    --run-id) RUN_ID_OVERRIDE="$2"; shift 2 ;;
    *) echo "emit-event: WARNING — unknown flag '$1'" >&2; shift ;;
  esac
done

SESSION_DIR=$(resolve_session_dir)
[ -d "$SESSION_DIR" ] || exit 0

EVENTS_FILE="$SESSION_DIR/events.jsonl"
SEQ_FILE="$SESSION_DIR/.seq"
LOCK_DIR="$SESSION_DIR/.seq.lock"

RUN_ID="$RUN_ID_OVERRIDE"
if [ -z "$RUN_ID" ] && [ -f "$SESSION_DIR/progress-log.json" ] && command -v jq &>/dev/null; then
  RUN_ID=$(jq -r '.runId // empty' "$SESSION_DIR/progress-log.json" 2>/dev/null || echo "")
fi

LOCK_TRIES=0
LOCK_MAX_TRIES="${DEVFW_EMIT_LOCK_MAX_TRIES:-600}"  # ~30s at 50ms; tunable for stress
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  LOCK_TRIES=$((LOCK_TRIES + 1))
  if [ "$LOCK_TRIES" -gt "$LOCK_MAX_TRIES" ]; then
    echo "emit-event: ERROR — could not acquire lock at $LOCK_DIR after $LOCK_MAX_TRIES tries" >&2
    exit 1
  fi
  sleep 0.05
done
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

LAST_SEQ=0
if [ -f "$SEQ_FILE" ]; then
  LAST_SEQ=$(cat "$SEQ_FILE" 2>/dev/null || echo 0)
  [[ "$LAST_SEQ" =~ ^[0-9]+$ ]] || LAST_SEQ=0
fi
NEW_SEQ=$((LAST_SEQ + 1))
AT=$(iso_utc)

if command -v jq &>/dev/null; then
  echo "$DATA" | jq empty 2>/dev/null || DATA='{}'
  jq -cn \
    --argjson seq "$NEW_SEQ" \
    --arg at "$AT" \
    --arg run "$RUN_ID" \
    --arg actor "$ACTOR" \
    --arg type "$TYPE" \
    --argjson data "$DATA" \
    '{seq:$seq, at:$at, runId:$run, actor:$actor, type:$type, data:$data}' \
    >> "$EVENTS_FILE"
else
  printf '{"seq":%d,"at":"%s","runId":"%s","actor":"%s","type":"%s","data":%s}\n' \
    "$NEW_SEQ" "$AT" "$RUN_ID" "$ACTOR" "$TYPE" "$DATA" \
    >> "$EVENTS_FILE"
fi

printf '%d' "$NEW_SEQ" > "$SEQ_FILE.tmp" && mv "$SEQ_FILE.tmp" "$SEQ_FILE"
exit 0
