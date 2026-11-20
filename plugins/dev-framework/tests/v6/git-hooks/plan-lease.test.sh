#!/bin/bash
# The plan-edit lease at commit and over the pushed range, and the current-branch claim check at commit.
#   pre-commit (hooks/git/rules/pre-commit.sh, gk_pre_commit):
#     A. in the plan repo (origin's raw URL names plan.repo), a commit that stages anything under <plan.path>/ needs
#        `bin/lease check --core-dir <core>` to pass: exit 4 -> "only the lease holder commits plan changes: <line>",
#        3 -> "no lease: <line>", other -> "cannot verify the lease (...)";
#     B. in a managed repo, a commit on a t/<n>-<slug> branch needs the same local claim evidence as the
#        reference-transaction rule (gk_t_evidence). This closes the `git branch -m/-c` gap: those create the branch
#        with no ref-tx line for it, so the first COMMIT on it is where it is caught.
#     gk_pre_commit_idle (the fast path) skips the rule only when neither can apply: HEAD is read as a non-t branch
#     (or detached) AND no config git reads (command scope or the cached config files) names the plan repo.
#   pre-push (hooks/git/rules/pre-push.sh): a push to the plan repo whose range (<remote>..<local>, or
#     <local> --not --remotes for a new branch) touches <plan.path>/ meets the same lease check, with the reason
#     prefix "plan change in pushed range: ". This is what catches a commit made with the pre-commit hook skipped.
# Every commit row here runs with the fixture's hooks (hk); setup runs without them.
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS DEVFW_SESSION_ID DEVFW_CONFIG DEVFW_CORE_DIR CDPATH
for v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_'); do unset "$v"; done
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_fixture.sh"
export GH_MODE=ok
# PL_UNTIL=<row> (mutation runs only): stop with the verdict right after that row reports. Unset = every row.
ok() { echo "ok $1"; [ "${1%% *}" != "${PL_UNTIL:-}" ] || fx_done; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); [ "${1%%:*}" != "${PL_UNTIL:-}" ] || fx_done; }

LOG="$TMP/state/dispatch.log"
ORIGIN="$TMP/origin.git"
NOTHOLDER=ffffffffffffffff
tok() { if [ -n "$1" ]; then printf '%s\n' "$1" > "$CORE/.orchestrator/lease"; else rm -f "$CORE/.orchestrator/lease"; fi; }
head_of() { git -C "$1" rev-parse -q --verify HEAD 2>/dev/null | tr -d '\r'; }
has() { git -C "$1" show-ref --verify -q "$2" 2>/dev/null; }
# unmoved <row> <repo> <sha before>: the blocked commit did not land
unmoved() { [ "$(head_of "$2")" = "$3" ] && ok "$1" || fail "$1: HEAD moved to $(head_of "$2") (was $3)"; }
# moved <row> <repo> <sha before>: the allowed commit landed
moved() { [ -n "$(head_of "$2")" ] && [ "$(head_of "$2")" != "$3" ] && ok "$1" || fail "$1: HEAD did not move (still $3)"; }
clean() { g -C "$1" reset -q --hard HEAD && g -C "$1" clean -fdq; }
tr_on() { rm -f "$LOG"; }
tr_lines() { tr -d '\r' < "$LOG" 2>/dev/null | grep -E "^$1	"; }
# traced <row> <want: fast|full> <repo>: one traced empty commit in <repo> (after an untraced warm one, so the chain
# cache is valid); the pre-commit run must have taken <want> (full = the rule ran: `full<TAB>pre-commit<TAB>rule`)
traced() {
  local row="$1" want="$2" repo="$3"
  hk git -C "$repo" commit -q --allow-empty -m "$row-warm" >/dev/null 2>&1 || { fail "$row: warm commit refused"; return 1; }
  tr_on
  DEVFW_GK_TRACE=1 expect "$row" 0 - hk git -C "$repo" commit -q --allow-empty -m "$row" || return 1
  case "$want" in
    fast) tr_lines fast | grep -q "	pre-commit	" && ! tr_lines full | grep -q "	pre-commit	" ;;
    full) tr_lines full | grep -qx "full	pre-commit	rule" ;;
  esac && ok "$row" || fail "$row: pre-commit was not $want: $(tr -d '\r' < "$LOG" 2>&1 | tr '\n' '|')"
}
# clone_managed <dir> [clone args...]: a clone of origin.git that names acme/api, like W
clone_managed() {
  local d="$1"; shift
  g clone -q "$@" "$ORIGIN" "$d" 2>/dev/null || fx_die "clone $d"
  git -C "$d" remote set-url origin https://github.com/acme/api.git
  fx_insteadof "$d" "$ORIGIN" https://github.com/acme/api.git
}

