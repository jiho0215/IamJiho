#!/bin/bash
# hooks/git/rules/reference-transaction.sh (gk_ref_tx): creating a local t/<n>-<slug> branch in a managed repo needs
# local evidence of the claim: a managed remote's refs/remotes/<r>/t/<n>-<slug>, already there or created by the
# same transaction. Read from git's own prepared ref lines (<old> <new> <ref>), so every way of creating a branch
# (checkout -b, switch -c, branch, worktree add -b, update-ref, fetch into a branch, an alias, a commit on an orphan)
# meets the same rule. Deletions (old and new zeros on git 2.53) and updates of an existing branch are never blocked.
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS DEVFW_SESSION_ID DEVFW_CONFIG DEVFW_CORE_DIR CDPATH
for v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_'); do unset "$v"; done
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_fixture.sh"
export GH_MODE=ok
# RT_UNTIL=<row> (mutation runs only): stop with the verdict right after that row reports. Unset = every row.
ok() { echo "ok $1"; [ "${1%% *}" != "${RT_UNTIL:-}" ] || fx_done; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); [ "${1%%:*}" != "${RT_UNTIL:-}" ] || fx_done; }

ORIGIN="$TMP/origin.git"
has() { git -C "$1" show-ref --verify -q "$2" 2>/dev/null; }          # has <repo> <full ref>
# absent <row> [<repo>]: the row's block left no refs/heads/t/77-x behind (the creation really was refused)
absent() { if has "${2:-$W}" refs/heads/t/77-x; then fail "$1: refs/heads/t/77-x exists after the block"; else ok "$1"; fi; }
# present <row> <repo> <full ref>...: the row's creation landed
present() {
  local row="$1" repo="$2" r; shift 2
  for r in "$@"; do has "$repo" "$r" || { fail "$row: $r missing"; return 1; }; done
  ok "$row"
}
# clone_managed <dir> [clone args...]: a clone of origin.git that names acme/api, like W
clone_managed() {
  local d="$1"; shift
  g clone -q "$@" "$ORIGIN" "$d" 2>/dev/null || fx_die "clone $d"
  git -C "$d" remote set-url origin https://github.com/acme/api.git
  fx_insteadof "$d" "$ORIGIN" https://github.com/acme/api.git
}
NOCLAIM77='no claim for issue 77 (no origin/t/77-x); run bin/claim, then git fetch origin +refs/heads/t/77-x:refs/remotes/origin/t/77-x'

# --- setup (no hk): issues 41 and 55 are claimed and fetched; W has main checked out.
# t/55-x is a local branch whose tracking ref is gone (merged, then `fetch --prune`); t/55-y is local with no tracking.
"$PLUGIN/bin/claim" 41 x --repo-dir "$W" --base main >/dev/null || fx_die "claim 41"
"$PLUGIN/bin/claim" 55 x --repo-dir "$W" --base main >/dev/null || fx_die "claim 55"
g -C "$W" fetch -q origin || fx_die "fetch"
# (origin deletes t/55-x too, as a merge does, so no later full fetch brings the tracking ref back)
g -C "$W" branch -q --no-track t/55-x origin/t/55-x && git -C "$TMP/origin.git" update-ref -d refs/heads/t/55-x \
  && g -C "$W" update-ref -d refs/remotes/origin/t/55-x || fx_die "t/55-x"
g -C "$W" branch t/55-y main || fx_die "t/55-y"
has "$W" refs/remotes/origin/t/41-x && ! has "$W" refs/remotes/origin/t/55-x || fx_die "setup tracking refs"

# --- rule 1: only the prepared state is checked (git ignores a committed/aborted hook's exit code anyway).
# The same unclaimed creation line is fed straight to the installed shim in each state.
Z40=0000000000000000000000000000000000000000
MAINSHA=$(git -C "$W" rev-parse main | tr -d '\r')
printf '%s %s refs/heads/t/77-x\n' "$Z40" "$MAINSHA" > "$TMP/rt.in"
SHIM='cd "$1" && exec "$2/reference-transaction" "$3" < "$4"'   # <repo> <hook dir> <state> <stdin file>
expect rt_state_prepared_checked block "$NOCLAIM77" hk bash -c "$SHIM" _ "$W" "$HK" prepared "$TMP/rt.in" \
  && ok rt_state_prepared_checked
