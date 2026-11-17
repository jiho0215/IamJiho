#!/bin/bash
# push-guard.sh (v6): force/delete, default-branch, unclaimed t/<n>- and needs-ack pushes are blocked.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${PG_HOOK:-$DIR/../../../hooks/scripts/push-guard.sh}"
CLAIM="$DIR/../../../bin/claim"
[ -x "$HOOK" ] || { echo "FAIL: hooks/scripts/push-guard.sh missing or not executable"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*"; exit 1; }
unset DEVFW_CONFIG DEVFW_CORE_DIR

CORE="$TMP/core"; mkdir -p "$CORE" "$TMP/fakebin"
CFG='{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api","default":"main"}}}'
echo "$CFG" > "$CORE/orchestrator.json"

# origin (bare) behind the insteadOf trick; W is the managed work clone, U an unmanaged one.
g init -q --bare "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/W" 2>/dev/null
echo x > "$TMP/W/f"; g -C "$TMP/W" add f; g -C "$TMP/W" commit -qm init; g -C "$TMP/W" push -q origin main
git -C "$TMP/W" remote set-url origin https://github.com/acme/api.git
git -C "$TMP/W" config url."$(cygpath -m "$TMP/origin.git" 2>/dev/null || echo "$TMP/origin.git")".insteadOf https://github.com/acme/api.git
"$CLAIM" 41 x --repo-dir "$TMP/W" --base main >/dev/null || fail "setup: claim 41"
g init -q "$TMP/U"; git -C "$TMP/U" remote add origin https://github.com/other/x.git

# fake gh: GH_MODE = ok | ack | fail | slow
cat > "$TMP/fakebin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "${GH_LOG:-/dev/null}"
case "${GH_MODE:-ok}" in
  fail) exit 1 ;;
  slow) sleep 10 ;;
  ack) [ "$*" = "api repos/acme/core/issues/41" ] && { echo '{"labels":[{"name":"needs-ack"}]}'; exit 0; }; exit 1 ;;
  *) [ "$*" = "api repos/acme/core/issues/41" ] && { echo '{"labels":[{"name":"p1"}]}'; exit 0; }; exit 1 ;;
esac
STUB
chmod +x "$TMP/fakebin/gh"
export PATH="$TMP/fakebin:$PATH" DEVFW_CORE_DIR="$CORE" GH_LOG="$TMP/gh.log"

run() {  # run <cwd> <command>
  ERR=$(jq -cn --arg c "$2" --arg cwd "$1" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}' | bash "$HOOK" 2>&1 >/dev/null); RC=$?
  ERR="${ERR//$'\r'/}"
}
expect() { [ "$RC" = "$1" ] || fail "$2: rc=$RC want $1 (stderr: $ERR)"; }
says() { grep -q -- "$1" <<<"$ERR" || fail "$2: stderr lacks '$1': $ERR"; }
W="$TMP/W"

