#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
WAKE="$HOOKS/wake.sh"

[ -x "$WAKE" ] || { echo "FAIL: wake not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"

# Test 1: no session → compact empty state
mkdir -p "$DEVFW_TEST_SESSION_DIR"
OUT=$(bash "$WAKE")
echo "$OUT" | jq empty || { echo "FAIL: wake output invalid JSON"; exit 1; }
[ "$(echo "$OUT" | jq -r '.lastSeq')" = "0" ] || { echo "FAIL: empty lastSeq != 0"; exit 1; }
[ "$(echo "$OUT" | jq -r '.status')" = "no-session" ] || { echo "FAIL: empty status"; exit 1; }
[ "$(echo "$OUT" | jq -r '.pendingAction')" = "session.not-started" ] || { echo "FAIL: empty pendingAction"; exit 1; }

# Test 2: session started, phase 1 in progress → pendingAction phase.1.completion
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-w1","status":"in-progress"}
JSON
bash "$EMIT" session.started --actor orchestrator --data '{"mode":"full-cycle","featureSlug":"f1"}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":1}'
OUT=$(bash "$WAKE")
[ "$(echo "$OUT" | jq -r '.currentPhase')" = "1" ] || { echo "FAIL: currentPhase != 1"; exit 1; }
[ "$(echo "$OUT" | jq -r '.pendingAction')" = "phase.1.completion" ] || { echo "FAIL: pendingAction phase 1 (got $(echo "$OUT" | jq -r '.pendingAction'))"; exit 1; }
[ "$(echo "$OUT" | jq -r '.status')" = "in-progress" ] || { echo "FAIL: status != in-progress"; exit 1; }

# Test 3: phase 3 complete, no GATE 1 approval → pendingAction gate.1.pending
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":3}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":3}'
OUT=$(bash "$WAKE")
[ "$(echo "$OUT" | jq -r '.pendingAction')" = "gate.1.pending" ] || { echo "FAIL: gate.1.pending (got $(echo "$OUT" | jq -r '.pendingAction'))"; exit 1; }

# Test 4: after gate.approved → phase.4.ready
bash "$EMIT" gate.approved --actor orchestrator --data '{"gate":1,"approvalMode":"interactive","approvedBy":"test"}'
OUT=$(bash "$WAKE")
[ "$(echo "$OUT" | jq -r '.pendingAction')" = "phase.4.ready" ] || { echo "FAIL: phase.4.ready (got $(echo "$OUT" | jq -r '.pendingAction'))"; exit 1; }

# Test 5: active consensus iteration
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":5}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":5,"iteration":3}'
OUT=$(bash "$WAKE")
[ "$(echo "$OUT" | jq -r '.pendingAction')" = "phase.5.iteration.3.active" ] || { echo "FAIL: iteration active (got $(echo "$OUT" | jq -r '.pendingAction'))"; exit 1; }

# Test 6: after session.interrupted → ready-to-resume
bash "$EMIT" session.interrupted --actor "hook:sessionend" --data '{"interruptedAt":"2026-04-20T12:00:00Z","currentPhase":5}'
OUT=$(bash "$WAKE")
[ "$(echo "$OUT" | jq -r '.pendingAction')" = "session.ready-to-resume" ] || { echo "FAIL: resume (got $(echo "$OUT" | jq -r '.pendingAction'))"; exit 1; }

# Test 7: after session.completed → complete
bash "$EMIT" session.completed --actor orchestrator --data '{"totalMinutes":60}'
OUT=$(bash "$WAKE")
[ "$(echo "$OUT" | jq -r '.pendingAction')" = "session.complete" ] || { echo "FAIL: complete"; exit 1; }

echo "PASS: wake"