# --- setup (no hk): issue 41 is claimed and fetched in W; t/55-x is a local branch whose claim was merged and pruned
"$PLUGIN/bin/claim" 41 x --repo-dir "$W" --base main >/dev/null || fx_die "claim 41"
"$PLUGIN/bin/claim" 55 x --repo-dir "$W" --base main >/dev/null || fx_die "claim 55"
g -C "$W" fetch -q origin || fx_die "fetch"
g -C "$W" branch -q --no-track t/55-x origin/t/55-x && git -C "$ORIGIN" update-ref -d refs/heads/t/55-x \
  && g -C "$W" update-ref -d refs/remotes/origin/t/55-x || fx_die "t/55-x"
has "$W" refs/remotes/origin/t/41-x && ! has "$W" refs/remotes/origin/t/55-x || fx_die "setup tracking refs"
[ -f "$CORE/docs/plan/START-HERE.md" ] || fx_die "CORE has no docs/plan/"
tok "$FX_TOKEN"

# ============ A. the lease at pre-commit (CORE is the plan repo acme/core, and the clone bin/lease fetches in)
# pc_non_holder_blocks: a non-holder stages a new plan file
tok "$NOTHOLDER"
echo plan > "$CORE/docs/plan/PLAN.md"; g -C "$CORE" add docs/plan/PLAN.md
B=$(head_of "$CORE")
rm -f "$TMP/state/shadow/new.jsonl"
expect pc_non_holder_blocks block "devfw pre-commit: only the lease holder commits plan changes: lease: lease mismatch" \
  hk git -C "$CORE" commit -q -m x && unmoved pc_non_holder_blocks "$CORE" "$B"
# pc_block_logged: the shadow row names the hook and the plan repo
ROW=$(tail -1 "$TMP/state/shadow/new.jsonl" 2>/dev/null | tr -d '\r')
jq -e '.hook == "pre-commit" and .repo == "acme/core" and .session == "s1"
       and (.reason | startswith("only the lease holder commits plan changes"))' >/dev/null 2>&1 <<<"$ROW" \
  && ok pc_block_logged || fail "pc_block_logged: $ROW"
# pc_no_lease_blocks: no local lease token (lease exit 3)
tok ""
expect pc_no_lease_blocks block "devfw pre-commit: no lease: lease: no local lease token" hk git -C "$CORE" commit -q -m x \
  && unmoved pc_no_lease_blocks "$CORE" "$B"
# pc_holder_allowed: the real bin/lease check fetched and passed
tok "$FX_TOKEN"
expect pc_holder_allowed 0 - hk git -C "$CORE" commit -q -m x && moved pc_holder_allowed "$CORE" "$B"
# pc_commit_a_plan_blocks: `commit -a` stages a tracked plan file inside git's own commit (the hook's GIT_INDEX_FILE)
tok "$NOTHOLDER"
echo edit >> "$CORE/docs/plan/PLAN.md"
B=$(head_of "$CORE")
expect pc_commit_a_plan_blocks block "devfw pre-commit: only the lease holder commits plan changes" \
  hk git -C "$CORE" commit -q -a -m x && unmoved pc_commit_a_plan_blocks "$CORE" "$B"
clean "$CORE" || fx_die "clean CORE"
# pc_outside_plan_no_network: CORE's own fetch is broken, so any lease fetch would fail; a non-holder commits outside
# the plan path (the discriminating pair of pc_lease_fetch_fail_blocks)
git -C "$CORE" config remote.origin.uploadpack /nonexistent
echo r > "$CORE/README.md"; g -C "$CORE" add README.md
B=$(head_of "$CORE")
expect pc_outside_plan_no_network 0 - hk git -C "$CORE" commit -q -m readme && moved pc_outside_plan_no_network "$CORE" "$B"
# pc_lease_fetch_fail_blocks: the same broken fetch, staging a plan file (lease exit 1)
echo again >> "$CORE/docs/plan/PLAN.md"; g -C "$CORE" add docs/plan/PLAN.md
B=$(head_of "$CORE")
expect pc_lease_fetch_fail_blocks block "devfw pre-commit: cannot verify the lease (lease exit 1: " \
  hk git -C "$CORE" commit -q -m x && unmoved pc_lease_fetch_fail_blocks "$CORE" "$B"
git -C "$CORE" config --unset remote.origin.uploadpack
clean "$CORE" || fx_die "clean CORE (2)"

