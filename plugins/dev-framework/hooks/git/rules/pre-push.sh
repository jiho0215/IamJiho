#!/bin/bash
# pre-push rules of the dev-framework git hooks. Sourced by hooks/git/dispatch.sh (after bin/_lib.sh, bin/_scope.sh
# and _git-lib.sh); defines functions only. They read git's own resolved ref lines from stdin
# (<local ref> <local sha> <remote ref> <remote sha>), never the command text, so every way of starting a push
# (a shell, node, an alias, a URL instead of a remote name) meets the same rules.
#
# gk_pre_push <remote> <url> <stdin-file>: returns 0 or blocks (gk_block <reason> <slug> <remote ref>). In order:
#   1 scope: only a push to a managed repo is checked (no network before this answer);
#   2 session: a session id is required, and a latched session pushes nothing;
#   per ref line:
#   3 delete (local sha zeros) and force (remote sha not an ancestor of the local sha, or not in this repo) are
#     off unless hooks.pushGuard.allowForce;
#   4 refs/tags/* and refs/devfw/* skip 5-7; any other non-branch destination blocks;
#   5 the managed repo's default branch is merged through bin/merge, never pushed;
#   5b the plan repo only, a non-deletion: when the pushed range (<remote sha>..<local sha>, or for a new branch
#     <local sha> --not --remotes) has a commit touching <plan.path>/, the plan-edit lease must hold
#     (gk_lease_check, reason prefix "plan change in pushed range: "). This catches a plan commit made with the
#     pre-commit hook skipped, or made before the lease moved;
#   6 t/<n>-...: claimed (scope_claim_ok), unless the line is bin/claim's own create-only push (_gk_claim_push_exempt);
#   7 t/<n>-...: issue <n> in the plan repo must not carry needs-ack.
# Every network call goes through gk_net (constant 20 s bound); scope_claim_ok's go through scope_net -> gk_net.

