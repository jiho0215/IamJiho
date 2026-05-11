#!/bin/bash
set -euo pipefail
F="plugins/dev-framework/skills/spike/references/guardrails.md"
[ -f "$F" ] || { echo "FAIL: file missing"; exit 1; }
for kw in SOLID DRY YAGNI "Open/Closed" "edge case" "repo style" "ADR" "inline comment"; do
  grep -qi "$kw" "$F" || { echo "FAIL: keyword '$kw' missing"; exit 1; }
done
echo "PASS"
