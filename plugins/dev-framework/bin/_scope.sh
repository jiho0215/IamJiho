#!/bin/bash
# Scope helpers shared by the PreToolUse hooks (hooks/scripts/_v6-hook.sh) and the git hooks (hooks/git/_git-lib.sh).
# Source it; do not execute it. It defines functions only. The caller has sourced bin/_lib.sh (devfw_path, and the
# MSYS no-pathconv setting the claim fetch's `src:dst` refspecs need) and defines
#
#   scope_net <outvar> <seconds> <cmd...>
#
# which runs <cmd...> bounded by <seconds>, assigns its stdout to the variable named <outvar> IN THE CALLER'S OWN
# SHELL (printf -v), returns the command's exit code (124 on a timeout), and never prints. Every network call in this
# file goes through scope_net, and no function here is ever called inside $( ... ): a block raised inside scope_net
# (an exhausted run budget in the PreToolUse hooks) must exit the whole hook, and the hook's network-time counter
# must stay in the hook's shell. Fenced by tests/v6/hooks/lib.test.sh (lib_claim_budget_exits_hook) and by
# tests/v6/hooks/hooks-json.test.sh section 6, which scans this file.
#
# Locals here are prefixed _sc_ so that a scope_net <outvar> never names a local of scope_net's own implementation.

# scope_slug <url>: owner/name for the three GitHub URL forms (https://[user@]github.com/o/n[.git][/],
# git@github.com:o/n[.git], ssh://git@github.com/o/n[.git]), else nothing.
scope_slug() {
  local _sc_u="${1%/}"
  _sc_u="${_sc_u%.git}"
  if [[ "$_sc_u" =~ ^https://([^/@]+@)?github\.com/([^/]+)/([^/]+)$ ]]; then
    printf '%s/%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  elif [[ "$_sc_u" =~ ^(git@github\.com:|ssh://git@github\.com/)([^/]+)/([^/]+)$ ]]; then
    printf '%s/%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  fi
}

# scope_claim_ok <repo-dir> <branch> <remote>: is <branch> (t/<n>-<slug>) claimed on <remote> (a name or URL) right
# now? Fresh reads: ls-remote finds the default branch and whether <branch> exists, then one fetch into
# refs/devfw/claim-check/<pid>/ (--no-write-fetch-head: no FETCH_HEAD race; --refmap=: no remote-tracking updates;
# --no-tags). Each network call is bounded by ${SCOPE_NET_SECS:-20} through the caller's scope_net.
# Returns 0 claimed (a commit in base..<branch> carries "Claim-Issue: <n>"), 3 not claimed (no issue number in the
# name, branch missing, or no such trailer), 1 network/git error. Never call it inside $( ... ).
scope_claim_ok() {
  local _sc_dir _sc_branch="$2" _sc_remote="${3:-origin}" _sc_n _sc_ls _sc_base _sc_body _sc_t="${SCOPE_NET_SECS:-20}"
  _sc_dir=$(devfw_path "$1")
  [[ "$_sc_branch" =~ ^t/([1-9][0-9]*)- ]] || return 3
  _sc_n="${BASH_REMATCH[1]}"
  git check-ref-format "refs/heads/$_sc_branch" || return 3
  scope_net _sc_ls "$_sc_t" git -C "$_sc_dir" ls-remote --symref "$_sc_remote" HEAD "refs/heads/$_sc_branch" || return 1
  _sc_ls="${_sc_ls//$'\r'/}"
  _sc_base=$(sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]HEAD$#\1#p' <<<"$_sc_ls" | head -1)
  [ -n "$_sc_base" ] || return 1
  awk -v r="refs/heads/$_sc_branch" '$2 == r { f = 1 } END { exit !f }' <<<"$_sc_ls" || return 3
  # per-process refs (M1): two checks of the same claim can run in parallel and must not lock the same ref; deleted
  # after the read (a killed run can leave one behind under refs/devfw/claim-check/<pid>/, harmless).
  local _sc_cr="refs/devfw/claim-check/$$" _sc_rc=3
  scope_net _sc_body "$_sc_t" git -C "$_sc_dir" -c gc.auto=0 -c maintenance.auto=false fetch -q --no-tags --no-write-fetch-head \
    --refmap= --no-recurse-submodules "$_sc_remote" \
    "+refs/heads/$_sc_branch:$_sc_cr/b/$_sc_branch" "+refs/heads/$_sc_base:$_sc_cr/base" \
    || { _scope_claim_refs_rm "$_sc_dir" "$_sc_cr"; return 1; }
  if _sc_body=$(git -C "$_sc_dir" log --format=%B "$_sc_cr/base..$_sc_cr/b/$_sc_branch" 2>/dev/null); then
    grep -q "^Claim-Issue: $_sc_n\$" <<<"${_sc_body//$'\r'/}" && _sc_rc=0
  else _sc_rc=1; fi
  _scope_claim_refs_rm "$_sc_dir" "$_sc_cr"
  return "$_sc_rc"
}
_scope_claim_refs_rm() {  # _scope_claim_refs_rm <dir> <ref-prefix>: delete this run's claim-check refs
  local _sc_r
  while IFS= read -r _sc_r; do
    [ -n "$_sc_r" ] && git -C "$1" update-ref -d "$_sc_r" >/dev/null 2>&1
  done < <(git -C "$1" for-each-ref --format='%(refname)' "$2/" 2>/dev/null | tr -d '\r')
  return 0
}
