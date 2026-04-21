#!/bin/bash
# M3 integration: simulate Phase 1 entry using phase YAML + execute.sh + events.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
PHASES="$SCRIPT_DIR/../../phases"
EMIT="$HOOKS/emit-event.sh"
EXEC="$HOOKS/execute.sh"
READ="$HOOKS/read-phase.sh"
GET="$HOOKS/get-events.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"status":"in-progress","runId":"run-disp","currentPhase":0,"phases":[]}
JSON

# 1. Read phase 1 YAML metadata
PHASE_NUM=$(bash "$READ" "$PHASES/phase-1.yaml" phase)
[ "$PHASE_NUM" = "1" ] || { echo "FAIL: read phase"; exit 1; }

NAME=$(bash "$READ" "$PHASES/phase-1.yaml" name)
[ "$NAME" = "Requirements" ] || { echo "FAIL: read name (got $NAME)"; exit 1; }

REFS=$(bash "$READ" "$PHASES/phase-1.yaml" requiredRefs)
echo "$REFS" | grep -q "templates/FEATURE_SPEC_TEMPLATE.md" || { echo "FAIL: requiredRefs missing template"; exit 1; }

USER_GATE=$(bash "$READ" "$PHASES/phase-1.yaml" userGate)
[ "$USER_GATE" = "none" ] || { echo "FAIL: userGate != none (got $USER_GATE)"; exit 1; }

# 2. Simulate dispatcher emitting entry event
bash "$EMIT" phase.started --actor orchestrator --data "{\"phase\":$PHASE_NUM}"

# 3. Dispatch phase-gate via execute.sh (begin 1)
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"status":"in-progress","runId":"run-disp","currentPhase":1,"phases":[]}
JSON
bash "$EXEC" hook phase-gate.sh --input '{"args":["begin","1"]}' > /dev/null 2>&1

# 4. Dispatch a skill (stub — not actually calling a Skill tool)
bash "$EXEC" skill "superpowers:brainstorming" --input '{"topic":"test"}' > /dev/null
bash "$EXEC" --complete skill "superpowers:brainstorming" --output '{"result":"done"}'

# 5. Dispatch a protocol load
bash "$EXEC" protocol multi-agent-consensus > /dev/null 2>&1 || true

# 6. Emit phase.completed
bash "$EMIT" phase.completed --actor orchestrator --data "{\"phase\":$PHASE_NUM}"

# --- Verify event stream ---
PHASE_EVENTS=$(bash "$GET" --type 'phase.*' --format count)
[ "$PHASE_EVENTS" = "2" ] || { echo "FAIL: phase.* count != 2 (got $PHASE_EVENTS)"; exit 1; }

TOOL_STARTED=$(bash "$GET" --type tool.call.started --format count)
[ "$TOOL_STARTED" -ge "3" ] || { echo "FAIL: tool.call.started count < 3 (got $TOOL_STARTED)"; exit 1; }

TOOL_COMPLETED=$(bash "$GET" --type tool.call.completed --format count)
[ "$TOOL_COMPLETED" -ge "3" ] || { echo "FAIL: tool.call.completed count < 3 (got $TOOL_COMPLETED)"; exit 1; }

# Verify the tool.call events carry correct kinds
KINDS=$(bash "$GET" --type tool.call.started --format json | jq -r '.data.kind' | sort -u | paste -sd, | tr -d '\r')
echo "$KINDS" | grep -q "hook" || { echo "FAIL: no hook kind in stream"; exit 1; }
echo "$KINDS" | grep -q "skill" || { echo "FAIL: no skill kind in stream"; exit 1; }
echo "$KINDS" | grep -q "protocol" || { echo "FAIL: no protocol kind in stream"; exit 1; }

echo "PASS: dispatcher-integration"