# pc_code_repo_ignored: W is acme/api, not the plan repo; a non-holder stages docs/plan/x.md there. On main the
# fast path decides (idle); on the claimed t/41-x the full path runs the rule (_full), which is the row that
# discriminates the scope compare.
mkdir -p "$W/docs/plan"; echo x > "$W/docs/plan/x.md"; g -C "$W" add docs/plan/x.md
B=$(head_of "$W")
expect pc_code_repo_ignored 0 - hk git -C "$W" commit -q -m plan-in-code && moved pc_code_repo_ignored "$W" "$B"
g -C "$W" checkout -q t/41-x || fx_die "checkout t/41-x"
mkdir -p "$W/docs/plan"; echo y > "$W/docs/plan/y.md"; g -C "$W" add docs/plan/y.md
B=$(head_of "$W"); tr_on
DEVFW_GK_TRACE=1 expect pc_code_repo_ignored_full 0 - hk git -C "$W" commit -q -m plan-in-code-t \
  && { tr_lines full | grep -q "^full	pre-commit	" && moved pc_code_repo_ignored_full "$W" "$B" \
         || fail "pc_code_repo_ignored_full: the rule did not run: $(tr '\n' '|' < "$LOG")"; }
g -C "$W" checkout -q main || fx_die "back to main"

# pc_command_scope_origin_plan_blocks: U (other/x) whose origin is overridden to the plan repo in the command scope
# (`git -c`): the scope is the raw URL git uses, and the fast path must see it in GIT_CONFIG_PARAMETERS
hk git -C "$U" commit -q --allow-empty -m warm-u >/dev/null 2>&1 || fx_die "warm U"
mkdir -p "$U/docs/plan"; echo u > "$U/docs/plan/u.md"; g -C "$U" add docs/plan/u.md
B=$(head_of "$U")
expect pc_command_scope_origin_plan_blocks block "devfw pre-commit: only the lease holder commits plan changes" \
  hk git -C "$U" -c remote.origin.url=https://github.com/acme/core.git commit -q -m x \
  && unmoved pc_command_scope_origin_plan_blocks "$U" "$B"
# pc_config_count_origin_plan_blocks: the same through GIT_CONFIG_COUNT / _KEY_<i> / _VALUE_<i>
hk_env
expect pc_config_count_origin_plan_blocks block "devfw pre-commit: only the lease holder commits plan changes" \
  env "${HKENV[@]}" GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_1=remote.origin.url \
  GIT_CONFIG_VALUE_1=https://github.com/acme/core.git git -C "$U" commit -q -m x \
  && unmoved pc_config_count_origin_plan_blocks "$U" "$B"
clean "$U" || fx_die "clean U"

# ============ the fast path (gk_pre_commit_idle): both idle exits, and each condition that makes it busy
traced pc_idle_code_repo_main_fast fast "$W"            # idle exit 2: non-t branch, no config names the plan repo
traced pc_idle_plan_repo_full full "$CORE"              # busy: CORE's own config names acme/core
g -C "$W" checkout -q t/41-x || fx_die "checkout t/41-x (idle)"
traced pc_idle_t_branch_full full "$W"                  # busy: the current branch is t/*
g -C "$W" checkout -q main || fx_die "back to main (idle)"
g -C "$W" checkout -q --detach || fx_die "detach"
traced pc_idle_detached_fast fast "$W"                  # a detached HEAD (a sha in the HEAD file) is not a t/ branch
g -C "$W" checkout -q main || fx_die "back to main (detached)"
# idle exit 1: an install whose scope.env has no plan repo (a hand-edited copy) skips the plan part entirely, even
# in CORE whose config names acme/core
cp -r "$HK" "$TMP/hk-noplan" && sed -i 's/^DEVFW_HK_PLAN_REPO=.*/DEVFW_HK_PLAN_REPO=/' "$TMP/hk-noplan/scope.env" \
  && grep -qx 'DEVFW_HK_PLAN_REPO=' "$TMP/hk-noplan/scope.env" || fx_die "hk-noplan"
