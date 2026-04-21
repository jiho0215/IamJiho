#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
REDUCER="$HOOKS/reduce-progress-log.sh"

[ -x "$REDUCER" ] || { echo "FAIL: reducer not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-abc","status":"in-progress"}
JSON

# Seed events: phase1 complete, phase2 complete, phase3 in-progress, 1 bypass, 2 consensus iterations in phase3
bash "$EMIT" session.started --actor orchestrator --data '{"mode":"full-cycle","featureSlug":"test-feat"}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":3}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":3,"iteration":1}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":3,"iteration":2}'
bash "$EMIT" bypass.created --actor orchestrator --data '{"feature":"test-feat","reason":"emergency","userMessage":"bypass"}'

bash "$REDUCER"
VIEW="$DEVFW_TEST_SESSION_DIR/views/progress-log.json"
[ -f "$VIEW" ] || { echo "FAIL: view not created"; exit 1; }
jq empty "$VIEW" || { echo "FAIL: view invalid JSON"; exit 1; }

# Assertions
[ "$(jq -r '.status' "$VIEW")" = "in-progress" ] || { echo "FAIL: status"; exit 1; }
[ "$(jq -r '.mode' "$VIEW")" = "full-cycle" ] || { echo "FAIL: mode"; exit 1; }
[ "$(jq -r '.featureSlug' "$VIEW")" = "test-feat" ] || { echo "FAIL: featureSlug"; exit 1; }
[ "$(jq -r '.runId' "$VIEW")" = "run-abc" ] || { echo "FAIL: runId"; exit 1; }
[ "$(jq -r '.currentPhase' "$VIEW")" = "3" ] || { echo "FAIL: currentPhase"; exit 1; }
[ "$(jq -r '.phases | length' "$VIEW")" = "3" ] || { echo "FAIL: phases length"; exit 1; }
[ "$(jq -r '.phases[0].status' "$VIEW")" = "completed" ] || { echo "FAIL: phase1 status"; exit 1; }
[ "$(jq -r '.phases[2].status' "$VIEW")" = "in-progress" ] || { echo "FAIL: phase3 status"; exit 1; }
[ "$(jq -r '.summary.bypassCount' "$VIEW")" = "1" ] || { echo "FAIL: bypassCount"; exit 1; }
[ "$(jq -r '.summary.consensusRounds.phase3' "$VIEW")" = "2" ] || { echo "FAIL: consensusRounds.phase3"; exit 1; }

# After session.interrupted, status should flip to interrupted
bash "$EMIT" session.interrupted --actor "hook:sessionend" --data '{"interruptedAt":"2026-04-20T12:00:00Z","currentPhase":3}'
bash "$REDUCER"
[ "$(jq -r '.status' "$VIEW")" = "interrupted" ] || { echo "FAIL: status after interrupt"; exit 1; }
[ "$(jq -r '.interruptedAt' "$VIEW")" = "2026-04-20T12:00:00Z" ] || { echo "FAIL: interruptedAt"; exit 1; }

# After session.completed, status → completed
bash "$EMIT" session.completed --actor orchestrator --data '{"totalMinutes":45}'
bash "$REDUCER"
[ "$(jq -r '.status' "$VIEW")" = "completed" ] || { echo "FAIL: status after complete"; exit 1; }

echo "PASS: reduce-progress-log"
