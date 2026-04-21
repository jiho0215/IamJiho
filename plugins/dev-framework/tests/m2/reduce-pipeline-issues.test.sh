#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
REDUCER="$HOOKS/reduce-pipeline-issues.sh"

[ -x "$REDUCER" ] || { echo "FAIL: reducer not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-aaa","status":"in-progress"}
JSON

bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":5,"iteration":1}'
bash "$EMIT" consensus.issues.found      --actor "agent:x" --data '{"phase":5,"iteration":1,"issues":[{"s":"H"},{"s":"M"},{"s":"L"}]}'
bash "$EMIT" consensus.fix.applied       --actor orchestrator --data '{"phase":5,"iteration":1,"issueId":"I1"}'
bash "$EMIT" consensus.fix.applied       --actor orchestrator --data '{"phase":5,"iteration":1,"issueId":"I2"}'
bash "$EMIT" consensus.fix.applied       --actor orchestrator --data '{"phase":5,"iteration":1,"issueId":"I3"}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":5,"iteration":2}'
bash "$EMIT" consensus.converged         --actor orchestrator --data '{"phase":5,"iterations":2,"issuesFixed":3}'

bash "$REDUCER"
VIEW="$DEVFW_TEST_SESSION_DIR/views/pipeline-issues.json"
[ -f "$VIEW" ] || { echo "FAIL: view not created"; exit 1; }

[ "$(jq -r '.runs | length' "$VIEW")" = "1" ] || { echo "FAIL: runs length"; exit 1; }
[ "$(jq -r '.runs[0].runId' "$VIEW")" = "run-aaa" ] || { echo "FAIL: runId"; exit 1; }
[ "$(jq -r '.runs[0].phases."5".iterations | length' "$VIEW")" = "2" ] || { echo "FAIL: iterations length"; exit 1; }
[ "$(jq -r '.runs[0].phases."5".iterations[0].issuesFound' "$VIEW")" = "3" ] || { echo "FAIL: issuesFound"; exit 1; }
[ "$(jq -r '.runs[0].phases."5".iterations[0].fixesApplied' "$VIEW")" = "3" ] || { echo "FAIL: fixesApplied"; exit 1; }
[ "$(jq -r '.runs[0].phases."5".converged' "$VIEW")" = "true" ] || { echo "FAIL: converged"; exit 1; }
[ "$(jq -r '.runs[0].phases."5".remainingIssues' "$VIEW")" = "0" ] || { echo "FAIL: remainingIssues"; exit 1; }

# Second run with forced_stop
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":6,"iteration":1}'
bash "$EMIT" consensus.issues.found      --actor "agent:y" --data '{"phase":6,"iteration":1,"issues":[{"s":"C"},{"s":"C"}]}'
bash "$EMIT" consensus.forced_stop       --actor orchestrator --data '{"phase":6,"iterations":10,"remainingIssues":2}'

bash "$REDUCER"
[ "$(jq -r '.runs[0].phases."6".converged' "$VIEW")" = "false" ] || { echo "FAIL: p6 converged"; exit 1; }
[ "$(jq -r '.runs[0].phases."6".remainingIssues' "$VIEW")" = "2" ] || { echo "FAIL: p6 remaining"; exit 1; }

echo "PASS: reduce-pipeline-issues"
