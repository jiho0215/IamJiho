#!/bin/bash
# Run every tests/v6/*.test.sh and tests/v6/hooks/*.test.sh; print PASS/FAIL per file; exit non-zero on any failure.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "$DIR"/*.test.sh "$DIR"/hooks/*.test.sh; do
  [ -e "$t" ] || continue
  name=${t#"$DIR"/}
  if out=$(bash "$t" 2>&1); then echo "PASS $name"; else echo "FAIL $name"; echo "$out" | tail -5 | sed 's/^/    /'; fail=1; fi
done
if out=$(cd "$DIR/node" && node --test *.test.mjs 2>&1); then echo "PASS node"; else echo "FAIL node"; echo "$out" | tail -5 | sed 's/^/    /'; fail=1; fi
exit $fail
