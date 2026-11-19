#!/bin/bash
# _v6-hook.sh: the shared library every v6 guard hook sources.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../../../hooks/scripts/_v6-hook.sh"
CLAIM="$DIR/../../../bin/claim"
[ -f "$LIB" ] || { echo "FAIL: hooks/scripts/_v6-hook.sh missing"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*"; exit 1; }
# run <stdin> <snippet>: source the library in a fresh bash, feed stdin, print "rc|stdout|stderr-line-1"
run() {
  local out err rc
  out=$(printf '%s' "$1" | bash -c ". '$LIB'; $2" 2>"$TMP/err"); rc=$?
  err=$(head -1 "$TMP/err" | tr -d '\r')
  printf '%s|%s|%s' "$rc" "$out" "$err"
}

# ---- hook_init / hook_field
JSON='{"tool_name":"Bash","cwd":"C:/w","agent_id":"ag1","tool_input":{"command":"git push","run_in_background":false}}'
R=$(run "$JSON" 'hook_init t; echo "$HOOK_NAME,$HOOK_TOOL,$HOOK_CWD,$HOOK_AGENT_ID,$(hook_field .tool_input.command),$(hook_field .tool_input.run_in_background),[$(hook_field .nope)]"')
[ "$R" = "0|t,Bash,C:/w,ag1,git push,false,[]|" ] || fail "hook_init fields: $R"
R=$(run '' 'hook_init t; echo "[$HOOK_TOOL][$HOOK_CWD][$(hook_field .tool_name)]"')
[ "$R" = "0|[][][]|" ] || fail "empty stdin: $R"
R=$(run 'not json {' 'hook_init t; echo "[$HOOK_TOOL][$(hook_field .cwd)]"')
[ "$R" = "0|[][]|" ] || fail "non-JSON stdin: $R"
R=$(DEVFW_CORE_DIR= run '{}' 'hook_init t; echo "[$HOOK_CORE]"')
[ "$R" = "0|[]|" ] || fail "HOOK_CORE should be empty when DEVFW_CORE_DIR is unset: $R"
mkdir -p "$TMP/core"
R=$(DEVFW_CORE_DIR="$TMP/core/" run '{}' 'hook_init t; echo "$HOOK_CORE"')
WANT=$TMP/core; command -v cygpath >/dev/null 2>&1 && WANT=$(cygpath -m "$TMP/core")
[ "$R" = "0|$WANT|" ] || fail "HOOK_CORE normalized: got $R want 0|$WANT|"

# ---- hook_block
R=$(run '{}' 'hook_init t; hook_block why "line two"; echo unreachable')
[ "$R" = "2||devfw t: why" ] || fail "hook_block: $R"
[ "$(sed -n 2p "$TMP/err" | tr -d '\r')" = "line two" ] || fail "hook_block extra line: $(cat "$TMP/err")"

# ---- hook_fail_closed: a failing command blocks (2), and so does any other non-zero exit
R=$(run '{}' 'hook_init t; hook_fail_closed; false; echo unreachable')
[[ "$R" == "2||devfw t: internal error at line "* ]] || fail "fail_closed ERR: $R"
R=$(run '{}' 'hook_init t; hook_fail_closed; set -u; echo "$UNSET_VAR_X"')
[[ "$R" == "2||"* ]] || fail "fail_closed unbound variable must exit 2: $R"
grep -q '^devfw t: internal error' "$TMP/err" || fail "fail_closed unbound variable message: $(cat "$TMP/err")"
R=$(run '{}' 'hook_init t; hook_fail_closed; exit 1')
[ "$R" = "2||devfw t: internal error (exit 1)" ] || fail "fail_closed must turn exit 1 into 2: $R"
R=$(run '{}' 'hook_init t; hook_fail_closed; if false; then :; fi; x=$(false) || true; echo ok')
[ "$R" = "0|ok|" ] || fail "fail_closed must not fire on handled failures: $R"
R=$(run '{}' 'hook_init t; hook_fail_closed; exit 0')
[ "$R" = "0||" ] || fail "fail_closed clean exit: $R"

# ---- hook_under
under() { bash -c ". '$LIB'; hook_under \"\$1\" \"\$2\"" _ "$1" "$2"; echo $?; }
[ "$(under 'C:/X/docs/other/../plan/a.md' 'C:/X/docs/plan')" = 0 ] || fail "hook_under .. row"
[ "$(under 'C:/X/docs/plan/a.md' 'C:/X/docs/plan/')" = 0 ] || fail "hook_under trailing / on dir"
[ "$(under 'C:/X/docs/plan' 'C:/X/docs/plan')" = 0 ] || fail "hook_under dir itself"
[ "$(under 'C:/X/docs/./plan/a.md' 'C:/X/docs/plan')" = 0 ] || fail "hook_under . row"
[ "$(under 'C:/X/docs/planner/a.md' 'C:/X/docs/plan')" = 1 ] || fail "hook_under docs/planner shares the prefix but is not inside"
[ "$(under 'C:/X/docs/plan/../planner/a.md' 'C:/X/docs/plan')" = 1 ] || fail "hook_under .. escapes the dir"
[ "$(under 'C:/X/docs' 'C:/X/docs/plan')" = 1 ] || fail "hook_under parent is not inside"
if command -v cygpath >/dev/null 2>&1; then
  [ "$(under 'C:\X\docs\plan\a.md' 'C:/X/docs/plan')" = 0 ] || fail "hook_under backslash row"
  [ "$(under 'c:/x/docs/plan/a.md' 'C:/X/docs/plan')" = 0 ] || fail "hook_under case row"
  [ "$(under '/c/X/docs/plan/a.md' 'C:/X/docs/plan')" = 0 ] || fail "hook_under /c/ row"
  [ "$(under 'C:\X\docs\planner\a.md' 'C:/X/docs/plan')" = 1 ] || fail "hook_under backslash planner row"
else
  echo "skip: no cygpath"
fi

# ---- config: hook_cfg / hook_managed_repos
cat > "$TMP/core/orchestrator.json" <<'EOF'
{ "plan": { "repo": "acme/core", "path": "docs/plan" },
  "repos": { "api": { "github": "acme/api", "default": "main", "ci": "required" },
             "web": { "github": "acme/web", "default": "main", "ci": "required" } } }
EOF
R=$(DEVFW_CORE_DIR="$TMP/core" run '{}' 'hook_init t; hook_managed_repos | tr "\n" ,; hook_cfg .plan.path; hook_cfg .plan.nope dflt')
[ "$R" = "0|acme/core,acme/api,acme/web,docs/plan
dflt|" ] || fail "hook_cfg/hook_managed_repos: $R"
printf '{"plan":{"repo":"acme/other"}}' > "$TMP/alt.json"
R=$(DEVFW_CORE_DIR="$TMP/core" DEVFW_CONFIG="$TMP/alt.json" run '{}' 'hook_init t; hook_managed_repos')
[ "$R" = "0|acme/other|" ] || fail "DEVFW_CONFIG wins: $R"
printf '{ broken' > "$TMP/bad.json"
R=$(DEVFW_CONFIG="$TMP/bad.json" run '{}' 'hook_init t; hook_cfg .plan.repo; echo "rc=$?"')
[ "$R" = "0|rc=1|" ] || fail "unreadable config must return 1: $R"

# ---- hook_repo_of: raw origin URL -> managed owner/name
g init -q "$TMP/r"
repo_of() { git -C "$TMP/r" config remote.origin.url "$1"; DEVFW_CORE_DIR="$TMP/core" run '{}' "hook_init t; hook_repo_of '$TMP/r'"; }
for u in https://github.com/acme/api.git https://github.com/acme/api git@github.com:acme/api.git ssh://git@github.com/acme/api.git https://github.com/Acme/API.git; do
  [ "$(repo_of "$u")" = "0|acme/api|" ] || fail "hook_repo_of $u: $(repo_of "$u")"
done
[ "$(repo_of https://github.com/other/x.git)" = "0||" ] || fail "hook_repo_of unmanaged"
[ "$(repo_of https://github.com/acme/api-x.git)" = "0||" ] || fail "hook_repo_of near-name"
# raw URL, never the insteadOf rewrite
git -C "$TMP/r" config url."https://github.com/acme/api.git".insteadOf "https://example.invalid/z.git"
[ "$(repo_of https://example.invalid/z.git)" = "0||" ] || fail "hook_repo_of must read the raw URL"
git -C "$TMP/r" remote add up git@github.com:acme/web.git
R=$(DEVFW_CORE_DIR="$TMP/core" run '{}' "hook_init t; hook_repo_for_remote '$TMP/r' up; hook_repo_for_remote '$TMP/r' https://github.com/acme/core")
[ "$R" = "0|acme/web
acme/core|" ] || fail "hook_repo_for_remote: $R"

# ---- hook_claim_ok
g init -q --bare "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/a" 2>/dev/null
echo x > "$TMP/a/f"; g -C "$TMP/a" add f; g -C "$TMP/a" commit -qm init; g -C "$TMP/a" push -q origin main
g clone -q "$TMP/origin.git" "$TMP/b" 2>/dev/null
"$CLAIM" 41 x --repo-dir "$TMP/a" --base main >/dev/null || fail "setup: claim 41"
claim_ok() { bash -c ". '$LIB'; hook_claim_ok \"\$1\" \"\$2\"" _ "$1" "$2"; echo $?; }
[ "$(claim_ok "$TMP/b" t/41-x)" = 0 ] || fail "hook_claim_ok: a claimed branch"
[ -z "$(git -C "$TMP/b" for-each-ref refs/remotes/origin/t)" ] || fail "hook_claim_ok must not update remote-tracking refs"
[ ! -e "$TMP/b/.git/FETCH_HEAD" ] || fail "hook_claim_ok wrote FETCH_HEAD"
[ -z "$(git -C "$TMP/b" for-each-ref refs/devfw/claim-check/)" ] || fail "M1: hook_claim_ok leaves its per-run refs behind: $(git -C "$TMP/b" for-each-ref refs/devfw/claim-check/)"
# M1: two guards check the same claim at once (Claude Code runs matching hooks in parallel): no ref-lock race
for i in 1 2 3 4; do claim_ok "$TMP/b" t/41-x > "$TMP/par$i" & done; wait
for i in 1 2 3 4; do [ "$(cat "$TMP/par$i")" = 0 ] || fail "M1: parallel claim check $i returned $(cat "$TMP/par$i")"; done
# plain push, no trailer
g -C "$TMP/b" commit -q --allow-empty -m 'plain'; g -C "$TMP/b" push -q origin HEAD:refs/heads/t/42-x
[ "$(claim_ok "$TMP/b" t/42-x)" = 3 ] || fail "hook_claim_ok: plain push must be 3"
# a claim commit for ANOTHER issue does not count
SHA41=$(git -C "$TMP/a" ls-remote origin refs/heads/t/41-x | cut -f1)
g -C "$TMP/a" push -q origin "$SHA41:refs/heads/t/43-y"
[ "$(claim_ok "$TMP/b" t/43-y)" = 3 ] || fail "hook_claim_ok: Claim-Issue 41 must not satisfy t/43-y"
[ "$(claim_ok "$TMP/b" t/44-missing)" = 3 ] || fail "hook_claim_ok: missing branch must be 3"
[ "$(claim_ok "$TMP/b" feature/x)" = 3 ] || fail "hook_claim_ok: no issue number must be 3"
g clone -q "$TMP/origin.git" "$TMP/c" 2>/dev/null
git -C "$TMP/c" remote set-url origin "$TMP/does-not-exist.git"
[ "$(claim_ok "$TMP/c" t/41-x)" = 1 ] || fail "hook_claim_ok: missing origin must be 1"
# lib_claim_budget_exits_hook: hook_claim_ok's network goes through bin/_scope.sh's scope_net, which must run hook_net
# in the hook's OWN shell: a run budget spent before the claim fetch exits the whole hook with the budget message,
# not a subshell's rc 2 turned into the caller's generic "cannot verify" block.
R=$(DEVFW_HOOK_BUDGET= run '{}' "hook_init x 1; rc=0; hook_claim_ok '$TMP/b' t/41-x || rc=\$?; [ \"\$rc\" -ne 1 ] || hook_block 'cannot verify the claim'; echo \"after rc=\$rc\"")
[ "$R" = "2||devfw x: time budget ran out (1s per run) before a network call; not allowing this (retry when the network is faster)" ] \
  || fail "lib_claim_budget_exits_hook: $R"
# ...and nothing after it: a subshell block would print its line first and let the caller's generic block follow
[ "$(wc -l < "$TMP/err")" -eq 1 ] || fail "lib_claim_budget_exits_hook: the hook went on after the budget block: $(cat "$TMP/err")"

# ---- hook_net: one deadline per run (ruling R19)
R=$(DEVFW_HOOK_BUDGET=0 run '{}' 'hook_init t 25; hook_net o null 5 echo hi; echo after')
[ "$R" = "2||devfw t: time budget ran out (0s per run) before a network call; not allowing this (retry when the network is faster)" ] || fail "hook_net, no budget left: $R"
R=$(DEVFW_HOOK_BUDGET=0 run '{}' 'HOOK_BUDGET_SOFT=1; hook_init t 25; hook_net o null 5 echo hi; echo "rc=$? [$o]"')
[ "$R" = "0|rc=124 []|" ] || fail "hook_net soft, no budget left: $R"
R=$(run '{}' 'hook_init t 25; hook_net o merge 5 sh -c "echo a; echo b >&2; exit 3"; echo "rc=$? [$o]"')
[ "$R" = "0|rc=3 [a"$'\n'"b]|" ] || fail "hook_net merge + exit code: $R"
R=$(run '{}' 'hook_init t 25; hook_net o null 1 sleep 3; echo "rc=$?"')
[ "$R" = "0|rc=124|" ] || fail "hook_net per-call bound: $R"
R=$(DEVFW_HOOK_BUDGET=3 run '{}' 'hook_init t 25; hook_net o null 20 sleep 5; echo "rc=$? $SECONDS"')
# rc=124 alone shows the 5 s sleep was cut (the per-call bound is 20); <= 4 s leaves room for a loaded machine
# (SECONDS counts whole seconds from shell start; one full-suite run measured 4)
[[ "$R" =~ ^0\|rc=124\ [0-4]\|$ ]] || fail "hook_net capped by the time left, not the per-call bound: $R"
R=$(DEVFW_HOOK_BUDGET=x run '{}' 'hook_init t 7; echo "$HOOK_BUDGET"')
[ "$R" = "0|7|" ] || fail "a non-numeric DEVFW_HOOK_BUDGET is ignored: $R"
# M6: a grandchild that outlives the command and holds stdout must not keep hook_net past the command's end
S=$SECONDS
R=$(run '{}' 'hook_init t 25; hook_net o null 5 bash -c "sleep 6 & echo hi"; echo "rc=$? [$o]"')
[ "$R" = "0|rc=0 [hi]|" ] || fail "M6: hook_net output with a lingering grandchild: $R"
[ $((SECONDS - S)) -le 3 ] || fail "M6: hook_net waited $((SECONDS - S))s for a grandchild holding stdout"

# ---- R24: jq missing never blocks before scope
. "$DIR/nojq-path.sh"; NOJQ_PATH=$(nojq_path "$TMP/nojq") || fail "setup: a PATH without jq"
R=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | PATH="$NOJQ_PATH" DEVFW_CORE_DIR="$TMP/core" bash -c ". '$LIB'; hook_init t; hook_need_jq 'push'; echo reached" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$R" ] || fail "R24: no token, no jq must exit 0 quietly: rc=$RC [$R]"
R=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git push"}}' | PATH="$NOJQ_PATH" DEVFW_CORE_DIR="$TMP/core" bash -c ". '$LIB'; hook_init t; hook_need_jq 'push'; echo reached" 2>&1); RC=$?
[ "$RC" = 2 ] && [[ "$R" == "devfw t: jq not found"* ]] || fail "R24: token present, no jq must block: rc=$RC [$R]"
R=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"GIT PUSH origin main"}}' | PATH="$NOJQ_PATH" DEVFW_CORE_DIR="$TMP/core" bash -c ". '$LIB'; hook_init t; hook_need_jq 'push'; echo reached" 2>&1); RC=$?
[ "$RC" = 2 ] && [[ "$R" == "devfw t: jq not found"* ]] || fail "R24+R27: token in another case, no jq must block: rc=$RC [$R]"
R=$(run '{"tool_name":"Bash","tool_input":{"command":"git push"}}' 'hook_init t; hook_need_jq push; echo reached')
[ "$R" = "0|reached|" ] || fail "R24: with jq, hook_need_jq returns: $R"
R=$(run '{"cwd":"C:\\w \"q\"","x":"y"}' 'hook_init t; hook_raw_str cwd')
[ "$R" = '0|C:\w "q"|' ] || fail "hook_raw_str unescapes: $R"
echo ok
