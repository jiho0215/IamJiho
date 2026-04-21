#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EXEC="$HOOKS/execute.sh"
GET="$HOOKS/get-events.sh"

[ -x "$EXEC" ] || { echo "FAIL: execute.sh not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

# --- Test 1: hook kind — invokes real hook and emits events ---
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"status":"in-progress","runId":"run-exec","currentPhase":1,"phases":[]}
JSON
bash "$EXEC" hook phase-gate.sh --input '{"args":["verify"]}' > /dev/null 2>&1 || true

STARTED=$(bash "$GET" --type tool.call.started --format count)
[ "$STARTED" = "1" ] || { echo "FAIL: tool.call.started count != 1 (got $STARTED)"; exit 1; }

COMPLETED=$(bash "$GET" --type tool.call.completed --format count)
[ "$COMPLETED" = "1" ] || { echo "FAIL: tool.call.completed count != 1 (got $COMPLETED)"; exit 1; }

KIND=$(bash "$GET" --type tool.call.started --format json | jq -r '.data.kind')
[ "$KIND" = "hook" ] || { echo "FAIL: started.data.kind ($KIND)"; exit 1; }
NAME=$(bash "$GET" --type tool.call.started --format json | jq -r '.data.name')
[ "$NAME" = "phase-gate.sh" ] || { echo "FAIL: started.data.name ($NAME)"; exit 1; }

# --- Test 2: skill kind — emits event + returns JSON payload ---
OUT=$(bash "$EXEC" skill "superpowers:brainstorming" --input '{"topic":"test"}')
echo "$OUT" | jq empty || { echo "FAIL: skill output not valid JSON"; exit 1; }
[ "$(echo "$OUT" | jq -r '.kind')" = "skill" ] || { echo "FAIL: skill payload kind"; exit 1; }
[ "$(echo "$OUT" | jq -r '.name')" = "superpowers:brainstorming" ] || { echo "FAIL: skill payload name"; exit 1; }
[ "$(echo "$OUT" | jq -r '.status')" = "dispatched" ] || { echo "FAIL: skill payload status"; exit 1; }

STARTED2=$(bash "$GET" --type tool.call.started --format count)
[ "$STARTED2" = "2" ] || { echo "FAIL: second started (got $STARTED2)"; exit 1; }

# --- Test 3: --complete flag emits tool.call.completed ---
bash "$EXEC" --complete skill "superpowers:brainstorming" --output '{"result":"ok"}'
COMP_COUNT=$(bash "$GET" --type tool.call.completed --format count)
[ "$COMP_COUNT" = "2" ] || { echo "FAIL: completed after --complete ($COMP_COUNT)"; exit 1; }

# --- Test 4: failure path emits tool.call.failed ---
bash "$EXEC" --fail skill "superpowers:nonexistent" --error "skill not found"
FAIL_COUNT=$(bash "$GET" --type tool.call.failed --format count)
[ "$FAIL_COUNT" = "1" ] || { echo "FAIL: failed count ($FAIL_COUNT)"; exit 1; }
SRC=$(bash "$GET" --type tool.call.failed --format json | jq -r '.data.failureSource')
[ "$SRC" = "explicit" ] || { echo "FAIL: failureSource ($SRC)"; exit 1; }

# --- Test 5: invalid kind rejected ---
set +e
bash "$EXEC" invalid foo 2>/dev/null
RC=$?
set -e
[ "$RC" != "0" ] || { echo "FAIL: invalid kind accepted"; exit 1; }

echo "PASS: execute"
