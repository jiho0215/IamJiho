#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READ="$SCRIPT_DIR/../../hooks/scripts/read-phase.sh"
[ -x "$READ" ] || { echo "FAIL: read-phase.sh not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/phase-test.yaml" <<'YAML'
phase: 3
name: "Test Phase"
skillMdSection: "Phase 3 — Test"
requiredRefs:
  - methodology/DECISION_MAKING.md
  - protocols/multi-agent-consensus.md
budget:
  seconds: 120
userGate: 1
YAML

# Scalars
[ "$(bash "$READ" "$TMP/phase-test.yaml" phase)" = "3" ] || { echo "FAIL: phase scalar"; exit 1; }
[ "$(bash "$READ" "$TMP/phase-test.yaml" name)" = "Test Phase" ] || { echo "FAIL: name scalar"; exit 1; }
[ "$(bash "$READ" "$TMP/phase-test.yaml" budget.seconds)" = "120" ] || { echo "FAIL: nested scalar"; exit 1; }
[ "$(bash "$READ" "$TMP/phase-test.yaml" userGate)" = "1" ] || { echo "FAIL: userGate"; exit 1; }

# List
REFS=$(bash "$READ" "$TMP/phase-test.yaml" requiredRefs)
echo "$REFS" | grep -q "methodology/DECISION_MAKING.md" || { echo "FAIL: list item 1"; exit 1; }
echo "$REFS" | grep -q "protocols/multi-agent-consensus.md" || { echo "FAIL: list item 2"; exit 1; }
LINES=$(echo "$REFS" | grep -c . || true)
[ "$LINES" = "2" ] || { echo "FAIL: list count (got $LINES)"; exit 1; }

# Missing key → empty
OUT=$(bash "$READ" "$TMP/phase-test.yaml" nonexistent)
[ -z "$OUT" ] || { echo "FAIL: missing key should be empty"; exit 1; }

# Missing file → exit 1
set +e
bash "$READ" "$TMP/nonexistent.yaml" phase 2>/dev/null
RC=$?
set -e
[ "$RC" = "1" ] || { echo "FAIL: missing file should exit 1"; exit 1; }

echo "PASS: read-phase"
