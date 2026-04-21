#!/bin/bash
# M2 integration test: simulate a Phase 1-3 pipeline + GATE 1, then verify
# the three views + wake output contain consistent state derived from events.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
REGEN="$HOOKS/regenerate-views.sh"
WAKE="$HOOKS/wake.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-sem","status":"in-progress","freezeDocPath":"docs/specs/x-freeze.md"}
JSON

bash "$EMIT" session.started     --actor orchestrator --data '{"mode":"full-cycle","featureSlug":"semtest"}'
bash "$EMIT" phase.started       --actor orchestrator --data '{"phase":1}'
bash "$EMIT" decision.recorded   --actor orchestrator --data '{"id":"D001","phase":1,"category":"plan","decision":"x","reason":"y","confidence":"high"}'
bash "$EMIT" phase.completed     --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.started       --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.completed     --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.started       --actor orchestrator --data '{"phase":3}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":3,"iteration":1}'
bash "$EMIT" consensus.issues.found      --actor "agent:arch" --data '{"phase":3,"iteration":1,"issues":[{"s":"H"}]}'
bash "$EMIT" consensus.fix.applied       --actor orchestrator --data '{"phase":3,"iteration":1,"issueId":"I1"}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":3,"iteration":2}'
bash "$EMIT" consensus.converged         --actor orchestrator --data '{"phase":3,"iterations":2,"issuesFixed":1}'
bash "$EMIT" phase.completed             --actor orchestrator --data '{"phase":3}'
bash "$EMIT" gate.approved               --actor orchestrator --data '{"gate":1,"approvalMode":"interactive","approvedBy":"tester"}'

bash "$REGEN"

# --- progress-log view ---
PV="$DEVFW_TEST_SESSION_DIR/views/progress-log.json"
[ "$(jq -r '.status' "$PV")" = "in-progress" ] || { echo "FAIL: pv.status"; exit 1; }
[ "$(jq -r '.mode' "$PV")" = "full-cycle" ] || { echo "FAIL: pv.mode"; exit 1; }
[ "$(jq -r '.currentPhase' "$PV")" = "3" ] || { echo "FAIL: pv.currentPhase"; exit 1; }
[ "$(jq -r '.phases | length' "$PV")" = "3" ] || { echo "FAIL: pv.phases length"; exit 1; }
[ "$(jq -r '.phases[2].status' "$PV")" = "completed" ] || { echo "FAIL: pv.phase3.status"; exit 1; }
[ "$(jq -r '.summary.gateApprovals.gate1' "$PV")" = "interactive" ] || { echo "FAIL: pv.gateApprovals.gate1"; exit 1; }
[ "$(jq -r '.summary.consensusRounds.phase3' "$PV")" = "2" ] || { echo "FAIL: pv.consensusRounds.phase3"; exit 1; }

# --- decision-log view ---
DV="$DEVFW_TEST_SESSION_DIR/views/decision-log.json"
[ "$(jq -r '.decisions | length' "$DV")" = "2" ] || { echo "FAIL: dv.decisions length"; exit 1; }

# --- pipeline-issues view ---
IV="$DEVFW_TEST_SESSION_DIR/views/pipeline-issues.json"
[ "$(jq -r '.runs[0].runId' "$IV")" = "run-sem" ] || { echo "FAIL: iv.runId"; exit 1; }
[ "$(jq -r '.runs[0].phases."3".iterations | length' "$IV")" = "2" ] || { echo "FAIL: iv.iterations"; exit 1; }
[ "$(jq -r '.runs[0].phases."3".converged' "$IV")" = "true" ] || { echo "FAIL: iv.converged"; exit 1; }

# --- wake ---
WO=$(bash "$WAKE")
[ "$(echo "$WO" | jq -r '.pendingAction')" = "phase.4.ready" ] || { echo "FAIL: wake pendingAction (got $(echo "$WO" | jq -r '.pendingAction'))"; exit 1; }
[ "$(echo "$WO" | jq -r '.status')" = "in-progress" ] || { echo "FAIL: wake.status"; exit 1; }
[ "$(echo "$WO" | jq -r '.minimumContext.freezeDocPath')" = "docs/specs/x-freeze.md" ] || { echo "FAIL: wake.freezeDocPath"; exit 1; }

# --- replay to seq 6 (before Phase 3) and check wake shows phase.3.ready ---
bash "$HOOKS/replay.sh" --until-seq 6 --target "$TMP/replayed-6"
DEVFW_TEST_SESSION_DIR="$TMP/replayed-6" bash "$WAKE" > "$TMP/wake-6.json"
RA=$(jq -r '.pendingAction' "$TMP/wake-6.json")
[ "$RA" = "phase.3.ready" ] || { echo "FAIL: replay wake (got $RA)"; exit 1; }

echo "PASS: semantic-equivalence"
