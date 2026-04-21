#!/bin/bash
# M2.5: verify the three new event types populate view fields for near-byte-parity
# with procedural progress-log.json.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
REGEN="$HOOKS/regenerate-views.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-m25","status":"in-progress"}
JSON

# Emit M1 baseline events
bash "$EMIT" session.started --actor orchestrator \
  --data '{"mode":"full-cycle","featureSlug":"parity-test"}'

# --- M2.5: config.snapshot.recorded ---
bash "$EMIT" config.snapshot.recorded --actor orchestrator \
  --data '{"maxReviewIterations":10,"consecutiveZerosToExit":2,"testCoverageTarget":90,"modelProfile":"balanced"}'

# --- M2.5: patterns.loaded ---
bash "$EMIT" patterns.loaded --actor "hook:load-chronic-patterns" \
  --data '{"count":3,"file":"workflow_mistake_patterns.md","chronicPatterns":["P1","P2","P3"]}'

# Phase 1-3 events
bash "$EMIT" phase.started   --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.started   --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.started   --actor orchestrator --data '{"phase":3}'

# --- M2.5: plan.files.set ---
bash "$EMIT" plan.files.set --actor orchestrator \
  --data '{"phase":3,"plannedFiles":["src/auth/login.ts","src/auth/session.ts","tests/auth.test.ts"]}'

bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":3}'

# --- M2.5: patterns.promoted ---
bash "$EMIT" patterns.promoted --actor orchestrator \
  --data '{"id":"P4","pattern":"Missing null check","frequency":3}'

bash "$REGEN"
PV="$DEVFW_TEST_SESSION_DIR/views/progress-log.json"

# --- Verify M2.5 fields ---
CS_ITERS=$(jq -r '.configSnapshot.maxReviewIterations' "$PV")
[ "$CS_ITERS" = "10" ] || { echo "FAIL: configSnapshot.maxReviewIterations ($CS_ITERS)"; exit 1; }

CS_PROFILE=$(jq -r '.configSnapshot.modelProfile' "$PV")
[ "$CS_PROFILE" = "balanced" ] || { echo "FAIL: configSnapshot.modelProfile ($CS_PROFILE)"; exit 1; }

PF_LEN=$(jq -r '.plannedFiles | length' "$PV")
[ "$PF_LEN" = "3" ] || { echo "FAIL: plannedFiles length ($PF_LEN)"; exit 1; }

PF_FIRST=$(jq -r '.plannedFiles[0]' "$PV")
[ "$PF_FIRST" = "src/auth/login.ts" ] || { echo "FAIL: plannedFiles[0]"; exit 1; }

CP_LOADED=$(jq -r '.chronicPatternsLoaded' "$PV")
[ "$CP_LOADED" = "3" ] || { echo "FAIL: chronicPatternsLoaded ($CP_LOADED)"; exit 1; }

PROM=$(jq -r '.summary.patternsPromoted' "$PV")
[ "$PROM" = "1" ] || { echo "FAIL: patternsPromoted ($PROM)"; exit 1; }

DEM=$(jq -r '.summary.patternsDemoted' "$PV")
[ "$DEM" = "0" ] || { echo "FAIL: patternsDemoted ($DEM)"; exit 1; }

# --- Missing events → sensible defaults ---
rm -f "$DEVFW_TEST_SESSION_DIR/events.jsonl" "$DEVFW_TEST_SESSION_DIR/.seq"
bash "$EMIT" session.started --actor orchestrator --data '{"mode":"review"}'
bash "$REGEN"

PF2=$(jq -r '.plannedFiles | length' "$PV")
[ "$PF2" = "0" ] || { echo "FAIL: missing plan defaults to empty ($PF2)"; exit 1; }

CS2=$(jq -r '.configSnapshot' "$PV")
[ "$CS2" = "null" ] || { echo "FAIL: missing config defaults to null ($CS2)"; exit 1; }

CP2=$(jq -r '.chronicPatternsLoaded' "$PV")
[ "$CP2" = "0" ] || { echo "FAIL: missing patterns defaults to 0 ($CP2)"; exit 1; }

echo "PASS: byte-parity (M2.5 fields)"
