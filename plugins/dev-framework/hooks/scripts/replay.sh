#!/bin/bash
# replay.sh — Copy events up to --until-seq N into --target DIR and regenerate views.
#
# Usage:
#   replay.sh [--until-seq N] [--target DIR]
#
# Defaults: --until-seq = last seq (copy all), --target = $SESSION_DIR/.replay
# Leaves the original session untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"
# shellcheck source=./_reducers.sh
. "$SCRIPT_DIR/_reducers.sh"

command -v jq &>/dev/null || { echo "replay: ERROR — jq required" >&2; exit 1; }

UNTIL_SEQ=""
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --until-seq) UNTIL_SEQ="$2"; shift 2 ;;
    --target)    TARGET="$2"; shift 2 ;;
    *) echo "replay: ERROR — unknown flag '$1'" >&2; exit 1 ;;
  esac
done

SOURCE_DIR=$(resolve_session_dir)
SOURCE_EVENTS="$SOURCE_DIR/events.jsonl"

if [ ! -f "$SOURCE_EVENTS" ]; then
  echo "replay: no events.jsonl in source session ($SOURCE_DIR)" >&2
  exit 1
fi

[ -n "$TARGET" ] || TARGET="$SOURCE_DIR/.replay"
mkdir -p "$TARGET"

if [ -n "$UNTIL_SEQ" ]; then
  jq -c --argjson limit "$UNTIL_SEQ" 'select(.seq <= $limit)' "$SOURCE_EVENTS" > "$TARGET/events.jsonl"
else
  cp "$SOURCE_EVENTS" "$TARGET/events.jsonl"
fi

# Copy progress-log.json so runId is available for reducers
if [ -f "$SOURCE_DIR/progress-log.json" ]; then
  cp "$SOURCE_DIR/progress-log.json" "$TARGET/progress-log.json"
fi

LAST=$(jq -s 'map(.seq) | max // 0' "$TARGET/events.jsonl")
printf '%d' "$LAST" > "$TARGET/.seq"

DEVFW_TEST_SESSION_DIR="$TARGET" bash "$SCRIPT_DIR/regenerate-views.sh"

echo "replay: wrote $(wc -l < "$TARGET/events.jsonl" | tr -d ' ') events to $TARGET (views regenerated)"
exit 0
