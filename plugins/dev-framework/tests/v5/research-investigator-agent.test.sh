#!/bin/bash
set -euo pipefail
F="plugins/dev-framework/agents/research-investigator.md"
[ -f "$F" ] || { echo "FAIL: agent missing"; exit 1; }
grep -qE '^name: research-investigator' "$F" \
  || { echo "FAIL: name frontmatter wrong"; exit 1; }
for tool in WebFetch WebSearch Read Write Grep Glob Bash AskUserQuestion NotebookRead; do
  grep -q "$tool" "$F" || { echo "FAIL: tool $tool missing"; exit 1; }
done
for kw in "verified-empirically" "doc-only" "inferred-from-code" "user-confirmed" \
          "REDACTED" "Bash" "read-only" "redispatched"; do
  grep -qF "$kw" "$F" || { echo "FAIL: keyword '$kw' missing"; exit 1; }
done
echo "PASS"