HK="$(mp "$TMP/hk-noplan")" traced pc_idle_no_plan_repo_fast fast "$CORE"
# pc_no_plan_repo_full_path_ignored: with no plan repo, the FULL path (forced by a repo hook to chain) must not
# treat an empty origin slug as the plan repo: N has no remote at all, a non-holder stages docs/plan/n.md
N="$TMP/N"; g init -q "$N" && g -C "$N" commit -q --allow-empty -m init || fx_die "init N"
mkdir -p "$N/.git/hooks" "$N/docs/plan"; printf '#!/bin/sh\nexit 0\n' > "$N/.git/hooks/pre-commit"; chmod +x "$N/.git/hooks/pre-commit"
echo n > "$N/docs/plan/n.md"; g -C "$N" add docs/plan/n.md
B=$(head_of "$N")
HK="$(mp "$TMP/hk-noplan")" expect pc_no_plan_repo_full_path_ignored 0 - hk git -C "$N" commit -q -m n \
  && moved pc_no_plan_repo_full_path_ignored "$N" "$B"
tok "$FX_TOKEN"

# ============ B. the current t/ branch (managed repo W; the controller's -m/-c addition)
g -C "$W" branch -q feat main || fx_die "feat"
# pc_renamed_unclaimed_branch_blocks: rename the CURRENT unclaimed branch to t/77-x (ref-tx sees no line for it)
g -C "$W" checkout -q feat || fx_die "checkout feat"
expect pc_renamed_unclaimed_branch_blocks 0 - hk git -C "$W" branch -m t/77-x \
  && [ "$(git -C "$W" symbolic-ref HEAD | tr -d '\r')" = refs/heads/t/77-x ] || fail "pc_renamed_unclaimed_branch_blocks: setup: rename"
B=$(head_of "$W")
expect pc_renamed_unclaimed_branch_blocks block \
  'devfw pre-commit: no claim for issue 77 (no origin/t/77-x); run bin/claim, then git fetch origin +refs/heads/t/77-x:refs/remotes/origin/t/77-x' \
  hk git -C "$W" commit -q --allow-empty -m x && unmoved pc_renamed_unclaimed_branch_blocks "$W" "$B"
g -C "$W" checkout -q main && g -C "$W" branch -q -D t/77-x || fx_die "drop t/77-x"
# pc_copied_unclaimed_branch_blocks: branch -c runs no ref-tx hook; the checkout of it is a HEAD symref line only
expect pc_copied_unclaimed_branch_blocks 0 - hk git -C "$W" branch -c main t/78-x \
  && expect pc_copied_unclaimed_branch_blocks 0 - hk git -C "$W" checkout -q t/78-x \
  || fail "pc_copied_unclaimed_branch_blocks: setup: copy + checkout"
B=$(head_of "$W")
expect pc_copied_unclaimed_branch_blocks block "devfw pre-commit: no claim for issue 78 (no origin/t/78-x)" \
  hk git -C "$W" commit -q --allow-empty -m x && unmoved pc_copied_unclaimed_branch_blocks "$W" "$B"
g -C "$W" checkout -q main && g -C "$W" branch -q -D t/78-x || fx_die "drop t/78-x"
# pc_wrong_slug_branch_blocks: issue 41 is claimed as t/41-x
g -C "$W" checkout -q -b feat main && g -C "$W" branch -q -m t/41-y || fx_die "t/41-y"
B=$(head_of "$W")
expect pc_wrong_slug_branch_blocks block "devfw pre-commit: issue 41 is claimed as t/41-x" \
  hk git -C "$W" commit -q --allow-empty -m x && unmoved pc_wrong_slug_branch_blocks "$W" "$B"
# pc_case_variant_branch_blocks: an upper-case T/ name (HEAD names refs/heads/T/79-x). `branch -m` rewrites
# .git/config, which invalidates the chain cache and forces the full path whatever the fast path says; so the cache
# is refreshed by a commit on main first and the branch is made with plumbing that writes no config, so this row also
# carries the fast path's case fold (gk_pre_commit_idle must call T/ busy).
g -C "$W" checkout -q main || fx_die "main (T/)"
hk git -C "$W" commit -q --allow-empty -m refresh-cache >/dev/null 2>&1 || fx_die "refresh commit (T/)"
g -C "$W" update-ref refs/heads/T/79-x main && g -C "$W" symbolic-ref HEAD refs/heads/T/79-x || fx_die "T/79-x"
B=$(head_of "$W"); tr_on
DEVFW_GK_TRACE=1 expect pc_case_variant_branch_blocks block "devfw pre-commit: branch names under t/ must be lowercase (T/79-x)" \
  hk git -C "$W" commit -q --allow-empty -m x \
  && { tr_lines full | grep -qx "full	pre-commit	rule" && unmoved pc_case_variant_branch_blocks "$W" "$B" \
         || fail "pc_case_variant_branch_blocks: not full/rule: $(tr '\n' '|' < "$LOG")"; }