expect rt_state_committed_passes 0 - hk bash -c "$SHIM" _ "$W" "$HK" committed "$TMP/rt.in" && ok rt_state_committed_passes
expect rt_state_aborted_passes 0 - hk bash -c "$SHIM" _ "$W" "$HK" aborted "$TMP/rt.in" && ok rt_state_aborted_passes

# --- rule 2 is pure shell: nothing selected -> no git or jq call (git, jq and gk_managed stubbed to log; the
# control line proves the stubs are reached once something IS selected)
C41=$(git -C "$W" rev-parse origin/t/41-x | tr -d '\r')
{ printf '%s %s refs/heads/t/41-x\n' "$C41" "$MAINSHA"          # a commit on an existing t/ branch
  printf '%s %s refs/heads/t/55-x\n' "$Z40" "$Z40"              # a deletion
  printf '%s ref:refs/heads/t/77-x HEAD\n' "$Z40"               # HEAD symref
  printf '%s %s refs/remotes/origin/t/77-x\n' "$Z40" "$MAINSHA" # a tracking ref
  printf '%s %s refs/heads/main\n' "$Z40" "$MAINSHA"            # a non-t branch
} > "$TMP/rt-none.in"
{ cat "$TMP/rt-none.in"; printf '%s %s refs/heads/t/77-x\n' "$Z40" "$MAINSHA"; } > "$TMP/rt-one.in"
LIBS=". '$PLUGIN/bin/_lib.sh'; . '$PLUGIN/bin/_scope.sh'; . '$PLUGIN/hooks/git/_git-lib.sh'; . '$PLUGIN/hooks/git/rules/reference-transaction.sh'"
STUBS="git() { echo git >> '$TMP/calls'; }; jq() { echo jq >> '$TMP/calls'; }; gk_managed() { echo managed >> '$TMP/calls'; }"
rf() { : > "$TMP/calls"; (cd "$W" && bash -c "$LIBS; gk_init reference-transaction '$HK'; $STUBS; gk_ref_tx prepared '$1'") >/dev/null 2>&1; }
if ! rf "$TMP/rt-none.in"; then fail "rt_filter_no_git: rc != 0 with nothing selected"
elif [ -s "$TMP/calls" ]; then fail "rt_filter_no_git: called $(tr '\n' ' ' < "$TMP/calls")with nothing selected"
else rf "$TMP/rt-one.in"; grep -q git "$TMP/calls" && ok rt_filter_no_git || fail "rt_filter_no_git: control made no git call"; fi

# --- rule 5: an unclaimed creation blocks, however it is started; the branch is absent afterwards
rm -f "$TMP/state/shadow/new.jsonl"
expect rt_checkout_b_unclaimed block "$NOCLAIM77" hk git -C "$W" checkout -b t/77-x && absent rt_checkout_b_unclaimed
# rt_block_logged: the block row carries the hook, the slug, the ref and the session
ROW=$(tail -1 "$TMP/state/shadow/new.jsonl" 2>/dev/null | tr -d '\r')
jq -e '.hook == "reference-transaction" and .repo == "acme/api" and .ref == "refs/heads/t/77-x" and .session == "s1"
       and (.reason | startswith("no claim for issue 77"))' >/dev/null 2>&1 <<<"$ROW" \
  && ok rt_block_logged || fail "rt_block_logged: $ROW"
