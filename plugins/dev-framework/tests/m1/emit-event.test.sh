#!/bin/bash
# Verify emit-event.sh creates valid JSONL entries with atomic seq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"

[ -x "$EMIT" ] || { echo "FAIL: emit-event.sh not found or not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Test 1: no-op when session dir missing ---
export DEVFW_TEST_SESSION_DIR="$TMP/nonexistent"
bash "$EMIT" test.noop --data '{}' 2>/dev/null
[ ! -f "$TMP/nonexistent/events.jsonl" ] \
  || { echo "FAIL: no-op path created events.jsonl"; exit 1; }

# --- Test 2: happy path writes valid JSON with seq=1 ---
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
bash "$EMIT" phase.started --data '{"phase":1}' --actor "test"
EVENTS="$DEVFW_TEST_SESSION_DIR/events.jsonl"
[ -f "$EVENTS" ] || { echo "FAIL: events.jsonl not created"; exit 1; }
LINE=$(cat "$EVENTS")
echo "$LINE" | jq empty || { echo "FAIL: line is not valid JSON"; exit 1; }
[ "$(echo "$LINE" | jq -r '.seq')" = "1" ] \
  || { echo "FAIL: seq != 1 (got $(echo "$LINE" | jq -r '.seq'))"; exit 1; }
[ "$(echo "$LINE" | jq -r '.type')" = "phase.started" ] \
  || { echo "FAIL: type mismatch"; exit 1; }
[ "$(echo "$LINE" | jq -r '.actor')" = "test" ] \
  || { echo "FAIL: actor mismatch"; exit 1; }
[ "$(echo "$LINE" | jq -r '.data.phase')" = "1" ] \
  || { echo "FAIL: data.phase mismatch"; exit 1; }

# --- Test 3: subsequent emits increment seq ---
bash "$EMIT" phase.completed --data '{"phase":1}' --actor "test"
bash "$EMIT" phase.started --data '{"phase":2}' --actor "test"
COUNT=$(wc -l < "$EVENTS")
[ "$COUNT" -eq 3 ] || { echo "FAIL: expected 3 events, got $COUNT"; exit 1; }
SEQ2=$(sed -n '2p' "$EVENTS" | jq -r '.seq')
SEQ3=$(sed -n '3p' "$EVENTS" | jq -r '.seq')
[ "$SEQ2" = "2" ] || { echo "FAIL: seq2 != 2 (got $SEQ2)"; exit 1; }
[ "$SEQ3" = "3" ] || { echo "FAIL: seq3 != 3 (got $SEQ3)"; exit 1; }

# --- Test 4: concurrent emits do not duplicate seq ---
rm -f "$EVENTS" "$DEVFW_TEST_SESSION_DIR/.seq"
for i in 1 2 3 4 5 6 7 8 9 10; do
  bash "$EMIT" concurrent.test --data "{\"i\":$i}" --actor "test" &
done
wait
COUNT=$(wc -l < "$EVENTS")
[ "$COUNT" -eq 10 ] || { echo "FAIL: expected 10 events under concurrency, got $COUNT"; exit 1; }
UNIQUE_SEQS=$(jq -r '.seq' "$EVENTS" | sort -n | uniq | wc -l)
[ "$UNIQUE_SEQS" -eq 10 ] || { echo "FAIL: seq collisions under concurrency ($UNIQUE_SEQS unique of 10)"; exit 1; }

# --- Test 5: invalid --data JSON is rejected (falls back to {}) ---
rm -f "$EVENTS" "$DEVFW_TEST_SESSION_DIR/.seq"
bash "$EMIT" bad.data --data 'not-json' --actor "test"
DATA=$(jq -r '.data' "$EVENTS")
[ "$DATA" = "{}" ] || { echo "FAIL: invalid data not sanitized (got $DATA)"; exit 1; }

# --- Test 6: runId pulled from progress-log.json when present ---
rm -f "$EVENTS" "$DEVFW_TEST_SESSION_DIR/.seq"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-abc-123","status":"in-progress"}
JSON
bash "$EMIT" runid.test --data '{}' --actor "test"
RID=$(jq -r '.runId' "$EVENTS")
[ "$RID" = "run-abc-123" ] || { echo "FAIL: runId not auto-pulled (got $RID)"; exit 1; }

# --- Test 7: --run-id override takes precedence ---
bash "$EMIT" runid.override --data '{}' --actor "test" --run-id "run-override-999"
RID=$(sed -n '2p' "$EVENTS" | jq -r '.runId')
[ "$RID" = "run-override-999" ] || { echo "FAIL: runId override ignored (got $RID)"; exit 1; }

echo "PASS: emit-event"