# pc_t_without_issue_allowed: a t/ name with no issue number is not a ticket branch
g -C "$W" branch -q -m t/notes || fx_die "t/notes"
B=$(head_of "$W")
expect pc_t_without_issue_allowed 0 - hk git -C "$W" commit -q --allow-empty -m x && moved pc_t_without_issue_allowed "$W" "$B"
g -C "$W" branch -q -m feat || fx_die "back to feat"
# pc_pruned_t_branch_blocks: t/55-x's claim was merged and its tracking ref pruned; a new commit there has no evidence
g -C "$W" checkout -q t/55-x || fx_die "checkout t/55-x"
B=$(head_of "$W")
expect pc_pruned_t_branch_blocks block "devfw pre-commit: no claim for issue 55" \
  hk git -C "$W" commit -q --allow-empty -m x && unmoved pc_pruned_t_branch_blocks "$W" "$B"
# pc_claimed_t_branch_commits
g -C "$W" checkout -q t/41-x || fx_die "checkout t/41-x (claimed)"
B=$(head_of "$W")
expect pc_claimed_t_branch_commits 0 - hk git -C "$W" commit -q --allow-empty -m x && moved pc_claimed_t_branch_commits "$W" "$B"
# session (the branch is claimed, so only the session can block)
mkdir -p "$TMP/state/latch"; : > "$TMP/state/latch/s1"
B=$(head_of "$W")
expect pc_t_branch_latched_blocks block "devfw pre-commit: session is latched; the owner must clear it" \
  hk git -C "$W" commit -q --allow-empty -m x && unmoved pc_t_branch_latched_blocks "$W" "$B"
rm -f "$TMP/state/latch/s1"
HK_SESSION= expect pc_t_branch_no_session_blocks block "devfw pre-commit: no session id; start a new session" \
  hk git -C "$W" commit -q --allow-empty -m x && unmoved pc_t_branch_no_session_blocks "$W" "$B"
g -C "$W" checkout -q main || fx_die "back to main (B)"
# pc_t_branch_unmanaged_allowed: other/x is not managed
g -C "$U" checkout -q -b t/77-x || fx_die "U t/77-x"
B=$(head_of "$U")
expect pc_t_branch_unmanaged_allowed 0 - hk git -C "$U" commit -q --allow-empty -m x && moved pc_t_branch_unmanaged_allowed "$U" "$B"
g -C "$U" checkout -q main || fx_die "U back to main"

# pc_linked_worktree_t_branch_blocks: a linked worktree of W (git exports GIT_DIR=<W>/.git/worktrees/<n> to hooks)
g -C "$W" worktree add -q "$(mp "$TMP/wtw")" feat 2>/dev/null || fx_die "worktree wtw"
g -C "$TMP/wtw" branch -q -m t/80-x || fx_die "wtw t/80-x"
B=$(head_of "$TMP/wtw")
expect pc_linked_worktree_t_branch_blocks block "devfw pre-commit: no claim for issue 80" \
  hk git -C "$TMP/wtw" commit -q --allow-empty -m x && unmoved pc_linked_worktree_t_branch_blocks "$TMP/wtw" "$B"
g -C "$TMP/wtw" branch -q -m feat || fx_die "wtw back to feat"
traced pc_linked_worktree_main_fast fast "$TMP/wtw"
# pc_separate_git_dir_main_fast: .git is a `gitdir: <path>` file (git exports GIT_DIR to the hook here too, measured
# on 2.53: separate git dir, submodule and linked worktree all get it; the gitdir-file branch is fenced by
# pc_head_ref_unit below)
SG="$TMP/SG"
g init -q --separate-git-dir "$(mp "$TMP/SG.git")" "$SG" && g -C "$SG" commit -q --allow-empty -m init || fx_die "init SG"
[ -f "$SG/.git" ] || fx_die "SG/.git is not a gitdir file"
git -C "$SG" remote add origin https://github.com/acme/api.git && fx_insteadof "$SG" "$ORIGIN" https://github.com/acme/api.git
traced pc_separate_git_dir_main_fast fast "$SG"
g -C "$SG" checkout -q -b t/77-x || fx_die "SG t/77-x"
B=$(head_of "$SG")
expect pc_separate_git_dir_t_branch_blocks block "devfw pre-commit: no claim for issue 77" \
  hk git -C "$SG" commit -q --allow-empty -m x && unmoved pc_separate_git_dir_t_branch_blocks "$SG" "$B"
