#!/bin/bash
# merge-gate-hook: PreToolUse hook. Blocks `gh pr merge` (and `gh api .../pulls/N/merge`) unless bin/merge-gate
# passes the PR. Rules: (1) no DEVFW_CORE_DIR, or no `gh`/`pulls/`/`merge` in the command -> allow (jq missing:
# `merge`/`pulls/` blocks, else allow; ruling R24). (2) Parse; no merge, no opaque segment mentioning a merge and
# no gh/git alias expanding to one (ruling R25) -> allow. A gh endpoint given as a full URL is read like a path
# (ruling R22). (3) fail closed. An unreadable merge cannot be read exactly: block (an alias whose `gh alias list`
# failed blocks only when the hook cwd is managed). (4) per merge: --auto blocks; no --repo blocks (never inferred);
# an unmanaged repo is not ours; the plan repo is decided by the lease alone (`bin/lease check`; design B1, ruling
# R23: bin/merge-gate is not called for it); every other managed repo must pass `bin/merge-gate`, whose first
# reason leads the block message. Network bounds: lease DEVFW_HOOK_NET_TIMEOUT (20s), gate DEVFW_HOOK_GATE_TIMEOUT
# (100s; the plan's inner 100 < hook 120). R29a: the pre-filter takes `git` too (a git alias or injected config can
# run a merge with no merge word in the text); a git/gh shell (`!`) alias step counts when its text names gh, merge
# or pulls/, or when the dir it was looked up in is managed. R34: a branch-merge API call (a write to
# repos/<o>/<n>/merges, GraphQL mergeBranch) blocks when its repo is managed or cannot be read: such merges go
# through a PR.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_v6-hook.sh"
hook_init merge-gate-hook 115
[ -n "$HOOK_CORE" ] || exit 0
hook_need_jq 'merge|pulls/'
[ "$HOOK_TOOL" = Bash ] || exit 0
CMD=$(hook_field .tool_input.command)
grep -Eiq 'gh|pulls/|merge|\bgit\b' <<<"$CMD" || exit 0   # R29a: \bgit\b too

hook_parse "$CMD"
PARSER_OK=1
if [ -z "$PARSED" ]; then
  PARSER_OK=0
  # the parser failed: only a command that looks like a merge is in scope
  grep -Eiq 'merge|pulls/' <<<"$CMD" || exit 0
fi
NOPAQUE=0; NUNRES=0
if [ "$PARSER_OK" -eq 1 ]; then
  NMERGE=$(jq -r '.merges | length' <<<"$PARSED" | tr -d '\r')
  # the GraphQL merge mutations are words of their own (R33 matches whole words); so is the branch-merge API (R34):
  # a path segment `merges` (repos/<o>/<n>/merges). R35e: written `(?<=/)merges`, not `repos/\S*/merges`, which
  # retried from every `repos/` (quadratic: a 1 MB whole-command row of repos/repos/... passed the hook timeout)
  hook_opaque_rows 'merge|pulls/|mergePullRequest|enablePullRequestAutoMerge|mergeBranch|(?<=/)merges' 'merge|pulls/' '\bgh\b|merge|pulls/'
  for row in "${HOOK_OPQ_ROWS[@]}"; do
    case "$row" in
      2*) NUNRES=$((NUNRES + 1)) ;;
      3*)   # R29a: a `!` alias whose text names no merge counts only where it was looked up in a managed repo
        rc=0; crepo=$(hook_repo_of "${row#*$'\t'}") || rc=1
        if [ "$rc" -ne 0 ] || [ -n "$crepo" ]; then NOPAQUE=$((NOPAQUE + 1)); fi ;;
      *) NOPAQUE=$((NOPAQUE + 1)) ;;
    esac
  done
  if [ "$NUNRES" -gt 0 ]; then   # gh alias list failed: in scope only from a managed cwd (R25)
    rc=0; crepo=$(hook_repo_of "${HOOK_CWD:-.}") || rc=1
    if [ "$rc" -ne 0 ] || [ -n "$crepo" ]; then NOPAQUE=$((NOPAQUE + NUNRES)); fi
  fi
  [ "$NMERGE" -gt 0 ] || [ "$NOPAQUE" -gt 0 ] || exit 0
fi

hook_fail_closed
[ "$PARSER_OK" -eq 1 ] || hook_block "cannot read this merge command exactly; write it as: gh pr merge <n> --repo <owner/name> --squash"
[ "$NOPAQUE" -eq 0 ] || hook_block "cannot read this merge command exactly; write it as: gh pr merge <n> --repo <owner/name> --squash"

