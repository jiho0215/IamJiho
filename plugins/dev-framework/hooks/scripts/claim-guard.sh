#!/bin/bash
# claim-guard: PreToolUse hook (v6). Blocks creating a t/<n>-<slug> ticket branch (git worktree add -b, git
# checkout -b, git switch -c, git branch <new>) in a managed repo unless origin holds a claim for issue <n>
# (a commit in base..branch carrying "Claim-Issue: <n>"). Design 7a B1: it checks the claim exists and names this
# ticket, not who made it.
# Rules: (1) no DEVFW_CORE_DIR, or no worktree|checkout|switch|branch in the command -> allow. (2) scope, with no
# network and nothing that can fail: each parsed branch named ^t/[1-9][0-9]*- whose dir (else HOOK_CWD) has a raw
# origin URL naming a managed repo; none -> allow. An opaque segment that would create/check out a branch is in
# scope when HOOK_CWD is managed, a cd / -C argument is non-literal, or the text names a managed slug; in scope +
# opaque + (the text mentions t/ or the segment is non-literal) blocks. A parser failure blocks only when the
# text also mentions t/. (3) fail closed; hook_claim_ok: 3 blocks "no claim", 1 blocks "cannot verify".
# Rule 4 (EnterWorktree) is NOT implemented: Q5 (is it hookable) was never measured (controller ruling R5).
# KNOWN GAP: the parser emits creation forms only; a plain `git checkout t/41-x` / `git switch t/41-x` of an
# existing branch is not a Branch entry, so it is not seen here. Network calls are bounded by
# DEVFW_HOOK_NET_TIMEOUT (default 20s); a timeout blocks.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_v6-hook.sh"
hook_init claim-guard 25
[ -n "$HOOK_CORE" ] || exit 0
[ "$HOOK_TOOL" = Bash ] || exit 0
CMD=$(hook_field .tool_input.command)
grep -Eiq 'worktree|checkout|switch|branch' <<<"$CMD" || exit 0

PARSED=$(node "$(devfw_path "$HOOK_LIB_DIR/../../bin/hook-parse")" <<<"$CMD" | tr -d '\r') || PARSED=""
if [ -z "$PARSED" ] || ! jq -e . >/dev/null 2>&1 <<<"$PARSED"; then
  grep -q 't/' <<<"$CMD" || exit 0
  hook_fail_closed
  hook_block "cannot read this branch command exactly; write it as: git worktree add <dir> -b t/<n>-<slug>"
fi

_abs() {
  case "$1" in
    /*|[A-Za-z]:*) printf '%s\n' "$1" ;;
    *) if [ -n "$HOOK_CWD" ]; then printf '%s/%s\n' "$HOOK_CWD" "$1"; else printf '%s\n' "$1"; fi ;;
  esac
}

# Scope pass: ticket-named branches in a managed repo (an unreadable config counts as in scope).
INSCOPE=()
while IFS= read -r b; do
  [ -n "$b" ] || continue
  name=$(jq -r '.name // empty' <<<"$b" | tr -d '\r')
  [[ "$name" =~ ^t/[1-9][0-9]*- ]] || continue
  d=$(jq -r '.dir // empty' <<<"$b" | tr -d '\r')
  if [ -n "$d" ]; then d=$(_abs "$d"); else d="${HOOK_CWD:-.}"; fi
  rc=0; repo=$(hook_repo_of "$d") || rc=1
  if [ "$rc" -ne 0 ] || [ -n "$repo" ]; then INSCOPE+=("$d"$'\t'"$name"); fi
done < <(jq -c '.branches[]' <<<"$PARSED" | tr -d '\r')

OPAQUE_HIT=0
OPQ=$(jq -r '.opaque[] | select(test("worktree|checkout|switch|branch";"i"))' <<<"$PARSED" | tr -d '\r')
if [ -n "$OPQ" ]; then
  rc=0; orepo=$(hook_repo_of "${HOOK_CWD:-.}") || rc=1
  if [ "$rc" -ne 0 ] || [ -n "$orepo" ]; then OPAQUE_HIT=1; fi
  grep -Eq '(^|[;&|({[:space:]])cd[[:space:]]+[^;&|]*[$`(]' <<<"$CMD" && OPAQUE_HIT=1
  grep -Eq '(^|[[:space:]])-C[[:space:]]*[^;&|[:space:]]*[$`(]' <<<"$CMD" && OPAQUE_HIT=1
  rc=0; mrepos=$(hook_managed_repos) || rc=1
  if [ "$rc" -ne 0 ]; then OPAQUE_HIT=1; fi
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if [[ "${CMD,,}" == *"${m,,}"* ]]; then OPAQUE_HIT=1; fi
  done <<<"$mrepos"
  if [ "$OPAQUE_HIT" -eq 1 ]; then
    # in scope: it matters only when it could name a ticket branch (mentions t/, or the name is non-literal)
    if ! grep -q 't/' <<<"$CMD" && ! grep -Eq '[$`(]' <<<"$OPQ"; then OPAQUE_HIT=0; fi
  fi
fi
[ "${#INSCOPE[@]}" -gt 0 ] || [ "$OPAQUE_HIT" -eq 1 ] || exit 0

hook_fail_closed
[ "$OPAQUE_HIT" -eq 0 ] || hook_block "cannot read this branch command exactly; write it as: git worktree add <dir> -b t/<n>-<slug>"

export HOOK_NET_TIMEOUT="${DEVFW_HOOK_NET_TIMEOUT:-20}"
for e in "${INSCOPE[@]}"; do
  d="${e%%$'\t'*}"; name="${e#*$'\t'}"
  [[ "$name" =~ ^t/([1-9][0-9]*)- ]]
  n="${BASH_REMATCH[1]}"
  rc=0
  hook_claim_ok "$d" "$name" origin || rc=$?
  [ "$rc" -ne 3 ] || hook_block "t/$n-… has no claim on origin; the orchestrator claims before a worker starts (bin/claim)"
  [ "$rc" -eq 0 ] || hook_block "cannot verify the claim for $name (fetch failed)"
done
exit 0