# pc_head_ref_unit: _gk_head_ref directly, for the two git-dir sources a hook run cannot tell apart (git always
# exports GIT_DIR when .git is a file). (a) GIT_DIR unset, cwd SG: the `gitdir:` file is followed -> SG's t/77-x;
# (b) GIT_DIR=SG's git dir while the cwd is W (on main): GIT_DIR wins -> t/77-x, not W's main.
hr() { (cd "$1" && if [ -n "$2" ]; then export GIT_DIR="$2"; else unset GIT_DIR; fi
        bash -c ". '$PLUGIN/bin/_lib.sh'; . '$PLUGIN/bin/_scope.sh'; . '$PLUGIN/hooks/git/_git-lib.sh'; _gk_head_ref && printf '%s' \"\$GK_HEAD_REF\"") 2>/dev/null; }
A=$(hr "$SG" ""); Bv=$(hr "$W" "$(mp "$TMP/SG.git")")
[ "$A" = refs/heads/t/77-x ] && [ "$Bv" = refs/heads/t/77-x ] && [ "$(hr "$W" "")" = refs/heads/main ] \
  && ok pc_head_ref_unit || fail "pc_head_ref_unit: gitdir-file '$A', GIT_DIR '$Bv', W '$(hr "$W" "")'"
# a reftable repo: its HEAD file is the placeholder `ref: refs/heads/.invalid`, so the fast path cannot read the
# branch (busy) and the rule asks git
RT="$TMP/RT"
g init -q --ref-format=reftable "$RT" && g -C "$RT" commit -q --allow-empty -m init || fx_die "init RT"
git -C "$RT" remote add origin https://github.com/acme/api.git && fx_insteadof "$RT" "$ORIGIN" https://github.com/acme/api.git
traced pc_reftable_main_full full "$RT"
# pc_reftable_main_no_session_allowed: the branch git reports (main) is not t/, so the session is not asked for
B=$(head_of "$RT")
HK_SESSION= expect pc_reftable_main_no_session_allowed 0 - hk git -C "$RT" commit -q --allow-empty -m x \
  && moved pc_reftable_main_no_session_allowed "$RT" "$B"
g -C "$RT" checkout -q -b t/77-x || fx_die "RT t/77-x"
B=$(head_of "$RT")
expect pc_reftable_t_branch_blocks block "devfw pre-commit: no claim for issue 77" \
  hk git -C "$RT" commit -q --allow-empty -m x && unmoved pc_reftable_t_branch_blocks "$RT" "$B"

# pc_non_t_branch_no_git_call: on main in a managed repo, the current-branch check makes no git call. git and
# gk_managed are stubbed to log; the plan part's one origin lookup is the only call allowed. The control (t/41-x)
# proves the stubs are reached once the branch IS t/.
LIBS=". '$PLUGIN/bin/_lib.sh'; . '$PLUGIN/bin/_scope.sh'; . '$PLUGIN/hooks/git/_git-lib.sh'; . '$PLUGIN/hooks/git/rules/pre-commit.sh'"
STUBS="git() { echo \"git \$*\" >> '$TMP/calls'; }; gk_managed() { echo managed >> '$TMP/calls'; }"
pcs() { : > "$TMP/calls"; (cd "$W" && bash -c "$LIBS; gk_init pre-commit '$HK'; $STUBS; gk_pre_commit") >/dev/null 2>&1; }
if ! pcs; then fail "pc_non_t_branch_no_git_call: rc != 0 on main"
elif [ -n "$(grep -vx 'git config --get remote.origin.url' "$TMP/calls")" ]; then
  fail "pc_non_t_branch_no_git_call: calls on main: $(tr '\n' '|' < "$TMP/calls")"
else
  g -C "$W" checkout -q t/41-x || fx_die "checkout t/41-x (stubs)"
  pcs; grep -q -- '--get-regexp' "$TMP/calls" && ok pc_non_t_branch_no_git_call \
    || fail "pc_non_t_branch_no_git_call: control made no remote lookup: $(tr '\n' '|' < "$TMP/calls")"
  g -C "$W" checkout -q main || fx_die "back to main (stubs)"
fi

# pc_linked_worktree_lease_reads_core: the lease is read from the core clone, not from the repo being committed.
# C2 is another clone of the plan repo whose origin (acme/core, through insteadOf) is core2.git, where START-HERE's
# lease line holds ANOTHER token; its linked worktree gets GIT_DIR exported to hooks. The holder commits a plan file
# there: bin/lease must read CORE (token match), not C2 (mismatch).
g clone -q --bare "$TMP/core.git" "$TMP/core2.git" 2>/dev/null || fx_die "core2.git"
g clone -q "$TMP/core2.git" "$TMP/c2seed" 2>/dev/null || fx_die "c2seed"
sed -i "1s/$FX_TOKEN/aaaaaaaaaaaaaaaa/" "$TMP/c2seed/docs/plan/START-HERE.md" \
  && g -C "$TMP/c2seed" commit -qam other-lease && g -C "$TMP/c2seed" push -q origin main || fx_die "core2 lease"
