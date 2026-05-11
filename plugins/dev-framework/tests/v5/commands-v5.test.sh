#!/bin/bash
set -euo pipefail
SP="plugins/dev-framework/commands/spike.md"
IM="plugins/dev-framework/commands/implement.md"

grep -qF 'research <topic>' "$SP" || { echo "FAIL: spike cmd missing research mode"; exit 1; }
grep -qF 'story <ticket' "$SP"    || { echo "FAIL: spike cmd missing story mode"; exit 1; }
grep -qF -- '--revisit'    "$SP"  || { echo "FAIL: spike cmd missing --revisit"; exit 1; }
grep -qF '<freeze-doc-path>' "$IM" || { echo "FAIL: implement cmd missing freeze-doc-path"; exit 1; }
echo "PASS"
