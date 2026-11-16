#!/bin/bash
# pr-size: weighted-line read-time estimate, planned and diff modes, exact values.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS="$DIR/../../bin/pr-size"
[ -x "$PS" ] || { echo "FAIL: bin/pr-size missing or not executable"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export DEVFW_CONFIG="$TMP/none.json"   # defaults only, unless a case sets its own

expect() {  # expect <label> <json> <jq-filter> <want>
  local got; got=$(jq -r "$3" <<<"$2")
  [ "$got" = "$4" ] || { echo "FAIL: $1: $3 = $got, want $4 (out: $2)"; exit 1; }
}
planned() { echo "$1" > "$TMP/p.json"; set +e; OUT=$("$PS" --planned "$TMP/p.json"); RC=$?; set -e; }

# A: one logic file +100
planned '[{"path":"src/a.cs","kind":"logic","added":100,"deleted":0}]'
expect A "$OUT" .files 1; expect A "$OUT" .weightedLines 100; expect A "$OUT" .seconds 170
expect A "$OUT" .limit 240; expect A "$OUT" .verdict ok; [ $RC -eq 0 ] || { echo "FAIL: A rc $RC"; exit 1; }
A_OUT="$OUT"

# B: + one test file +100 -> tests weigh 0.3
planned '[{"path":"src/a.cs","kind":"logic","added":100,"deleted":0},{"path":"tests/aTests.cs","kind":"test","added":100,"deleted":0}]'
expect B "$OUT" .files 2; expect B "$OUT" .weightedLines 130; expect B "$OUT" .seconds 235; expect B "$OUT" .verdict ok

# C: risk path multiplies by 3 -> over
echo '{"prSize":{"riskGlobs":["src/auth/**"]}}' > "$TMP/risk.json"
echo '[{"path":"src/auth/x.cs","kind":"logic","added":100,"deleted":0}]' > "$TMP/p.json"
set +e; OUT=$(DEVFW_CONFIG="$TMP/risk.json" "$PS" --planned "$TMP/p.json"); RC=$?; set -e
expect C "$OUT" .weightedLines 300; expect C "$OUT" .seconds 470; expect C "$OUT" .verdict over
[ $RC -eq 5 ] || { echo "FAIL: C rc $RC, want 5"; exit 1; }

# D: generated files score nothing and are not counted
planned '[{"path":"src/a.cs","kind":"logic","added":100,"deleted":0},{"path":"pkg.lock","kind":"generated","added":5000,"deleted":0}]'
[ "$OUT" = "$A_OUT" ] || { echo "FAIL: D differs from A: $OUT"; exit 1; }

# E: empty -> ok
planned '[]'
expect E "$OUT" .files 0; expect E "$OUT" .seconds 0; expect E "$OUT" .verdict ok

# deleted lines weigh 0.3; config 0.3
planned '[{"path":"src/a.cs","kind":"logic","added":0,"deleted":100},{"path":"app.json","kind":"config","added":10,"deleted":0}]'
expect F "$OUT" .weightedLines 33

# diff mode: pure rename scores nothing; glob detection of a test path
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -C "$TMP/r" "$@"; }
mkdir -p "$TMP/r/src"; git init -q "$TMP/r"
seq 1 10 > "$TMP/r/src/a.cs"; echo same > "$TMP/r/old.txt"; g add -A; g commit -qm one
seq 11 30 >> "$TMP/r/src/a.cs"; g mv old.txt new.txt; g add -A; g commit -qm two
OUT=$("$PS" --diff HEAD~1..HEAD --repo-dir "$TMP/r")
expect diff "$OUT" .files 1; expect diff "$OUT" .weightedLines 20; expect diff "$OUT" .limit 300
mkdir -p "$TMP/r/src/__tests__"; seq 1 10 > "$TMP/r/src/__tests__/a.test.ts"; g add -A; g commit -qm three
OUT=$("$PS" --diff HEAD~1..HEAD --repo-dir "$TMP/r")
expect difftest "$OUT" .weightedLines 3

set +e; "$PS" --bogus >/dev/null 2>&1; RC=$?; set -e
[ $RC -eq 2 ] || { echo "FAIL: bad args rc $RC"; exit 1; }
echo ok
