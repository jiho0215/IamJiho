#!/bin/bash
# Stress-test events.jsonl concurrency guarantees under heavy parallelism.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
GET="$HOOKS/get-events.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

# Scenario 1: 50 parallel emits → unique contiguous seqs
N=50
for i in $(seq 1 $N); do
  bash "$EMIT" stress.test --data "{\"i\":$i}" --actor "stress-$i" &
done
wait

LINES=$(wc -l < "$DEVFW_TEST_SESSION_DIR/events.jsonl")
[ "$LINES" = "$N" ] || { echo "FAIL: expected $N lines, got $LINES"; exit 1; }

UNIQUE_SEQS=$(jq -r '.seq' "$DEVFW_TEST_SESSION_DIR/events.jsonl" | tr -d '\r' | sort -n | uniq | wc -l | tr -d ' ')
[ "$UNIQUE_SEQS" = "$N" ] || { echo "FAIL: seq collisions ($UNIQUE_SEQS unique of $N)"; exit 1; }

MIN=$(jq -r '.seq' "$DEVFW_TEST_SESSION_DIR/events.jsonl" | tr -d '\r' | sort -n | head -1)
MAX=$(jq -r '.seq' "$DEVFW_TEST_SESSION_DIR/events.jsonl" | tr -d '\r' | sort -n | tail -1)
[ "$MIN" = "1" ] || { echo "FAIL: min seq != 1 (got $MIN)"; exit 1; }
[ "$MAX" = "$N" ] || { echo "FAIL: max seq != $N (got $MAX)"; exit 1; }

# All events are valid JSON (use -s to handle multi-object stream)
jq -s 'length' "$DEVFW_TEST_SESSION_DIR/events.jsonl" > /dev/null || { echo "FAIL: events.jsonl has malformed lines"; exit 1; }

# Scenario 2: Mixed emitters (3 phase transitions + 20 consensus events) in parallel
rm -f "$DEVFW_TEST_SESSION_DIR/events.jsonl" "$DEVFW_TEST_SESSION_DIR/.seq"
for i in 1 2 3; do
  bash "$EMIT" phase.started --actor orchestrator --data "{\"phase\":$i}" &
done
for i in $(seq 1 20); do
  bash "$EMIT" consensus.iteration.started --actor "agent-$i" --data "{\"phase\":5,\"iteration\":$i}" &
done
wait

TOTAL=$(wc -l < "$DEVFW_TEST_SESSION_DIR/events.jsonl")
[ "$TOTAL" = "23" ] || { echo "FAIL: mixed emitters total ($TOTAL)"; exit 1; }

PHASE_COUNT=$(bash "$GET" --type 'phase.*' --format count)
[ "$PHASE_COUNT" = "3" ] || { echo "FAIL: phase count != 3 (got $PHASE_COUNT)"; exit 1; }
CONS_COUNT=$(bash "$GET" --type 'consensus.*' --format count)
[ "$CONS_COUNT" = "20" ] || { echo "FAIL: consensus count != 20 (got $CONS_COUNT)"; exit 1; }

echo "PASS: concurrency-stress ($N parallel + 23 mixed)"
