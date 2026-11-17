#!/bin/bash
# claim-guard.sh (v6): creating a t/<n>-<slug> branch in a managed repo needs a claim on origin for issue <n>.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${CG_HOOK:-$DIR/../../../hooks/scripts/claim-guard.sh}"
CLAIM="$DIR/../../../bin/claim"
[ -x "$HOOK" ] || { echo "FAIL: hooks/scripts/claim-guard.sh missing or not executable"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*"; exit 1; }
unset DEVFW_CONFIG DEVFW_CORE_DIR
P() { cygpath -m "$1" 2>/dev/null || echo "$1"; }

CORE="$TMP/core"; mkdir -p "$CORE"
echo '{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api","default":"main"}}}' > "$CORE/orchestrator.json"

g init -q --bare "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/W" 2>/dev/null
echo x > "$TMP/W/f"; g -C "$TMP/W" add f; g -C "$TMP/W" commit -qm init; g -C "$TMP/W" push -q origin main
git -C "$TMP/W" remote set-url origin https://github.com/acme/api.git
git -C "$TMP/W" config url."$(P "$TMP/origin.git")".insteadOf https://github.com/acme/api.git
"$CLAIM" 41 x --repo-dir "$TMP/W" --base main >/dev/null || fail "setup: claim 41"
# t/44-w exists on origin and carries a claim for ISSUE 41 only: a claim for 41 must not satisfy t/44-...
g -C "$TMP/W" checkout -q -b t/44-w main; g -C "$TMP/W" commit -q --allow-empty -m $'claim\n\nClaim-Issue: 41'
g -C "$TMP/W" push -q origin t/44-w; g -C "$TMP/W" checkout -q main
# V: managed, origin unreachable.  U: unmanaged.
g init -q "$TMP/V"; git -C "$TMP/V" remote add origin https://github.com/acme/api.git
git -C "$TMP/V" config url."$(P "$TMP/nowhere.git")".insteadOf https://github.com/acme/api.git
g init -q "$TMP/U"; git -C "$TMP/U" remote add origin https://github.com/other/x.git
export DEVFW_CORE_DIR="$CORE"

run() {  # run <cwd> <command>
  ERR=$(jq -cn --arg c "$2" --arg cwd "$1" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}' | bash "$HOOK" 2>&1 >/dev/null); RC=$?
  ERR="${ERR//$'\r'/}"
}
expect() { [ "$RC" = "$1" ] || fail "$2: rc=$RC want $1 (stderr: $ERR)"; }
says() { grep -q -- "$1" <<<"$ERR" || fail "$2: stderr lacks '$1': $ERR"; }
W="$TMP/W"; U="$TMP/U"

run "$W" 'git worktree add ../wt -b t/41-x origin/t/41-x'; expect 0 "claimed worktree add"
run "$W" 'git checkout -b t/41-x origin/t/41-x'; expect 0 "claimed checkout -b"
run "$W" 'git worktree add ../wt -b t/43-z origin/main'; expect 2 "unclaimed worktree add"
says 'devfw claim-guard: t/43-… has no claim on origin; the orchestrator claims before a worker starts (bin/claim)' "unclaimed text"
run "$W" 'git switch -c t/43-z'; expect 2 "unclaimed switch -c"
run "$W" 'git checkout -b t/43-z'; expect 2 "unclaimed checkout -b"
run "$W" 'git branch t/43-z'; expect 2 "unclaimed git branch"
run "$W" 'git worktree add ../wt -b t/44-w origin/t/44-w'; expect 2 "claim for 41 must not satisfy t/44-"
says 't/44-… has no claim on origin' "t/44 text"
run "$W" 'git switch -c feature/x'; expect 0 "non-ticket branch"
run "$W" 'git checkout -b tx/43-z'; expect 0 "not a t/ branch"
run "$W" 'git status'; expect 0 "no branch word"
run "$U" 'git worktree add ../wt -b t/43-z'; expect 0 "unmanaged repo"
run "$TMP/V" 'git worktree add ../wt -b t/41-x'; expect 2 "unreachable origin"
says 'cannot verify the claim' "unreachable text"
run "$TMP" "cd $W && git switch -c t/43-z"; expect 2 "cd into a managed repo"
run "$TMP" "cd $W && git switch -c t/41-x"; expect 0 "cd into a managed repo, claimed"
run "$U" "git -C $W switch -c t/43-z"; expect 2 "-C into a managed repo"

# opaque
run "$W" 'eval "git switch -c t/43-z"'; expect 2 "opaque in a managed cwd naming t/"
says 'cannot read this branch command exactly' "opaque text"
run "$W" 'git switch -c "t/4$N-z"'; expect 2 "non-literal ticket name"
run "$W" 'eval "git switch -c feature/x"'; expect 0 "opaque, literal non-ticket name"
run "$U" 'eval "git switch -c t/43-z"'; expect 0 "opaque in an unmanaged cwd"
run "$U" 'cd $X && eval "git switch -c t/43-z"'; expect 2 "non-literal cd, opaque"
run "$U" 'eval "git switch -c t/43-z" # acme/api'; expect 2 "opaque naming a managed slug"
run "$W" 'git worktree add -b t/4'"'"'1-x ../w'; expect 2 "unparseable, mentions t/"
run "$W" 'git "unterminated switch -c t/43-z'; expect 2 "parse failure mentioning t/"
run "$W" 'git "unterminated branch'; expect 0 "parse failure, no t/"

# no core dir
ERR=$(jq -cn --arg cwd "$W" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:"git switch -c t/43-z"}}' | env -u DEVFW_CORE_DIR bash "$HOOK" 2>&1 >/dev/null); RC=$?
expect 0 "DEVFW_CORE_DIR unset"
echo "claim-guard: all passed"