[ "$(git -C "$W" symbolic-ref --short HEAD | tr -d '\r')" = main ] || fx_die "W left main"
expect rt_switch_c block "no claim for issue 77" hk git -C "$W" switch -c t/77-x && absent rt_switch_c
expect rt_branch_new block "no claim for issue 77" hk git -C "$W" branch t/77-x && absent rt_branch_new
expect rt_branch_f_unclaimed block "no claim for issue 77" hk git -C "$W" branch -f t/77-x main && absent rt_branch_f_unclaimed
expect rt_worktree_add_b block "no claim for issue 77" hk git -C "$W" worktree add -b t/77-x "$(mp "$TMP/wt77")" \
  && absent rt_worktree_add_b
rm -rf "$TMP/wt77"; git -C "$W" worktree prune 2>/dev/null
expect rt_update_ref block "no claim for issue 77" hk git -C "$W" update-ref refs/heads/t/77-x HEAD && absent rt_update_ref
expect rt_fetch_dot block "no claim for issue 77" hk git -C "$W" fetch . main:t/77-x && absent rt_fetch_dot
expect rt_alias block "no claim for issue 77" hk git -C "$W" -c alias.nb="checkout -b" nb t/77-x && absent rt_alias

# --- allowed: a claimed creation
expect rt_dwim_checkout 0 - hk git -C "$W" checkout -q t/41-x && present rt_dwim_checkout "$W" refs/heads/t/41-x
g -C "$W" checkout -q main && g -C "$W" branch -q -D t/41-x || fx_die "reset t/41-x (dwim)"
expect rt_claimed_checkout_b 0 - hk git -C "$W" checkout -q -b t/41-x origin/t/41-x \
  && present rt_claimed_checkout_b "$W" refs/heads/t/41-x
g -C "$W" checkout -q main && g -C "$W" branch -q -D t/41-x || fx_die "reset t/41-x (checkout -b)"
# branch -f of an absent branch sends old zeros: a creation, allowed by the claim
expect rt_branch_f_claimed 0 - hk git -C "$W" branch -f t/41-x origin/t/41-x && present rt_branch_f_claimed "$W" refs/heads/t/41-x

# rt_t_without_issue_allowed: a t/ branch that names no issue number is not a ticket branch (as in pre-push)
expect rt_t_without_issue_allowed 0 - hk git -C "$W" branch t/notes && present rt_t_without_issue_allowed "$W" refs/heads/t/notes

# rt_slug_mismatch_blocks: issue 41 is claimed as t/41-x, so t/41-y has no evidence
expect rt_slug_mismatch_blocks block "issue 41 is claimed as t/41-x" hk git -C "$W" checkout -b t/41-y \
  && { has "$W" refs/heads/t/41-y && fail "rt_slug_mismatch_blocks: t/41-y exists" || ok rt_slug_mismatch_blocks; }

# --- rule 4: session (the creation itself is claimed, so only the session can block it)
g -C "$W" branch -q -D t/41-x || fx_die "reset t/41-x (session)"
mkdir -p "$TMP/state/latch"; : > "$TMP/state/latch/s1"
expect rt_latched_blocks block "session is latched; the owner must clear it" hk git -C "$W" branch t/41-x origin/t/41-x \
  && { has "$W" refs/heads/t/41-x && fail "rt_latched_blocks: t/41-x exists" || ok rt_latched_blocks; }
rm -f "$TMP/state/latch/s1"
HK_SESSION= expect rt_no_session_blocks block "no session id; start a new session" hk git -C "$W" branch t/41-x origin/t/41-x \
  && { has "$W" refs/heads/t/41-x && fail "rt_no_session_blocks: t/41-x exists" || ok rt_no_session_blocks; }
g -C "$W" branch -q t/41-x origin/t/41-x || fx_die "restore t/41-x"

