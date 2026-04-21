#!/bin/bash
# M1 integration test: simulate a minimal pipeline session and verify
# that state-transition events are emitted correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

# Seed a minimal progress-log.json so hooks find state
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{
  "schemaVersion": 1,
  "mode": "full-cycle",
  "featureSlug": "test-feature",
  "runId": "run-test-0001",
  "startedAt": "2026-04-20T10:00:00Z",
  "status": "in-progress",
  "currentPhase": 1,
  "phases": []
}
JSON

# Emit a representative sequence (simulating SKILL.md orchestrator flow)
bash "$HOOKS/emit-event.sh" session.started      --actor orchestrator --data '{"mode":"full-cycle","featureSlug":"test-feature"}'
bash "$HOOKS/emit-event.sh" phase.started         --actor orchestrator --data '{"phase":1}'
bash "$HOOKS/emit-event.sh" phase.completed       --actor orchestrator --data '{"phase":1}'
bash "$HOOKS/emit-event.sh" phase.started         --actor orchestrator --data '{"phase":2}'
bash "$HOOKS/emit-event.sh" phase.completed       --actor orchestrator --data '{"phase":2}'
bash "$HOOKS/emit-event.sh" phase.started         --actor orchestrator --data '{"phase":3}'
bash "$HOOKS/emit-event.sh" consensus.iteration.started --actor orchestrator --data '{"phase":3,"iteration":1}'
bash "$HOOKS/emit-event.sh" consensus.converged   --actor orchestrator --data '{"phase":3,"iterations":2,"issuesFixed":5}'
bash "$HOOKS/emit-event.sh" gate.approved         --actor orchestrator --data '{"gate":1,"approvalMode":"interactive","approvedBy":"test"}'
bash "$HOOKS/emit-event.sh" phase.completed       --actor orchestrator --data '{"phase":3}'

# --- Verify queries ---
PHASE_COUNT=$(bash "$HOOKS/get-events.sh" --type 'phase.*' --format count)
[ "$PHASE_COUNT" = "6" ] || { echo "FAIL: phase.* count != 6 (got $PHASE_COUNT)"; exit 1; }

CONS_COUNT=$(bash "$HOOKS/get-events.sh" --type 'consensus.*' --format count)
[ "$CONS_COUNT" = "2" ] || { echo "FAIL: consensus.* count != 2 (got $CONS_COUNT)"; exit 1; }

GATE_APPROVED=$(bash "$HOOKS/get-events.sh" --type gate.approved --format count)
[ "$GATE_APPROVED" = "1" ] || { echo "FAIL: gate.approved count != 1"; exit 1; }

# Filter by phase — phase 3 should have 3 events (started, completed, converged)
# plus consensus.iteration.started = 4
PHASE3=$(bash "$HOOKS/get-events.sh" --phase 3 --format count)
[ "$PHASE3" = "4" ] || { echo "FAIL: phase=3 count != 4 (got $PHASE3)"; exit 1; }

# Verify seq contiguous 1..N (events emitted in order). Strip \r from jq
# output (git-bash jq uses CRLF line endings in pipes).
SEQS=$(jq -r '.seq' "$DEVFW_TEST_SESSION_DIR/events.jsonl" | tr -d '\r' | paste -sd,)
[ "$SEQS" = "1,2,3,4,5,6,7,8,9,10" ] || { echo "FAIL: seq order wrong ($SEQS)"; exit 1; }

# Verify runId is auto-pulled from progress-log
RUN_IDS=$(jq -r '.runId' "$DEVFW_TEST_SESSION_DIR/events.jsonl" | tr -d '\r' | sort -u)
[ "$RUN_IDS" = "run-test-0001" ] || { echo "FAIL: runId not consistent ($RUN_IDS)"; exit 1; }

# --- Hook-emit integration: run phase-gate.sh verify, check it emitted gate.passed ---
BEFORE=$(bash "$HOOKS/get-events.sh" --type gate.passed --actor 'hook:*' --format count)
bash "$HOOKS/phase-gate.sh" verify > /dev/null 2>&1
AFTER=$(bash "$HOOKS/get-events.sh" --type gate.passed --actor 'hook:*' --format count)
[ "$AFTER" -gt "$BEFORE" ] || { echo "FAIL: phase-gate did not emit gate.passed (before=$BEFORE after=$AFTER)"; exit 1; }

# --- Hook-emit: session.interrupted via sessionend.sh ---
bash "$HOOKS/sessionend.sh" > /dev/null 2>&1 || true
INT_COUNT=$(bash "$HOOKS/get-events.sh" --type session.interrupted --format count)
[ "$INT_COUNT" = "1" ] || { echo "FAIL: session.interrupted count != 1 (got $INT_COUNT)"; exit 1; }

# Summary output for eyeball verification
echo "--- Final event timeline ---"
bash "$HOOKS/get-events.sh" --format summary
echo "PASS: dual-write integration"
