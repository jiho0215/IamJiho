#!/bin/bash
set -euo pipefail
SPIKE="plugins/dev-framework/skills/spike/references/templates/FREEZE_DOC_TEMPLATE.md"
IMPL_OLD="plugins/dev-framework/skills/implement/references/templates/FREEZE_DOC_TEMPLATE.md"
[ -f "$SPIKE" ] || { echo "FAIL: not at spike location"; exit 1; }
[ ! -f "$IMPL_OLD" ] || { echo "FAIL: still at implement location"; exit 1; }
grep -q '^approvedHash:' "$SPIKE" \
  || { echo "FAIL: approvedHash header missing"; exit 1; }
grep -qF '§11 Prerequisites' "$SPIKE" \
  || { echo "FAIL: §11 Prerequisites missing"; exit 1; }
echo "PASS"
