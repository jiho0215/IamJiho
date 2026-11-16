#!/bin/bash
# stop-check: progress-based stop codes over a run ledger; each fixture isolates one rule.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$DIR/../../bin/stop-check"
[ -x "$SC" ] || { echo "FAIL: bin/stop-check missing or not executable"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
L="$TMP/ledger.jsonl"

# R <round> <tree> <blocking-json> [failing-json] [extra-json-fields] -> one ledger line
R() { local f="${4:-[]}" x="${5:-}"; echo "{\"stage\":\"${STAGE:-review}\",\"round\":$1,\"tree\":\"$2\",\"blocking\":$3,\"failing\":$f,\"toolCalls\":${TC:-10},\"tokens\":1000,\"budget\":{\"toolCalls\":100,\"tokens\":100000},\"env\":false,\"gate\":false${x:+,$x}}"; }
check() {  # check <label> <want-code> <want-exit> [reason-substring]
  set +e; OUT=$("$SC" --ledger "$L" --stage review); RC=$?; set -e
  [ "$(jq -r .code <<<"$OUT")" = "$2" ] || { echo "FAIL: $1: code $(jq -r .code <<<"$OUT"), want $2 ($OUT)"; exit 1; }
  [ "$RC" -eq "$3" ] || { echo "FAIL: $1: exit $RC, want $3"; exit 1; }
  [ -z "${4:-}" ] || grep -qF "$4" <<<"$(jq -r .reason <<<"$OUT")" || { echo "FAIL: $1: reason lacks '$4': $OUT"; exit 1; }
}

: > "$L";                                                          check empty continue 0
R 1 t1 '["F1"]' > "$L";                                            check one-round continue 0
{ R 1 t1 '["F1","F2"]'; R 2 t2 '["F1"]'; } > "$L";                 check productive continue 0
[ "$(jq -r '.checkIn // false' <<<"$OUT")" = false ] || { echo "FAIL: checkIn on round 2"; exit 1; }

{ R 1 t1 '["F1","F2"]'; R 2 t1 '["F1"]'; } > "$L";                check stalled-a stalled 10 "stalled(a)"
{ R 1 t1 '["a","b","c"]'; R 2 t2 '["a","b"]'; R 3 t1 '["a"]'; } > "$L"; check stalled-b stalled 10 "stalled(b)"
{ R 1 t1 '["a","b","c"]' '["X|e"]'; R 2 t2 '["a","b"]' '["X|e"]'; R 3 t3 '["a"]' '["X|e"]'; } > "$L"; check stalled-c stalled 10 "stalled(c)"
{ R 1 t1 '["F1","F4","F5"]'; R 2 t2 '["F2"]'; R 3 t3 '["F1"]'; } > "$L"; check stalled-d stalled 10 "stalled(d)"
{ R 1 t1 '["a","b"]'; R 2 t2 '["c","d"]'; R 3 t3 '["e","f"]'; } > "$L";   check stalled-e stalled 10 "stalled(e)"

{ R 1 t1 '["a"]'; R 2 t2 '[]' '[]'; } > "$L";                      check solved solved 10
{ R 1 t1 '["a"]' '[]' '"env":true'; } | sed 's/"env":false,//' > "$L"; check env env 10
{ R 1 t1 '["a"]' '[]' '"gate":true'; } | sed 's/"gate":false,//' > "$L"; check gate gate_required 10

TC=250
{ R 1 t1 '["a","b","c"]' '[]'; R 2 t2 '["a","b"]' '["x|e1"]'; R 3 t3 '["a"]' '["x|e1","y|e2"]'; } > "$L"; check exhausted exhausted 10
{ R 1 t1 '["a","b","c"]'; R 2 t2 '["a","b"]'; R 3 t3 '["a"]'; } > "$L";      check over-budget-but-progressing continue 0
TC=10

{ R 1 t1 '["a"]'; echo '{"stage":"review","round":2,'; } > "$L";   check malformed failed 1
{ R 1 t1 '["a"]'; echo '{"stage":"review","round":2,"blocking":[]}'; } > "$L"; check missing-tree failed 1

{ R 1 t1 '["1","2","3","4","5","6"]'; R 2 t2 '["1","2","3","4","5"]'; R 3 t3 '["1","2","3","4"]'; R 4 t4 '["1","2","3"]'; R 5 t5 '["1","2"]'; } > "$L"
check five-productive continue 0
[ "$(jq -r '.checkIn // false' <<<"$OUT")" = true ] || { echo "FAIL: no checkIn at round 5: $OUT"; exit 1; }

{ STAGE=verify R 1 v1 '["z"]'; R 1 t1 '["a","b"]'; STAGE=verify R 2 v1 '["z"]'; R 2 t2 '["a"]'; } > "$L"
check other-stage-ignored continue 0

# Important 1: lines without a top-level stage (e.g. an emit-event envelope) must fail, not continue
{ echo '{"seq":1,"type":"loop.round","data":{"stage":"review","round":1,"tree":"t1","blocking":["F1"]}}'
  echo '{"seq":2,"type":"loop.round","data":{"stage":"review","round":2,"tree":"t1","blocking":["F1"]}}'; } > "$L"
check envelope failed 1
# Important 2: an empty blocking set is not "did not shrink"; a test-fix loop that is progressing continues
{ R 1 t1 '[]' '["a|1","b|1","c|1","d|1"]'; R 2 t2 '[]' '["e|2","f|2"]'; R 3 t3 '[]' '["g|3"]'; } > "$L"
check verify-progressing continue 0
echo ok
