#!/bin/bash
# get-events.sh — Query events.jsonl for the current session.
#
# Usage:
#   get-events.sh [--type T] [--phase N] [--actor A] [--since-seq N]
#                 [--until-seq N] [--run-id ID] [--limit N]
#                 [--format json|summary|count]
#
# --type and --actor accept exact match or trailing-* prefix (e.g. "phase.*").
# --format defaults to json. json and summary emit lines; count emits integer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

command -v jq &>/dev/null || { echo "get-events: ERROR — jq required" >&2; exit 1; }

TYPE=''
PHASE=''
ACTOR=''
SINCE_SEQ=''
UNTIL_SEQ=''
RUN_ID=''
LIMIT=''
FORMAT='json'

while [ $# -gt 0 ]; do
  case "$1" in
    --type) TYPE="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --actor) ACTOR="$2"; shift 2 ;;
    --since-seq) SINCE_SEQ="$2"; shift 2 ;;
    --until-seq) UNTIL_SEQ="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    *) echo "get-events: ERROR — unknown flag '$1'" >&2; exit 1 ;;
  esac
done

SESSION_DIR=$(resolve_session_dir)
EVENTS_FILE="$SESSION_DIR/events.jsonl"

if [ ! -f "$EVENTS_FILE" ]; then
  case "$FORMAT" in
    count) echo 0 ;;
    *) : ;;
  esac
  exit 0
fi

FILTER='.'

add_prefix_filter() {
  local field="$1" val="$2"
  if [ -z "$val" ]; then return; fi
  if [[ "$val" == *'*' ]]; then
    local prefix="${val%\*}"
    FILTER="$FILTER | select(.$field | startswith(\"$prefix\"))"
  else
    FILTER="$FILTER | select(.$field == \"$val\")"
  fi
}

add_prefix_filter type "$TYPE"
add_prefix_filter actor "$ACTOR"
[ -n "$PHASE" ]      && FILTER="$FILTER | select(.data.phase == $PHASE)"
[ -n "$SINCE_SEQ" ]  && FILTER="$FILTER | select(.seq >= $SINCE_SEQ)"
[ -n "$UNTIL_SEQ" ]  && FILTER="$FILTER | select(.seq <= $UNTIL_SEQ)"
[ -n "$RUN_ID" ]     && FILTER="$FILTER | select(.runId == \"$RUN_ID\")"

RESULT=$(jq -c "$FILTER" "$EVENTS_FILE")

if [ -n "$LIMIT" ]; then
  RESULT=$(echo "$RESULT" | head -n "$LIMIT")
fi

case "$FORMAT" in
  json)    [ -n "$RESULT" ] && echo "$RESULT" ;;
  summary) [ -n "$RESULT" ] && echo "$RESULT" | jq -r '[.seq, .at, .actor, .type] | @tsv' ;;
  count)   if [ -z "$RESULT" ]; then echo 0; else echo "$RESULT" | wc -l | tr -d ' '; fi ;;
  *) echo "get-events: ERROR — unknown format '$FORMAT'" >&2; exit 1 ;;
esac
exit 0
