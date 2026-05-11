#!/bin/bash
set -euo pipefail
DIR="plugins/dev-framework/phases/implement"
[ -d "$DIR" ] || { echo "FAIL: implement phases dir missing"; exit 1; }
for e in e1-execute e2-verify e3-finalize; do
  F="$DIR/$e.yaml"
  [ -f "$F" ] || { echo "FAIL: $e.yaml missing"; exit 1; }
  grep -qE '^id: implement\.' "$F" || { echo "FAIL: $e missing 'id: implement.*'"; exit 1; }
done
# Old files must be gone
for old in phase-5 phase-6 phase-7; do
  [ ! -f "plugins/dev-framework/phases/$old.yaml" ] \
    || { echo "FAIL: old $old.yaml still exists"; exit 1; }
done
echo "PASS"
