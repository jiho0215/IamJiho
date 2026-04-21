#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
REDUCER="$HOOKS/reduce-decision-log.sh"

[ -x "$REDUCER" ] || { echo "FAIL: reducer not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

bash "$EMIT" decision.recorded --actor orchestrator \
  --data '{"id":"D001","phase":1,"category":"plan","decision":"use OAuth","reason":"industry standard","confidence":"high"}'
bash "$EMIT" gate.approved --actor orchestrator --data '{"gate":1,"approvalMode":"interactive","approvedBy":"test"}'
bash "$EMIT" bypass.created --actor orchestrator --data '{"feature":"f","reason":"emergency","userMessage":"m"}'
bash "$EMIT" phase.failed --actor orchestrator --data '{"phase":4,"error":"test failed"}'

bash "$REDUCER"
VIEW="$DEVFW_TEST_SESSION_DIR/views/decision-log.json"
[ -f "$VIEW" ] || { echo "FAIL: view not created"; exit 1; }

COUNT=$(jq -r '.decisions | length' "$VIEW")
[ "$COUNT" = "4" ] || { echo "FAIL: decisions count != 4 (got $COUNT)"; exit 1; }

[ "$(jq -r '.decisions[0].id' "$VIEW")" = "D001" ] || { echo "FAIL: id D001"; exit 1; }
[ "$(jq -r '.decisions[0].category' "$VIEW")" = "plan" ] || { echo "FAIL: category plan"; exit 1; }

HAS_G1=$(jq -r '.decisions[] | select(.category == "gate-1") | .category' "$VIEW")
[ "$HAS_G1" = "gate-1" ] || { echo "FAIL: gate-1 derived"; exit 1; }

HAS_BP=$(jq -r '.decisions[] | select(.category == "bypass") | .category' "$VIEW")
[ "$HAS_BP" = "bypass" ] || { echo "FAIL: bypass derived"; exit 1; }

HAS_PF=$(jq -r '.decisions[] | select(.category == "phase-failure") | .category' "$VIEW")
[ "$HAS_PF" = "phase-failure" ] || { echo "FAIL: phase-failure derived"; exit 1; }

# Sorted by seq
SEQS=$(jq -r '.decisions[].seq' "$VIEW" | tr -d '\r' | paste -sd,)
[ "$SEQS" = "1,2,3,4" ] || { echo "FAIL: seq order ($SEQS)"; exit 1; }

echo "PASS: reduce-decision-log"
