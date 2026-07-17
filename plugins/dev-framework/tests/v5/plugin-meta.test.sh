#!/bin/bash
set -euo pipefail
PJ="plugins/dev-framework/.claude-plugin/plugin.json"
CL="plugins/dev-framework/CHANGELOG.md"
CM="plugins/dev-framework/CLAUDE.md"

grep -q '"version": "5.0.1"' "$PJ" \
  || { echo "FAIL: plugin.json not 5.0.1"; exit 1; }
grep -qF '## [5.0.1]' "$CL" \
  || { echo "FAIL: CHANGELOG missing 5.0.1 section"; exit 1; }
grep -qF 'E1 Execute' "$CM" \
  || { echo "FAIL: CLAUDE.md not updated for E1-E3"; exit 1; }
grep -qF 'research-investigator' "$CM" \
  || { echo "FAIL: CLAUDE.md missing research-investigator agent"; exit 1; }
echo "PASS"