MANAGED=$(hook_managed_repos) || hook_block "cannot read the config; not allowing a merge"
PLAN_REPO=$(hook_cfg '.plan.repo') || hook_block "cannot read the config; not allowing a merge"
BIN="${DEVFW_BIN_DIR:-$HOOK_LIB_DIR/../../bin}"
CORE_W=$(devfw_path "$HOOK_CORE")
ERRF=$(mktemp)
_done() { rm -f "$ERRF"; }
HOOK_CLEANUP=_done   # runs on every exit from here: hook_block, the EXIT trap, the internal-error path

while IFS= read -r m; do
  [ -n "$m" ] || continue
  pr=$(jq -r '.pr' <<<"$m" | tr -d '\r'); repo=$(jq -r '.repo // empty' <<<"$m" | tr -d '\r')
  auto=$(jq -r '.auto' <<<"$m" | tr -d '\r')
  # R34a: normalise the repo (GH_REPO / -R / --repo given with a host or as a URL) BEFORE any use, so the branch-merge
  # path and the gh-pr-merge path read it the same way (github.com/acme/api and https://… both become acme/api).
  [ -z "$repo" ] || { repo=${repo#https://}; repo=${repo#http://}; repo=${repo#github.com/}; repo=${repo%/}; repo=${repo%.git}; }
  if [ "$(jq -r '.via' <<<"$m" | tr -d '\r')" = gh-api-branch-merge ]; then
    # R34: a branch-merge API (REST repos/<o>/<n>/merges, GraphQL mergeBranch) moves a branch with no PR and no gate
    BRANCH_MSG="branch merges into a managed repo go through a PR: gh pr create, then gh pr merge <n> --repo <owner/name> --squash"
    [ -n "$repo" ] || hook_block "$BRANCH_MSG" "(this branch merge names no repo the hook can read, so it is treated as managed)"
    while IFS= read -r r; do [ -n "$r" ] && [ "${r,,}" = "${repo,,}" ] && hook_block "$BRANCH_MSG" "(repo: $r)"; done <<<"$MANAGED"
    continue
  fi
  [ "$pr" != null ] || hook_block "give the PR number: gh pr merge <n> --repo <owner/name>"
  [ "$auto" != true ] || hook_block "never use gh pr merge --auto (it merges at once here)"
  [ -n "$repo" ] || hook_block "pass --repo <owner/name>; the repo is not inferred"
  managed=0
  while IFS= read -r r; do [ -n "$r" ] && [ "${r,,}" = "${repo,,}" ] && managed=1; done <<<"$MANAGED"
  [ "$managed" -eq 1 ] || continue
  if [ -n "$PLAN_REPO" ] && [ "${PLAN_REPO,,}" = "${repo,,}" ]; then
    # R23: a plan PR is decided by the lease alone; bin/merge-gate gates code repos only
    rc=0
    hook_net out merge "${DEVFW_HOOK_NET_TIMEOUT:-20}" "$BIN/lease" check --core-dir "$CORE_W" || rc=$?
    out="${out//$'\r'/}"
    [ "$rc" -eq 0 ] || hook_block "only the lease holder merges plan PRs: ${out:-lease check failed (exit $rc)}"
    continue
  fi
  rc=0
  # bin/merge-gate is a `#!/usr/bin/env node` script: with MSYS_NO_PATHCONV (exported by _v6-hook.sh) Git Bash hands
  # node.exe its path as /c/..., which node cannot load. Let msys convert the script path for this one exec.
  hook_net out "$ERRF" "${DEVFW_HOOK_GATE_TIMEOUT:-100}" env -u MSYS_NO_PATHCONV -u MSYS2_ARG_CONV_EXCL "$BIN/merge-gate" --core-dir "$CORE_W" --repo "$repo" --pr "$pr" || rc=$?
  out="${out//$'\r'/}"
  [ "$rc" -ne 124 ] || hook_block "merge-gate could not run: timed out"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
    hook_block "merge-gate could not run: $(tr -d '\r' <"$ERRF" | head -3 | tr '\n' ' ')${out:+$out}"
  fi
  err=$(jq -r '.error // empty' <<<"$out" | tr -d '\r')
  [ -z "$err" ] || hook_block "merge-gate could not run: $err"
  [ "$(jq -r '.pass' <<<"$out" | tr -d '\r')" != true ] || continue
  mapfile -t reasons < <(jq -r '.reasons[]?' <<<"$out" | tr -d '\r')
  [ "${#reasons[@]}" -gt 0 ] || reasons=("merge-gate refused PR $pr in $repo")
  hook_block "${reasons[0]}" "${reasons[@]:1}"
done < <(jq -c '.merges[]' <<<"$PARSED" | tr -d '\r')
exit 0
