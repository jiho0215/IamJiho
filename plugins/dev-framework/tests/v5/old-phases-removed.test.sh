#!/bin/bash
set -euo pipefail
for f in phase-1 phase-2 phase-3 phase-4; do
  [ ! -f "plugins/dev-framework/phases/$f.yaml" ] \
    || { echo "FAIL: $f.yaml still exists"; exit 1; }
done
echo "PASS"
