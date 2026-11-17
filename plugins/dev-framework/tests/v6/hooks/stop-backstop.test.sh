#!/bin/bash
# stop-backstop.sh (Stop hook): blocks at most once when stop-check names a stop code with no matching hand-back.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/../../../hooks/scripts/stop-backstop.sh"
[ -x "$HOOK" ] || { echo "FAIL: hooks/scripts/stop-backstop.sh missing or not executable"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
unset DEVFW_CONFIG DEVFW_CORE_DIR DEVFW_BIN_DIR
export GIT_CONFIG_GLOBAL=/dev/null

REPO="$TMP/repo"; git init -q "$REPO"
GD=$(git -C "$REPO" rev-parse --absolute-git-dir | tr -d '\r'); mkdir -p "$GD/devfw"
L="$TMP/ledger.jsonl"
R() { echo "{\"stage\":\"review\",\"round\":$1,\"tree\":\"$2\",\"blocking\":$3,\"failing\":[],\"toolCalls\":10,\"tokens\":1000,\"budget\":{\"toolCalls\":100,\"tokens\":100000},\"env\":false,\"gate\":false}"; }
setrun() { jq -cn --arg l "$L" '{ledger:$l,stage:"review",issue:7}' > "$GD/devfw/run.json"; }
run() {  # run <stop_hook_active> [cwd]
  ERR=$(jq -cn --argjson a "$1" --arg cwd "${2:-$REPO}" '{hook_event_name:"Stop",stop_hook_active:$a,cwd:$cwd}' | bash "$HOOK" 2>&1 >/dev/null); RC=$?; ERR="${ERR//$'\r'/}"
}
expect() { [ "$RC" = "$1" ] || fail "$2: rc=$RC want $1 (stderr: $ERR)"; }
clean() { rm -f "$GD/devfw/handback.json"; }

setrun
{ R 1 t1 '["a","b"]'; R 2 t2 '["a"]'; } > "$L";  run false; expect 0 "progressing"
{ R 1 t1 '["a"]'; R 2 t1 '["a"]'; } > "$L"
clean; run false; expect 2 "stalled, no hand-back"
[ "$(head -1 <<<"$ERR")" = 'devfw stop-backstop: stop-check says stalled at round 2 (stalled(a): fix round left tree t1 unchanged): post "stopped 7 stalled" on the ticket and write devfw/handback.json before ending' ] || fail "message: $ERR"
echo '{"code":"stalled","round":2,"at":"x"}' > "$GD/devfw/handback.json"; run false; expect 0 "matching hand-back"
echo '{"code":"stalled","round":1,"at":"x"}' > "$GD/devfw/handback.json"; run false; expect 2 "older-round hand-back"
echo '{"code":"env","round":2,"at":"x"}' > "$GD/devfw/handback.json"; run false; expect 2 "other-code hand-back"
clean; run true; expect 0 "stalled with stop_hook_active"
rm -f "$GD/devfw/run.json"; run false; expect 0 "no run.json"
setrun; run false "$TMP"; expect 0 "cwd not in a git repo"
echo '{"stage":"review","round":2,' >> "$L"; clean
run false; expect 2 "malformed ledger"
grep -q 'stop-check failed: .*stopped 7 failed' <<<"$ERR" || fail "failure text: $ERR"
run true; expect 0 "malformed ledger, stop_hook_active"
rm -f "$L"; run false; expect 2 "missing ledger"
grep -q 'stop-check failed' <<<"$ERR" || fail "missing-ledger text: $ERR"
echo 'not json' > "$GD/devfw/run.json"; run false; expect 2 "malformed run.json"
echo '{"stage":"review"}' > "$GD/devfw/run.json"; run false; expect 2 "run.json without ledger"
echo "ok stop-backstop"
