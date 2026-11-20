#!/bin/bash
# pre-commit rules of the dev-framework git hooks. Sourced by hooks/git/dispatch.sh (after bin/_lib.sh, bin/_scope.sh
# and _git-lib.sh); defines functions only. A hook's cwd is the work tree top.
#
# gk_pre_commit: returns 0 or blocks (gk_block <reason> <slug> <ref>). Two independent checks:
#   A the plan-edit lease. Scope: origin's raw URL (remote.origin.url, never the insteadOf result) names the plan
#     repo; else no further git call for A. Then `git diff --cached --name-only -- <plan.path>/` (the index git is
#     committing: the hook's GIT_INDEX_FILE, so `commit -a` and `commit <paths>` are covered); empty -> nothing to
#     check. Else `bin/lease check --core-dir <core>` (gk_lease_check, through gk_net): 4 -> "only the lease holder
#     commits plan changes: <lease's line>", 3 -> "no lease: <line>", other -> "cannot verify the lease (...)".
#     A commit made with this hook skipped is still caught when it is pushed (pre-push, "plan change in pushed range").
#   B the current t/ branch. `git branch -m/-M` and `-c/-C` create a t/<n>-<slug> branch with no reference-transaction
#     line for it (git 2.53, measured in Task 5), so the claim is checked again here, before any commit lands on it.
#     The current branch is read from <git dir>/HEAD without a fork (_gk_head_ref); a non-t branch or a detached HEAD
#     makes no git call. For refs/heads/t/* (any case): scope = some managed remote (gk_managed_remotes, as in
#     reference-transaction rule 3; none -> allow); a session id is required and a latched session commits nothing;
#     then the same lowercase-name and local-evidence check as reference-transaction rule 5 (gk_t_evidence).
#     When HEAD cannot be read that way (a reftable repo), git is asked (`symbolic-ref`) after the scope check.
#
# gk_pre_commit_idle: the dispatcher's fast-path pre-filter (gk_fast; honoured only when the repo has no pre-commit
# hook of its own to chain). 0 = neither check can apply, decided without a fork:
#   - HEAD read as a non-t branch or detached (an unreadable HEAD is busy), AND
#   - no plan repo in the install (idle exit 1), or no config git reads for this repo can name it: the command scope
#     and every file of the valid chain-cache entry, scanned for the plan repo's owner/name (_gk_config_may_name; a
#     superset of "origin's raw URL names it", since every GitHub URL form holds owner/name) (idle exit 2).
# Anything else is 1 (busy) and the full path runs gk_pre_commit.

gk_pre_commit_idle() {
  _gk_head_ref || return 1
  case "${GK_HEAD_REF,,}" in refs/heads/t/*) return 1 ;; esac
  [ -n "$GK_PLAN_REPO" ] || return 0
  ! _gk_config_may_name "$GK_PLAN_REPO" || return 1
  return 0
}

gk_pre_commit() {
  local raw slug staged rc ref decided=1

  # A: the plan-edit lease
  if [ -n "$GK_PLAN_REPO" ]; then
    raw=$(git config --get remote.origin.url 2>/dev/null) || raw=""
    slug=$(scope_slug "${raw//$'\r'/}")
    if [ "${slug,,}" = "$GK_PLAN_REPO" ]; then
      rc=0; staged=$(git diff --cached --name-only -- "$GK_PLAN_PATH/" 2>/dev/null) || rc=$?
      [ "$rc" -eq 0 ] || gk_block "cannot list the staged changes under $GK_PLAN_PATH/ (git diff exit $rc)" "$GK_PLAN_REPO"
      [ -z "${staged//[$'\r\n']/}" ] || gk_lease_check "" "$GK_PLAN_REPO" ""
    fi
  fi

  # B: the current t/ branch
  _gk_head_ref || decided=0
  if [ "$decided" = 1 ]; then
    case "${GK_HEAD_REF,,}" in refs/heads/t/*) ;; *) return 0 ;; esac
  fi
  gk_managed_remotes
  [ "${#GK_MREMOTES[@]}" -gt 0 ] || return 0
  if [ "$decided" = 0 ]; then
    rc=0; ref=$(git symbolic-ref -q HEAD 2>/dev/null) || rc=$?
    [ "$rc" -ne 1 ] || return 0   # detached
    [ "$rc" -eq 0 ] || gk_block "cannot read the current branch (git symbolic-ref exit $rc)" "$GK_MSLUG"
    GK_HEAD_REF="${ref%$'\r'}"
    case "${GK_HEAD_REF,,}" in refs/heads/t/*) ;; *) return 0 ;; esac
  fi
  [ -n "$GK_SESSION" ] || gk_block "no session id; start a new session" "$GK_MSLUG" "$GK_HEAD_REF"
  ! gk_latched || gk_block "session is latched; the owner must clear it" "$GK_MSLUG" "$GK_HEAD_REF"
  gk_t_evidence "$GK_HEAD_REF" "$GK_MSLUG"
  return 0
}
