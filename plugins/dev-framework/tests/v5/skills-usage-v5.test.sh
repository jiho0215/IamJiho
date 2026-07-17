#!/bin/bash
set -euo pipefail
SP="plugins/dev-framework/skills/spike/SKILL.md"
IM="plugins/dev-framework/skills/implement/SKILL.md"

grep -qF 'research <topic>' "$SP" || { echo "FAIL: spike skill missing research mode"; exit 1; }
grep -qF 'story <ticket' "$SP"    || { echo "FAIL: spike skill missing story mode"; exit 1; }
grep -qF -- '--revisit'    "$SP"  || { echo "FAIL: spike skill missing --revisit"; exit 1; }
grep -qF '<freeze-doc-path>' "$IM" || { echo "FAIL: implement skill missing freeze-doc-path"; exit 1; }

# A command file named after a skill shadows it: the harness treats the rendered
# command as the loaded skill, so SKILL.md never reaches the model (5.0.1).
[ ! -d "plugins/dev-framework/commands" ] \
  || { echo "FAIL: commands/ reintroduced — a same-named command shadows its skill"; exit 1; }
echo "PASS"
