#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
REGEN="$HOOKS/regenerate-views.sh"

[ -x "$REGEN" ] || { echo "FAIL: regenerate-views not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-xyz","status":"in-progress"}
JSON

bash "$EMIT" session.started --actor orchestrator --data '{"mode":"full-cycle","featureSlug":"x"}'
bash "$EMIT" decision.recorded --actor orchestrator --data '{"id":"D001","phase":1,"category":"plan","decision":"a","reason":"b","confidence":"high"}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":5,"iteration":1}'

bash "$REGEN"

VIEWS="$DEVFW_TEST_SESSION_DIR/views"
[ -f "$VIEWS/progress-log.json" ] || { echo "FAIL: progress-log not generated"; exit 1; }
[ -f "$VIEWS/decision-log.json" ] || { echo "FAIL: decision-log not generated"; exit 1; }
[ -f "$VIEWS/pipeline-issues.json" ] || { echo "FAIL: pipeline-issues not generated"; exit 1; }

for f in "$VIEWS"/*.json; do
  jq empty "$f" || { echo "FAIL: $f invalid JSON"; exit 1; }
done

# Idempotency: running again produces same content (regeneratedAt may differ)
sleep 1
bash "$REGEN"
[ -f "$VIEWS/progress-log.json" ] || { echo "FAIL: idempotent regen lost progress-log"; exit 1; }

# No events.jsonl → no-op, no error
rm "$DEVFW_TEST_SESSION_DIR/events.jsonl"
bash "$REGEN"

echo "PASS: regenerate-views"
