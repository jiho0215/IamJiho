#!/bin/bash
set -euo pipefail
DIR="plugins/dev-framework/phases/spike"
[ -d "$DIR" ] || { echo "FAIL: spike phases dir missing"; exit 1; }
for p in p1-scope p2-investigate p3-decompose p4-spec p5-review p6-approve p7-retro; do
  F="$DIR/$p.yaml"
  [ -f "$F" ] || { echo "FAIL: $p.yaml missing"; exit 1; }
  grep -qE '^id:' "$F" || { echo "FAIL: $p missing 'id:'"; exit 1; }
  grep -qE '^primaryAgent:' "$F" || { echo "FAIL: $p missing 'primaryAgent:'"; exit 1; }
  grep -qE '^modes:' "$F" || { echo "FAIL: $p missing 'modes:'"; exit 1; }
done
echo "PASS"