C2="$TMP/C2"
g clone -q "$TMP/core2.git" "$C2" 2>/dev/null || fx_die "clone C2"
git -C "$C2" remote set-url origin https://github.com/acme/core.git
fx_insteadof "$C2" "$TMP/core2.git" https://github.com/acme/core.git
g -C "$C2" worktree add -q -b p/c2 "$(mp "$TMP/c2w")" 2>/dev/null || fx_die "worktree c2w"
mkdir -p "$TMP/c2w/docs/plan"; echo c > "$TMP/c2w/docs/plan/c2.md"; g -C "$TMP/c2w" add docs/plan/c2.md
tok "$FX_TOKEN"
B=$(head_of "$TMP/c2w")
expect pc_linked_worktree_lease_reads_core 0 - hk git -C "$TMP/c2w" commit -q -m c2 \
  && moved pc_linked_worktree_lease_reads_core "$TMP/c2w" "$B"

# ============ pre-push: the lease over the pushed range (CORE pushes to acme/core)
clean "$CORE" || fx_die "clean CORE (pp)"
# pp_plan_range_no_verify_blocks: a non-holder commits a plan change with pre-commit skipped, then pushes it
tok "$NOTHOLDER"
g -C "$CORE" checkout -q -b p1 origin/main || fx_die "p1"
echo p1 > "$CORE/docs/plan/P1.md"; g -C "$CORE" add docs/plan/P1.md
hk git -C "$CORE" commit -q --no-verify -m p1 || fail "pp_plan_range_no_verify_blocks: setup: the skipped commit was refused"
expect pp_plan_range_no_verify_blocks block \
  "devfw pre-push: plan change in pushed range: only the lease holder commits plan changes: lease: lease mismatch" \
  hk git -C "$CORE" push origin HEAD:refs/heads/p/1-x && ok pp_plan_range_no_verify_blocks
# pp_plan_range_new_branch: (a) a brand-new branch whose first commit touches the plan blocks; (b) one whose commits
# do not touch it is pushed (the full history holds START-HERE.md, so only `--not --remotes` makes (b) pass)
g -C "$CORE" checkout -q -b p2 origin/main && echo p2 > "$CORE/docs/plan/P2.md" && g -C "$CORE" add docs/plan/P2.md \
  && g -C "$CORE" commit -q -m p2 || fx_die "p2"
if expect pp_plan_range_new_branch block "devfw pre-push: plan change in pushed range: only the lease holder" \
   hk git -C "$CORE" push origin HEAD:refs/heads/p/2-x; then
  g -C "$CORE" checkout -q -b p3 origin/main && echo p3 > "$CORE/p3.txt" && g -C "$CORE" add p3.txt \
    && g -C "$CORE" commit -q -m p3 || fx_die "p3"
  P3=$(head_of "$CORE")
  expect pp_plan_range_new_branch 0 - hk git -C "$CORE" push -q origin HEAD:refs/heads/p/3-x \
    && { [ "$(git -C "$TMP/core.git" rev-parse refs/heads/p/3-x | tr -d '\r')" = "$P3" ] && ok pp_plan_range_new_branch \
           || fail "pp_plan_range_new_branch: p/3-x did not land"; }
fi
# pp_plan_range_existing_branch_blocks: p/3-x exists on origin; a plan commit on top (range <remote>..<local>)
echo p3b > "$CORE/docs/plan/P3.md"; g -C "$CORE" add docs/plan/P3.md && g -C "$CORE" commit -q -m p3b || fx_die "p3b"
expect pp_plan_range_existing_branch_blocks block "devfw pre-push: plan change in pushed range: only the lease holder" \
  hk git -C "$CORE" push origin HEAD:refs/heads/p/3-x && ok pp_plan_range_existing_branch_blocks
# pp_plan_range_only_new_commits: the holder pushed a plan commit to p/4-x by URL (no tracking ref is written);
# a non-holder then pushes one non-plan commit on top. The range is <remote sha>..<local>, so the holder's plan
# commit is not in it (`<local> --not --remotes` would include it: nothing under refs/remotes holds it).
tok "$FX_TOKEN"
g -C "$CORE" checkout -q -b p4 origin/main && echo p4 > "$CORE/docs/plan/P4.md" && g -C "$CORE" add docs/plan/P4.md \
  && g -C "$CORE" commit -q -m p4 || fx_die "p4"
