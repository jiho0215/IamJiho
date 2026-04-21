#!/bin/bash
# End-to-end dog-food test: exercise the full M1-M4 stack as if /dev were running
# a complete 7-phase cycle. No real Claude calls — we simulate the orchestrator's
# actions using our primitives and verify events + views + wake all behave.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
PHASES="$SCRIPT_DIR/../../phases"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
export DEVFW_CONFIG="$TMP/config.json"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

step() { echo "───── $* ─────"; }

#==============================================================================
step "Pre-Workflow: ensure-config, seed progress-log, emit session.started"
#==============================================================================
bash "$HOOKS/ensure-config.sh" > /dev/null

# Verify modelProfile exists in config (M3 knob)
[ "$(jq -r '.pipeline.modelProfile' "$DEVFW_CONFIG")" = "balanced" ] || { echo "FAIL: modelProfile not balanced"; exit 1; }

cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<JSON
{
  "schemaVersion":1,
  "mode":"full-cycle",
  "runId":"run-dogfood-$(date +%s)",
  "featureSlug":"dogfood-feat",
  "status":"in-progress",
  "currentPhase":0,
  "freezeDocPath":"docs/specs/dogfood-feat-freeze.md",
  "phases":[]
}
JSON

bash "$HOOKS/emit-event.sh" session.started --actor orchestrator \
  --data '{"mode":"full-cycle","featureSlug":"dogfood-feat"}'

#==============================================================================
step "Phase 1-7: emit phase.started + phase.completed per the dispatcher preamble"
#==============================================================================
for PHASE_NUM in 1 2 3 4 5 6 7; do
  # Read phase YAML metadata (simulates dispatcher preamble step 1)
  NAME=$(bash "$HOOKS/read-phase.sh" "$PHASES/phase-$PHASE_NUM.yaml" name)
  BUDGET=$(bash "$HOOKS/read-phase.sh" "$PHASES/phase-$PHASE_NUM.yaml" budget.seconds)
  USERGATE=$(bash "$HOOKS/read-phase.sh" "$PHASES/phase-$PHASE_NUM.yaml" userGate)
  echo "  Phase $PHASE_NUM: $NAME (budget=${BUDGET}s, gate=$USERGATE)"

  # Emit phase.started (M1 event)
  bash "$HOOKS/emit-event.sh" phase.started --actor orchestrator --data "{\"phase\":$PHASE_NUM}"

  # Simulate Phase 3 consensus rounds (2 iterations converging)
  if [ "$PHASE_NUM" = "3" ]; then
    bash "$HOOKS/emit-event.sh" consensus.iteration.started --actor orchestrator --data "{\"phase\":3,\"iteration\":1}"
    bash "$HOOKS/emit-event.sh" consensus.issues.found --actor "agent:architect" --data '{"phase":3,"iteration":1,"issues":[{"s":"HIGH"}]}'
    bash "$HOOKS/emit-event.sh" consensus.fix.applied --actor orchestrator --data '{"phase":3,"iteration":1,"issueId":"I1"}'
    bash "$HOOKS/emit-event.sh" consensus.iteration.started --actor orchestrator --data "{\"phase\":3,\"iteration\":2}"
    bash "$HOOKS/emit-event.sh" consensus.converged --actor orchestrator --data '{"phase":3,"iterations":2,"issuesFixed":1}'
  fi

  # Emit phase.completed
  bash "$HOOKS/emit-event.sh" phase.completed --actor orchestrator --data "{\"phase\":$PHASE_NUM}"

  # GATE 1 after Phase 3
  if [ "$PHASE_NUM" = "3" ]; then
    bash "$HOOKS/emit-event.sh" gate.approved --actor orchestrator \
      --data '{"gate":1,"approvalMode":"interactive","approvedBy":"dogfood"}'
  fi

  # GATE 2 after Phase 7
  if [ "$PHASE_NUM" = "7" ]; then
    bash "$HOOKS/emit-event.sh" gate.approved --actor orchestrator \
      --data '{"gate":2,"approvalMode":"interactive","approvedBy":"dogfood"}'
    bash "$HOOKS/emit-event.sh" session.completed --actor orchestrator --data '{"totalMinutes":42}'
  fi
done

#==============================================================================
step "execute.sh dispatch: simulate a skill invocation"
#==============================================================================
bash "$HOOKS/execute.sh" skill "superpowers:brainstorming" --input '{"topic":"test"}' > /dev/null
bash "$HOOKS/execute.sh" --complete skill "superpowers:brainstorming" --output '{"result":"ok"}'

#==============================================================================
step "fan-out.sh: spawn a child session for side exploration"
#==============================================================================
CHILD=$(bash "$HOOKS/fan-out.sh" --name dogfood-child --target-dir "$TMP/children")
[ -d "$CHILD" ] || { echo "FAIL: fan-out child dir"; exit 1; }

# The child session gets its own events when no --share-events
DEVFW_TEST_SESSION_DIR="$CHILD" bash "$HOOKS/emit-event.sh" child.work --data '{"task":"explore"}'
CHILD_EVENTS=$(wc -l < "$CHILD/events.jsonl")
[ "$CHILD_EVENTS" = "1" ] || { echo "FAIL: child independent events (got $CHILD_EVENTS)"; exit 1; }

