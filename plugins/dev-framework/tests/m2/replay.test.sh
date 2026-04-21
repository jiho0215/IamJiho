#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
REPLAY="$HOOKS/replay.sh"

[ -x "$REPLAY" ] || { echo "FAIL: replay not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-rep","status":"in-progress"}
JSON

bash "$EMIT" session.started --actor orchestrator --data '{"mode":"full-cycle"}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":2}'

# Replay to seq 3 (only session.started + phase1 started+completed)
TARGET="$TMP/replayed"
bash "$REPLAY" --until-seq 3 --target "$TARGET"

[ -f "$TARGET/events.jsonl" ] || { echo "FAIL: replay target missing events"; exit 1; }
LINES=$(wc -l < "$TARGET/events.jsonl")
[ "$LINES" = "3" ] || { echo "FAIL: replay should have 3 events, got $LINES"; exit 1; }
[ -f "$TARGET/views/progress-log.json" ] || { echo "FAIL: views not regenerated"; exit 1; }

CP=$(jq -r '.currentPhase' "$TARGET/views/progress-log.json")
[ "$CP" = "1" ] || { echo "FAIL: replayed currentPhase != 1 (got $CP)"; exit 1; }

# Original untouched
ORIG_COUNT=$(wc -l < "$DEVFW_TEST_SESSION_DIR/events.jsonl")
[ "$ORIG_COUNT" = "5" ] || { echo "FAIL: original modified"; exit 1; }

# Default (no --until-seq) copies all
bash "$REPLAY" --target "$TMP/all"
ALL_COUNT=$(wc -l < "$TMP/all/events.jsonl")
[ "$ALL_COUNT" = "5" ] || { echo "FAIL: default replay count ($ALL_COUNT)"; exit 1; }

# Default target = $SESSION_DIR/.replay
bash "$REPLAY" --until-seq 2
[ -f "$DEVFW_TEST_SESSION_DIR/.replay/events.jsonl" ] || { echo "FAIL: default target not created"; exit 1; }
DEF_COUNT=$(wc -l < "$DEVFW_TEST_SESSION_DIR/.replay/events.jsonl")
[ "$DEF_COUNT" = "2" ] || { echo "FAIL: default target count ($DEF_COUNT)"; exit 1; }

echo "PASS: replay"
