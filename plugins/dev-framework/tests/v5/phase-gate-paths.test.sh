#!/bin/bash
set -euo pipefail
SCRIPT="plugins/dev-framework/hooks/scripts/phase-gate.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: phase-gate.sh missing"; exit 1; }
grep -qE 'phases/(spike|implement)/' "$SCRIPT" \
  || { echo "FAIL: phase-gate.sh does not reference new paths"; exit 1; }
echo "PASS"