#==============================================================================
step "M2 views: regenerate + verify structure"
#==============================================================================
bash "$HOOKS/regenerate-views.sh"

for v in progress-log decision-log pipeline-issues; do
  [ -f "$DEVFW_TEST_SESSION_DIR/views/$v.json" ] || { echo "FAIL: views/$v.json missing"; exit 1; }
  jq empty "$DEVFW_TEST_SESSION_DIR/views/$v.json" || { echo "FAIL: views/$v.json invalid JSON"; exit 1; }
done

PV="$DEVFW_TEST_SESSION_DIR/views/progress-log.json"
[ "$(jq -r '.status' "$PV")" = "completed" ] || { echo "FAIL: pv.status != completed"; exit 1; }
[ "$(jq -r '.currentPhase' "$PV")" = "7" ] || { echo "FAIL: pv.currentPhase != 7"; exit 1; }
[ "$(jq -r '.phases | length' "$PV")" = "7" ] || { echo "FAIL: pv.phases != 7 entries"; exit 1; }
[ "$(jq -r '.summary.gateApprovals.gate1' "$PV")" = "interactive" ] || { echo "FAIL: gate1"; exit 1; }
[ "$(jq -r '.summary.gateApprovals.gate2' "$PV")" = "interactive" ] || { echo "FAIL: gate2"; exit 1; }
[ "$(jq -r '.summary.consensusRounds.phase3' "$PV")" = "2" ] || { echo "FAIL: consensus p3"; exit 1; }

IV="$DEVFW_TEST_SESSION_DIR/views/pipeline-issues.json"
[ "$(jq -r '.runs[0].phases."3".converged' "$IV")" = "true" ] || { echo "FAIL: iv.p3 converged"; exit 1; }

#==============================================================================
step "wake.sh: verify pendingAction on completed session"
#==============================================================================
WO=$(bash "$HOOKS/wake.sh")
[ "$(echo "$WO" | jq -r '.pendingAction')" = "session.complete" ] || { echo "FAIL: wake pendingAction != complete"; exit 1; }
[ "$(echo "$WO" | jq -r '.status')" = "completed" ] || { echo "FAIL: wake status != completed"; exit 1; }

#==============================================================================
step "replay.sh: rewind to post-Phase-3 and verify state"
#==============================================================================
# Find the seq of gate.approved for gate 1
GATE1_SEQ=$(bash "$HOOKS/get-events.sh" --type gate.approved --format json | \
  jq -s 'map(select(.data.gate == 1)) | .[0].seq')
bash "$HOOKS/replay.sh" --until-seq "$GATE1_SEQ" --target "$TMP/at-gate1"

WO2=$(DEVFW_TEST_SESSION_DIR="$TMP/at-gate1" bash "$HOOKS/wake.sh")
[ "$(echo "$WO2" | jq -r '.pendingAction')" = "phase.4.ready" ] || {
  echo "FAIL: replay wake pendingAction = $(echo "$WO2" | jq -r '.pendingAction')"; exit 1;
}

#==============================================================================
step "get-events query surface: retrospective audit"
#==============================================================================
TOTAL=$(bash "$HOOKS/get-events.sh" --format count)
PHASE_COUNT=$(bash "$HOOKS/get-events.sh" --type 'phase.*' --format count)
GATE_COUNT=$(bash "$HOOKS/get-events.sh" --type 'gate.*' --format count)
CONS_COUNT=$(bash "$HOOKS/get-events.sh" --type 'consensus.*' --format count)
TOOL_COUNT=$(bash "$HOOKS/get-events.sh" --type 'tool.call.*' --format count)
FANOUT_COUNT=$(bash "$HOOKS/get-events.sh" --type fan-out.spawned --format count)

echo "  Total events:          $TOTAL"
echo "  phase.*:               $PHASE_COUNT (expected 14: 7 started + 7 completed)"
echo "  gate.*:                $GATE_COUNT (expected 2: gate.approved x2)"
echo "  consensus.*:           $CONS_COUNT (expected 5: 2 iter+1 issues+1 fix+1 converged)"
echo "  tool.call.*:           $TOOL_COUNT (expected 2: skill started+completed)"
echo "  fan-out.spawned:       $FANOUT_COUNT (expected 1)"

[ "$PHASE_COUNT" = "14" ] || { echo "FAIL: phase count"; exit 1; }
[ "$GATE_COUNT" = "2" ]  || { echo "FAIL: gate count"; exit 1; }
[ "$CONS_COUNT" = "5" ]  || { echo "FAIL: consensus count"; exit 1; }
[ "$TOOL_COUNT" = "2" ]  || { echo "FAIL: tool count"; exit 1; }
[ "$FANOUT_COUNT" = "1" ] || { echo "FAIL: fan-out count"; exit 1; }

#==============================================================================
step "Full event timeline"
#==============================================================================
bash "$HOOKS/get-events.sh" --format summary | head -30
echo "..."
bash "$HOOKS/get-events.sh" --format summary | tail -5

echo ""
echo "=============================================="
echo "✓ DOG-FOOD END-TO-END TEST PASSED"
echo "  Events: $TOTAL"
echo "  Phases covered: 1-7 (all)"
echo "  Gates traversed: GATE 1 + GATE 2"
echo "  Primitives exercised: emit-event, get-events, execute, fan-out, read-phase, regenerate-views, wake, replay"
echo "=============================================="
