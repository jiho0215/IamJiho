#!/bin/bash
# Run every tests/v6/*.test.sh and tests/v6/hooks/*.test.sh (phase "shell") and the node tests (phase "node"); print
# PASS/FAIL per file; exit non-zero on any failure. `--phase shell|node` runs one phase (default: both).
# Run it bounded, one phase at a time (ruling R32): `timeout 25m bash tests/v6/run.sh --phase shell`, then
# `timeout 25m bash tests/v6/run.sh --phase node`. Measured on Windows Git Bash (2026-11-17): the shell phase alone
# takes about 25 min under load, so both phases in one 25 min bound do not fit.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE=all
while [ $# -gt 0 ]; do
  case "$1" in
    --phase) PHASE="${2:-}"; shift 2 ;;
    --phase=*) PHASE="${1#--phase=}"; shift ;;
    *) echo "usage: run.sh [--phase shell|node]" >&2; exit 2 ;;
  esac
done
case "$PHASE" in all|shell|node) ;; *) echo "usage: run.sh [--phase shell|node]" >&2; exit 2 ;; esac
fail=0
if [ "$PHASE" != node ]; then
  for t in "$DIR"/*.test.sh "$DIR"/hooks/*.test.sh; do
    [ -e "$t" ] || continue
    name=${t#"$DIR"/}
    if out=$(bash "$t" 2>&1); then echo "PASS $name"; else echo "FAIL $name"; echo "$out" | tail -5 | sed 's/^/    /'; fail=1; fi
  done
fi
if [ "$PHASE" != shell ]; then
  if out=$(cd "$DIR/node" && node --test *.test.mjs 2>&1); then echo "PASS node"; else echo "FAIL node"; echo "$out" | tail -5 | sed 's/^/    /'; fail=1; fi
fi
exit $fail