gk_pre_push() {
  local remote="$1" url="$2" in="$3" raw slug line lref lsha rref rsha first="" b n def rc out lab
  local -a lines=() range=()
  raw=$(git config --get "remote.$remote.url" 2>/dev/null) || raw=""
  slug=$(gk_managed "${raw%$'\r'}" "$remote" "$url")
  [ -n "$slug" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -n "$line" ] && lines+=("$line")
  done < "$in"
  [ "${#lines[@]}" -eq 0 ] || { read -r _ _ first _ <<<"${lines[0]}"; }
  [ -n "$GK_SESSION" ] || gk_block "no session id; start a new session" "$slug" "$first"
  ! gk_latched || gk_block "session is latched; the owner must clear it" "$slug" "$first"

  for line in "${lines[@]}"; do
    read -r lref lsha rref rsha <<<"$line"
    # 3: delete / force
    if [[ "$lsha" =~ ^0+$ ]]; then
      [ "$GK_ALLOW_FORCE" = true ] || gk_block "remote branch deletion is off" "$slug" "$rref"
    elif ! [[ "$rsha" =~ ^0+$ ]]; then
      # --is-ancestor: 0 = fast-forward, 1 = not an ancestor, 128 = the remote object is not in this repo (someone
      # else pushed it): only 0 proves a fast-forward
      rc=0; git merge-base --is-ancestor "$rsha" "$lsha" >/dev/null 2>&1 || rc=$?
      [ "$rc" -eq 0 ] || [ "$GK_ALLOW_FORCE" = true ] || gk_block "force-push is off" "$slug" "$rref"
    fi
    # 4: destination
    case "$rref" in
      refs/tags/*|refs/devfw/*) continue ;;
      refs/heads/*) b="${rref#refs/heads/}" ;;
      *) gk_block "unsupported destination $rref; push a branch or a tag" "$slug" "$rref" ;;
    esac
    # 5: the default branch
    def=$(gk_default_of "$slug")
    [ "${b,,}" != "${def,,}" ] || gk_block "merge to $def goes through bin/merge, not a push" "$slug" "$rref"
    # 5b: the plan-edit lease over the pushed range (the plan repo only; a deletion pushes no commits)
    if [ "$slug" = "$GK_PLAN_REPO" ] && ! [[ "$lsha" =~ ^0+$ ]]; then
      if [[ "$rsha" =~ ^0+$ ]]; then range=("$lsha" --not --remotes); else range=("$rsha..$lsha"); fi
      rc=0; out=$(git log --format=%H --name-only "${range[@]}" -- "$GK_PLAN_PATH/" 2>/dev/null) || rc=$?
      [ "$rc" -eq 0 ] || gk_block "cannot list the pushed range (git log exit $rc)" "$slug" "$rref"
      [ -z "${out//[$'\r\n']/}" ] || gk_lease_check "plan change in pushed range: " "$slug" "$rref"
    fi
    # 6: claim
    [[ "$b" =~ ^t/([1-9][0-9]*)- ]] || continue
    n="${BASH_REMATCH[1]}"
    if ! _gk_claim_push_exempt "$remote" "$lsha" "$rsha" "$n" "$b" "$slug" "$rref"; then
      rc=0; scope_claim_ok "$(pwd)" "$b" "$remote" || rc=$?
      [ "$rc" -ne 3 ] || gk_block "no claim for issue $n; run bin/claim first" "$slug" "$rref"
      [ "$rc" -eq 0 ] || gk_block "cannot verify the claim (fetch failed)" "$slug" "$rref"
      # 7: needs-ack (the exempt claim push skips it, as bin/claim's push always has)
      [ -n "$GK_PLAN_REPO" ] || gk_block "cannot read issue $n (no plan repo in the config)" "$slug" "$rref"
      rc=0; gk_net out 20 gh api "repos/$GK_PLAN_REPO/issues/$n" || rc=$?
      [ "$rc" -eq 0 ] || gk_block "cannot read issue $n (gh exit $rc: ${GK_NET_ERR%%$'\n'*})" "$slug" "$rref"
      lab=$(jq -r '[.labels[]?.name] | join("\n")' <<<"${out//$'\r'/}" 2>/dev/null) \
        || gk_block "cannot read issue $n (the answer is not an issue)" "$slug" "$rref"
      ! grep -qx 'needs-ack' <<<"${lab//$'\r'/}" \
        || gk_block "issue $n needs-ack: acknowledge the plan change before pushing" "$slug" "$rref"
    fi
  done
  return 0
}

# _gk_claim_push_exempt <remote> <local sha> <remote sha> <n> <branch> <slug> <remote ref>: 0 when this line is
# bin/claim's create-only claim push, recognised by its shape (all must hold):
#   the remote ref does not exist yet (remote sha zeros); the pushed commit has exactly one parent and the same tree
#   as that parent; its message has the line "Claim-Issue: <n>"; and one fresh ls-remote of <remote> shows the
#   parent as the tip of some refs/heads/* and no OTHER refs/heads/t/<n>-* (one issue, one claim).
# The local clauses run first, so only a claim-shaped commit costs a network call. An ls-remote failure blocks.
_gk_claim_push_exempt() {
  local remote="$1" lsha="$2" rsha="$3" n="$4" b="$5" slug="$6" rref="$7" pl par tree ptree ls rc
  local -a pa=()
  [[ "$rsha" =~ ^0+$ ]] || return 1
  pl=$(git rev-list --parents -n 1 "$lsha" 2>/dev/null) || return 1
  read -r -a pa <<<"${pl%$'\r'}"   # <commit> <parent>...
  [ "${#pa[@]}" -eq 2 ] || return 1
  par="${pa[1]}"
  tree=$(git rev-parse -q --verify "$lsha^{tree}" 2>/dev/null) || return 1
  ptree=$(git rev-parse -q --verify "$par^{tree}" 2>/dev/null) || return 1
  [ "${tree%$'\r'}" = "${ptree%$'\r'}" ] || return 1
  git log -1 --format=%B "$lsha" 2>/dev/null | tr -d '\r' | grep -qx "Claim-Issue: $n" || return 1
  rc=0; gk_net ls 20 git ls-remote "$remote" 'refs/heads/*' || rc=$?
  [ "$rc" -eq 0 ] || gk_block "cannot verify the claim push (ls-remote failed, exit $rc: ${GK_NET_ERR%%$'\n'*})" "$slug" "$rref"
  ls="${ls//$'\r'/}"
  awk -v p="$par" '$1 == p && $2 ~ /^refs\/heads\// { f = 1 } END { exit !f }' <<<"$ls" || return 1
  awk -v pre="refs/heads/t/$n-" -v me="refs/heads/$b" \
    'index($2, pre) == 1 && $2 != me { f = 1 } END { exit f }' <<<"$ls" || return 1
  return 0
}