hk git -C "$CORE" push -q https://github.com/acme/core.git HEAD:refs/heads/p/4-x || fx_die "p4 holder push"
! has "$CORE" refs/remotes/origin/p/4-x || fx_die "p4: a tracking ref was written (the row would not discriminate)"
tok "$NOTHOLDER"
echo p4b > "$CORE/p4.txt"; g -C "$CORE" add p4.txt && g -C "$CORE" commit -q -m p4b || fx_die "p4b"
expect pp_plan_range_only_new_commits 0 - hk git -C "$CORE" push -q origin HEAD:refs/heads/p/4-x \
  && ok pp_plan_range_only_new_commits
# pp_plan_range_code_repo_ignored: W (acme/api) pushes a new branch whose commit touches docs/plan/
g -C "$W" checkout -q -b p9 origin/main && mkdir -p "$W/docs/plan" && echo w > "$W/docs/plan/w.md" \
  && g -C "$W" add docs/plan/w.md && g -C "$W" commit -q -m w || fx_die "W p9"
expect pp_plan_range_code_repo_ignored 0 - hk git -C "$W" push -q origin HEAD:refs/heads/p/9-x && ok pp_plan_range_code_repo_ignored
g -C "$W" checkout -q main || fx_die "W back to main (pp)"
# pp_plan_range_delete_skipped: with hooks.pushGuard.allowForce a deletion passes rule 3; it pushes no commits, so
# no range is read (a non-holder deletes p/4-x, whose history touches the plan)
jq '. + {hooks:{pushGuard:{allowForce:true}}}' "$CORE/orchestrator.json" | tr -d '\r' > "$TMP/cfg-force.json"
HK2=$("$GITHOOKS" install --core-dir "$CORE" --config "$(mp "$TMP/cfg-force.json")" --state-dir "$TMP/state" | jq -r .dir | tr -d '\r')
grep -qx 'DEVFW_HK_ALLOW_FORCE=true' "$HK2/scope.env" 2>/dev/null || fx_die "allowForce install"
HK="$HK2" expect pp_plan_range_delete_skipped 0 - hk git -C "$CORE" push -q origin :refs/heads/p/4-x \
  && { git -C "$TMP/core.git" show-ref --verify -q refs/heads/p/4-x && fail "pp_plan_range_delete_skipped: p/4-x still there" \
         || ok pp_plan_range_delete_skipped; }
tok "$FX_TOKEN"

# ============ global config (last: it is seen by every repo). N has no remote of its own; a global
# remote.origin.url names the plan repo. After a warm commit the chain cache is valid, and the fast path must scan
# the cached ~/.gitconfig, not only the repo's own config. The file is written with CRLF line ends and the value is
# split by a backslash-newline continuation (both legal; git joins them), so the scan must too.
printf '[remote "origin"]\r\n\turl = https://github.com/acme/co\\\r\nre.git\r\n' > "$HOME/.gitconfig"
[ "$(git -C "$N" config --get remote.origin.url | tr -d '\r')" = https://github.com/acme/core.git ] \
  || fx_die "global: git does not read the continued URL as acme/core"
grep -q 'acme/core' "$HOME/.gitconfig" && fx_die "global: the file holds acme/core unsplit (the row would not discriminate)"
hk git -C "$N" commit -q --allow-empty -m warm-global >/dev/null 2>&1 || fx_die "warm N (global)"
rm -f "$N/.git/hooks/pre-commit"
hk git -C "$N" commit -q --allow-empty -m warm-global2 >/dev/null 2>&1 || fx_die "warm N (global, no hook)"
tok "$NOTHOLDER"
echo g > "$N/docs/plan/g.md"; g -C "$N" add docs/plan/g.md
B=$(head_of "$N"); tr_on
DEVFW_GK_TRACE=1 expect pc_global_origin_plan_blocks block "devfw pre-commit: only the lease holder commits plan changes" \
  hk git -C "$N" commit -q -m g \
  && { tr_lines full | grep -qx "full	pre-commit	rule" && unmoved pc_global_origin_plan_blocks "$N" "$B" \
         || fail "pc_global_origin_plan_blocks: not full/rule: $(tr '\n' '|' < "$LOG")"; }
rm -f "$HOME/.gitconfig"
tok "$FX_TOKEN"

fx_done