run "$W" 'git push origin t/41-x'; expect 0 "claimed, no needs-ack"
run "$W" 'git push -u origin t/41-x:t/41-x'; expect 0 "claimed src:dst"
run "$W" 'git push origin t/41-x:refs/heads/t/41-x'; expect 0 "claimed refs/heads dst"
GH_MODE=ack run "$W" 'git push origin t/41-x'; expect 2 "needs-ack"
says 'devfw push-guard: issue 41 needs-ack: acknowledge the plan change (ack 41 <plan-sha>: ' "needs-ack text"
run "$W" 'git push origin t/42-y'; expect 2 "unclaimed"
says 'no claim for issue 42; run bin/claim first' "unclaimed text"
run "$W" 'git push origin main'; expect 2 "push to default"
says 'merge to main goes through the merge gate, not a push' "default text"
run "$W" 'git push origin HEAD:main'; expect 2 "HEAD:main"
run "$W" 'git push origin t/41-x:main'; expect 2 "src:main"
run "$W" 'git push origin t/41-x --force-with-lease'; expect 2 "force-with-lease"
says 'force-push and remote branch deletion are off (hooks.pushGuard.allowForce)' "force text"
run "$W" 'git push --force origin t/41-x'; expect 2 "--force"
run "$W" 'git push origin +t/41-x'; expect 2 "+refspec"
run "$W" 'git push origin :t/41-x'; expect 2 "delete via :refspec"
run "$W" 'git push origin --delete t/41-x'; expect 2 "--delete"
GH_MODE=fail run "$W" 'git push origin t/41-x'; expect 2 "gh exits 1"
says 'cannot read issue 41' "gh failure text"
DEVFW_HOOK_NET_TIMEOUT=1 GH_MODE=slow run "$W" 'git push origin t/41-x'; expect 2 "gh timeout"
says 'cannot read issue 41' "gh timeout text"
run "$W" 'git push origin feature/free'; expect 0 "ordinary branch"
run "$W" 'git push --tags'; expect 0 "tags are not a branch"
run "$W" 'git push origin refs/tags/v1'; expect 0 "tag ref"
run "$W" 'git push --all'; expect 2 "opaque push in a managed cwd"
says 'cannot read this push command exactly' "opaque text"
run "$W" 'eval "git push origin main"'; expect 2 "eval push in a managed cwd"
run "$W" 'git status'; expect 0 "no push word"
run "$W" 'echo push'; expect 0 "not a git push"

# no refspec: the current branch is the destination
g -C "$W" checkout -q -b t/41-x origin/main 2>/dev/null || g -C "$W" checkout -q t/41-x 2>/dev/null
g -C "$W" fetch -q origin 't/41-x:refs/remotes/origin/t/41-x' 2>/dev/null
run "$W" 'git push'; expect 0 "bare push from claimed branch"
g -C "$W" checkout -q -b t/42-y; run "$W" 'git push'; expect 2 "bare push from unclaimed branch"
run "$W" 'git push origin HEAD'; expect 2 "HEAD from unclaimed branch"
g -C "$W" checkout -q main; run "$W" 'git push'; expect 2 "bare push from main"
g -C "$W" checkout -q --detach; run "$W" 'git push'; expect 2 "detached HEAD"
says 'cannot tell what this push updates' "detached text"
g -C "$W" checkout -q main

# where the push runs
run "$TMP/U" 'git push --force origin main'; expect 0 "unmanaged repo, force to main"
run "$TMP/U" "git -C '$W' push origin main"; expect 2 "-C into a managed repo from an unmanaged cwd"
run "$TMP/U" "cd '$W' && git push origin main"; expect 2 "cd into a managed repo"
run "$TMP/U" 'git push --all'; expect 0 "opaque push in an unmanaged cwd"
run "$W" "git -C '$TMP/U' push --force origin main"; expect 0 "-C into an unmanaged repo from a managed cwd"
git -C "$TMP/U" remote add up https://github.com/acme/api.git
run "$TMP/U" 'git push up main'; expect 2 "another remote that is managed"

# allowForce
echo '{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api","default":"main"}},"hooks":{"pushGuard":{"allowForce":true}}}' > "$CORE/orchestrator.json"
run "$W" 'git push --force-with-lease origin t/41-x'; expect 0 "allowForce lets a force push through"
run "$W" 'git push --force origin main'; expect 2 "allowForce does not open the default branch"
echo "$CFG" > "$CORE/orchestrator.json"

# a broken parser
mkdir -p "$TMP/badnode"; printf '#!/bin/bash\nexit 1\n' > "$TMP/badnode/node"; chmod +x "$TMP/badnode/node"
OLDP="$PATH"; PATH="$TMP/badnode:$PATH"
run "$W" 'git push origin t/41-x'; expect 2 "parser failure on a push blocks"
run "$W" 'echo hi'; expect 0 "parser failure on an unrelated command"
PATH="$OLDP"

unset DEVFW_CORE_DIR; run "$W" 'git push --force origin main'; expect 0 "DEVFW_CORE_DIR unset"
echo "PASS: push-guard"
