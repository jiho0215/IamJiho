#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
FANOUT="$HOOKS/fan-out.sh"
EMIT="$HOOKS/emit-event.sh"
GET="$HOOKS/get-events.sh"

[ -x "$FANOUT" ] || { echo "FAIL: fan-out.sh not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/parent"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-parent","status":"in-progress","phases":[]}
JSON

# Test 1: fan-out creates child session dir + progress-log
CHILD=$(bash "$FANOUT" --name test-child --target-dir "$TMP/children")
[ -d "$CHILD" ] || { echo "FAIL: child dir not created ($CHILD)"; exit 1; }
[ -f "$CHILD/progress-log.json" ] || { echo "FAIL: child progress-log not created"; exit 1; }
CHILD_RUN_ID=$(jq -r '.runId' "$CHILD/progress-log.json")
[ "$CHILD_RUN_ID" = "run-parent" ] || { echo "FAIL: child runId not inherited ($CHILD_RUN_ID)"; exit 1; }

# Test 2: parent emitted fan-out.spawned
SPAWNED=$(bash "$GET" --type fan-out.spawned --format count)
[ "$SPAWNED" = "1" ] || { echo "FAIL: fan-out.spawned count != 1 (got $SPAWNED)"; exit 1; }
SPAWN_DIR=$(bash "$GET" --type fan-out.spawned --format json | jq -r '.data.childDir')
[ "$SPAWN_DIR" = "$CHILD" ] || { echo "FAIL: spawned.childDir mismatch ($SPAWN_DIR vs $CHILD)"; exit 1; }

# Test 3: child session has its own events file (independent mode)
DEVFW_TEST_SESSION_DIR="$CHILD" bash "$EMIT" child.started --data '{}'
CHILD_EVENTS=$(wc -l < "$CHILD/events.jsonl")
[ "$CHILD_EVENTS" = "1" ] || { echo "FAIL: child events not independent ($CHILD_EVENTS)"; exit 1; }
PARENT_EVENTS=$(wc -l < "$DEVFW_TEST_SESSION_DIR/events.jsonl")
[ "$PARENT_EVENTS" = "1" ] || { echo "FAIL: parent events count changed (got $PARENT_EVENTS, expected 1)"; exit 1; }

# Test 4: --share-events either (a) shares events via symlink/hardlink so child
# emits appear in parent, or (b) falls back to copy with a warning. Both paths are
# correct; we just need to verify the fan-out runs and emits its own spawned event.
SHARED_CHILD=$(bash "$FANOUT" --name shared-child --target-dir "$TMP/children" --share-events 2>/tmp/share-stderr)
PARENT_BEFORE=$(wc -l < "$DEVFW_TEST_SESSION_DIR/events.jsonl")
DEVFW_TEST_SESSION_DIR="$SHARED_CHILD" bash "$EMIT" shared.event --data '{}'
PARENT_AFTER=$(wc -l < "$DEVFW_TEST_SESSION_DIR/events.jsonl")

# Two valid outcomes:
#   true sharing (POSIX): parent = PARENT_BEFORE + 1 (child emit appears in parent)
#   fallback copy (Windows no-symlink): parent = PARENT_BEFORE (child emit into copy)
DELTA=$((PARENT_AFTER - PARENT_BEFORE))
if [ "$DELTA" = "1" ]; then
  echo "  (share-events: true-share mode)"
elif [ "$DELTA" = "0" ]; then
  grep -q "WARNING" /tmp/share-stderr || { echo "FAIL: fallback path but no warning emitted"; exit 1; }
  echo "  (share-events: copy-fallback mode, platform limitation)"
else
  echo "FAIL: unexpected delta ($DELTA)"; exit 1
fi
rm -f /tmp/share-stderr

# Regardless of path, the shared_child itself should have emitted spawned in parent
SPAWN2=$(bash "$GET" --type fan-out.spawned --format count)
[ "$SPAWN2" = "2" ] || { echo "FAIL: fan-out.spawned count after second spawn ($SPAWN2)"; exit 1; }

echo "PASS: fan-out"
