#!/bin/bash
# Verify get-events.sh filters correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
GET="$HOOKS/get-events.sh"

[ -x "$GET" ] || { echo "FAIL: get-events.sh not found or not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

# Seed 5 events
bash "$EMIT" phase.started         --data '{"phase":1}' --actor "orchestrator"
bash "$EMIT" phase.completed       --data '{"phase":1}' --actor "orchestrator"
bash "$EMIT" phase.started         --data '{"phase":2}' --actor "orchestrator"
bash "$EMIT" consensus.issue.found --data '{"phase":2,"severity":"HIGH"}' --actor "agent:architect"
bash "$EMIT" phase.completed       --data '{"phase":2}' --actor "orchestrator"

# --- Test 1: no filter -> all events ---
COUNT=$(bash "$GET" --format count)
[ "$COUNT" = "5" ] || { echo "FAIL: no filter count != 5 (got $COUNT)"; exit 1; }

# --- Test 2: exact type match ---
COUNT=$(bash "$GET" --type phase.started --format count)
[ "$COUNT" = "2" ] || { echo "FAIL: exact type count != 2 (got $COUNT)"; exit 1; }

# --- Test 3: prefix type match ---
COUNT=$(bash "$GET" --type 'phase.*' --format count)
[ "$COUNT" = "4" ] || { echo "FAIL: prefix type count != 4 (got $COUNT)"; exit 1; }

# --- Test 4: phase filter ---
COUNT=$(bash "$GET" --phase 2 --format count)
[ "$COUNT" = "3" ] || { echo "FAIL: phase filter count != 3 (got $COUNT)"; exit 1; }

# --- Test 5: since-seq ---
COUNT=$(bash "$GET" --since-seq 4 --format count)
[ "$COUNT" = "2" ] || { echo "FAIL: since-seq count != 2 (got $COUNT)"; exit 1; }

# --- Test 6: actor prefix ---
COUNT=$(bash "$GET" --actor 'agent:*' --format count)
[ "$COUNT" = "1" ] || { echo "FAIL: actor prefix count != 1 (got $COUNT)"; exit 1; }

# --- Test 7: limit ---
COUNT=$(bash "$GET" --limit 2 --format count)
[ "$COUNT" = "2" ] || { echo "FAIL: limit count != 2 (got $COUNT)"; exit 1; }

# --- Test 8: summary format is tab-separated ---
SUMMARY=$(bash "$GET" --type phase.started --format summary | head -n1)
echo "$SUMMARY" | grep -q $'\t' || { echo "FAIL: summary missing tabs"; exit 1; }

# --- Test 9: combined filter ---
COUNT=$(bash "$GET" --type 'phase.*' --phase 2 --format count)
[ "$COUNT" = "2" ] || { echo "FAIL: combined filter count != 2 (got $COUNT)"; exit 1; }

# --- Test 10: until-seq ---
COUNT=$(bash "$GET" --until-seq 2 --format count)
[ "$COUNT" = "2" ] || { echo "FAIL: until-seq count != 2 (got $COUNT)"; exit 1; }

# --- Test 11: nonexistent events.jsonl -> exit 0, count 0 ---
rm "$DEVFW_TEST_SESSION_DIR/events.jsonl"
OUT=$(bash "$GET" --format count)
[ "$OUT" = "0" ] || { echo "FAIL: missing events.jsonl should give 0 (got '$OUT')"; exit 1; }

# --- Test 12: json format outputs one JSON per line ---
bash "$EMIT" json.format.test --data '{}' --actor "test"
LINES=$(bash "$GET" --format json | wc -l)
[ "$LINES" = "1" ] || { echo "FAIL: json format line count wrong ($LINES)"; exit 1; }
bash "$GET" --format json | jq empty || { echo "FAIL: json format not valid JSON"; exit 1; }

echo "PASS: get-events"
