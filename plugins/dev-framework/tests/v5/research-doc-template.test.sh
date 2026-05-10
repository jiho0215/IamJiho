#!/bin/bash
set -euo pipefail
F="plugins/dev-framework/skills/spike/references/templates/RESEARCH_DOC_TEMPLATE.md"
[ -f "$F" ] || { echo "FAIL: template missing"; exit 1; }
for sec in "§1 Question" "§2 Methodology" "§3 Findings" "§4 Schemas" \
           "§5 Edge Cases" "§6 Open Questions" "§7 Decision Impact" \
           "§8 References" "§9 Verification Backlog"; do
  grep -qF "$sec" "$F" || { echo "FAIL: section '$sec' missing"; exit 1; }
done
grep -qE '^status:' "$F" || { echo "FAIL: status frontmatter missing"; exit 1; }
echo "PASS"