# --- not a creation: commits on existing branches, including t/55-x whose tracking ref was pruned
c_on() {  # c_on <branch>: an empty commit on <branch> with the hooks; the branch must advance
  local before after
  g -C "$W" checkout -q "$1" || return 1
  before=$(git -C "$W" rev-parse HEAD | tr -d '\r')
  hk git -C "$W" commit -q --allow-empty -m "c on $1" || return 1
  after=$(git -C "$W" rev-parse "$1" | tr -d '\r')
  [ "$before" != "$after" ]
}
if c_on t/41-x && c_on t/55-x && c_on main; then ok rt_commit_unaffected; else fail "rt_commit_unaffected: a commit was refused"; fi
g -C "$W" checkout -q main || fx_die "back to main"
# a new remote t/ branch arrives as a tracking ref only (not a local branch): never selected
g -C "$W" push -q origin main:refs/heads/t/66-x || fx_die "seed t/66-x"
expect rt_fetch_unaffected 0 - hk git -C "$W" fetch -q origin && present rt_fetch_unaffected "$W" refs/remotes/origin/t/66-x

# rt_fetch_creates_both: the tracking ref is missing; fetching into the branch creates both in ONE prepared transaction
clone_managed "$TMP/W2"
g -C "$TMP/W2" update-ref -d refs/remotes/origin/t/41-x || fx_die "W2 drop tracking"
expect rt_fetch_creates_both 0 - hk git -C "$TMP/W2" fetch -q origin t/41-x:t/41-x \
  && present rt_fetch_creates_both "$TMP/W2" refs/heads/t/41-x refs/remotes/origin/t/41-x

# rt_single_branch_blocks_with_hint: no tracking line in a --single-branch clone; the message names the fetch that fixes it
clone_managed "$TMP/SB" --single-branch
HINT='git fetch origin +refs/heads/t/41-x:refs/remotes/origin/t/41-x'
if expect rt_single_branch_blocks_with_hint block "$HINT" hk git -C "$TMP/SB" fetch origin t/41-x:t/41-x; then
  if has "$TMP/SB" refs/heads/t/41-x; then fail "rt_single_branch_blocks_with_hint: t/41-x created"
  elif ! hk git -C "$TMP/SB" fetch -q origin +refs/heads/t/41-x:refs/remotes/origin/t/41-x; then
    fail "rt_single_branch_blocks_with_hint: the hinted fetch failed"
  elif expect rt_single_branch_blocks_with_hint 0 - hk git -C "$TMP/SB" fetch -q origin t/41-x:t/41-x; then
    present rt_single_branch_blocks_with_hint "$TMP/SB" refs/heads/t/41-x
  fi
fi

# rt_unmanaged: other/x is not managed
expect rt_unmanaged 0 - hk git -C "$U" checkout -q -b t/77-x && present rt_unmanaged "$U" refs/heads/t/77-x

# rt_no_verify_not_a_bypass: a commit on an orphan t/77-x creates the ref; skipping pre-commit does not skip this
expect rt_orphan_checkout 0 - hk git -C "$W" checkout -q --orphan t/77-x && ok rt_orphan_checkout
expect rt_no_verify_not_a_bypass block "no claim for issue 77" hk git -C "$W" commit -q --no-verify -m orphan \
  && absent rt_no_verify_not_a_bypass
g -C "$W" checkout -q -f main || fx_die "leave the orphan"

# --- deletion is never blocked (controller ruling 3)
has "$W" refs/remotes/origin/t/55-x && fx_die "the pruned origin/t/55-x came back (the deletion rows would not discriminate)"
expect rt_branch_D_after_prune 0 - hk git -C "$W" branch -q -D t/55-x \
  && { has "$W" refs/heads/t/55-x && fail "rt_branch_D_after_prune: t/55-x still there" || ok rt_branch_D_after_prune; }
expect rt_update_ref_d 0 - hk git -C "$W" update-ref -d refs/heads/t/55-y \
  && { has "$W" refs/heads/t/55-y && fail "rt_update_ref_d: t/55-y still there" || ok rt_update_ref_d; }
git -C "$ORIGIN" update-ref -d refs/heads/t/41-x || fx_die "origin drops t/41-x"
expect rt_fetch_prune 0 - hk git -C "$W" fetch -q --prune origin \
  && { has "$W" refs/remotes/origin/t/41-x && fail "rt_fetch_prune: tracking ref still there" || ok rt_fetch_prune; }

fx_done
