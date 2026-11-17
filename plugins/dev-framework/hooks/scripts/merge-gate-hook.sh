#!/bin/bash
# merge-gate-hook: PreToolUse hook. Blocks `gh pr merge` (and `gh api .../pulls/N/merge`) unless bin/merge-gate
# passes the PR. Rules: (1) no DEVFW_CORE_DIR, or no `gh`/`pulls/` in the command -> allow. (2) Parse; no merge
# and no opaque segment mentioning a merge -> allow. (3) fail closed. An opaque merge cannot be read exactly:
# block. (4) per merge: --auto blocks; no --repo blocks (never inferred); an unmanaged repo is not ours; the plan
# repo needs the lease (`bin/lease check`); every other managed repo must pass `bin/merge-gate`, whose first
# reason leads the block message. Network bounds: lease DEVFW_HOOK_NET_TIMEOUT (20s), gate DEVFW_HOOK_GATE_TIMEOUT
# (100s; the plan's inner 100 < hook 120).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_v6-hook.sh"
hook_init merge-gate-hook
[ -n "$HOOK_CORE" ] || exit 0
[ "$HOOK_TOOL" = Bash ] || exit 0
CMD=$(hook_field .tool_input.command)
grep -Eiq 'gh|pulls/|merge' <<<"$CMD" || exit 0

PARSED=$(node "$(devfw_path "$HOOK_LIB_DIR/../../bin/hook-parse")" <<<"$CMD" | tr -d '\r') || PARSED=""
PARSER_OK=1
if [ -z "$PARSED" ] || ! jq -e . >/dev/null 2>&1 <<<"$PARSED"; then
  PARSER_OK=0
  # the parser failed: only a command that looks like a merge is in scope
  grep -Eiq 'merge|pulls/' <<<"$CMD" || exit 0
fi
if [ "$PARSER_OK" -eq 1 ]; then
  NMERGE=$(jq -r '.merges | length' <<<"$PARSED" | tr -d '\r')
  NOPAQUE=$(jq -r '[.opaque[] | select(test("merge";"i"))] | length' <<<"$PARSED" | tr -d '\r')
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
eval "$(declare -f hook_block | sed '1s/hook_block/_hb_orig/')"
hook_block() { rm -f "$ERRF"; _hb_orig "$@"; }

while IFS= read -r m; do
  [ -n "$m" ] || continue
  pr=$(jq -r '.pr' <<<"$m" | tr -d '\r'); repo=$(jq -r '.repo // empty' <<<"$m" | tr -d '\r')
  auto=$(jq -r '.auto' <<<"$m" | tr -d '\r')
  [ "$pr" != null ] || hook_block "give the PR number: gh pr merge <n> --repo <owner/name>"
  [ "$auto" != true ] || hook_block "never use gh pr merge --auto (it merges at once here)"
  [ -n "$repo" ] || hook_block "pass --repo <owner/name>; the repo is not inferred"
  repo=${repo#https://}; repo=${repo#http://}; repo=${repo#github.com/}; repo=${repo%/}; repo=${repo%.git}
  managed=0
  while IFS= read -r r; do [ -n "$r" ] && [ "${r,,}" = "${repo,,}" ] && managed=1; done <<<"$MANAGED"
  [ "$managed" -eq 1 ] || continue
  if [ -n "$PLAN_REPO" ] && [ "${PLAN_REPO,,}" = "${repo,,}" ]; then
    rc=0
    out=$(timeout "${DEVFW_HOOK_NET_TIMEOUT:-20}" "$BIN/lease" check --core-dir "$CORE_W" 2>&1) || rc=$?
    out="${out//$'\r'/}"
    [ "$rc" -eq 0 ] || hook_block "only the lease holder merges plan PRs: ${out:-lease check failed (exit $rc)}"
  fi
  rc=0
  # bin/merge-gate is a `#!/usr/bin/env node` script: with MSYS_NO_PATHCONV (exported by _v6-hook.sh) Git Bash hands
  # node.exe its path as /c/..., which node cannot load. Let msys convert the script path for this one exec.
  out=$(timeout "${DEVFW_HOOK_GATE_TIMEOUT:-100}" env -u MSYS_NO_PATHCONV -u MSYS2_ARG_CONV_EXCL "$BIN/merge-gate" --core-dir "$CORE_W" --repo "$repo" --pr "$pr" 2>"$ERRF") || rc=$?
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
_done
exit 0
