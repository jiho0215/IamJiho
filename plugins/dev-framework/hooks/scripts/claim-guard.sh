#!/bin/bash
# claim-guard: PreToolUse hook (v6). Blocks creating a t/<n>-<slug> ticket branch (git worktree add -b, git
# checkout -b, git switch -c, git branch <new>) in a managed repo unless origin holds a claim for issue <n>
# (a commit in base..branch carrying "Claim-Issue: <n>"). Design 7a B1: it checks the claim exists and names this
# ticket, not who made it.
# Rules: (1) no DEVFW_CORE_DIR, or no worktree|checkout|switch|branch|git in the command -> allow (jq missing: a
# branch verb blocks, else allow; ruling R24). (2) scope, with no network and nothing that can fail: each parsed
# branch named ^t/[1-9][0-9]*- whose dir (else HOOK_CWD) has a raw origin URL naming a managed repo; none -> allow.
# An unreadable branch command (an opaque segment naming a branch verb, or a git alias whose expansion is a
# creation form; rulings R20, R25) is in scope when the parser cannot read its dir, when its literal dir or
# HOOK_CWD is managed, or when the text names a managed slug; in scope + unreadable + (the text mentions t/ or a
# segment is non-literal) blocks. A parser failure blocks only when the text also mentions t/. (3) fail closed;
# hook_claim_ok: 3 blocks "no claim", 1 blocks "cannot verify".
# Rule 4 (EnterWorktree) is NOT implemented: Q5 (is it hookable) was never measured (controller ruling R5).
# KNOWN GAP: the parser emits creation forms only; a plain `git checkout t/41-x` / `git switch t/41-x` of an
# existing branch is not a Branch entry, so it is not seen here. Network calls are bounded by
# DEVFW_HOOK_NET_TIMEOUT (default 20s); a timeout blocks.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_v6-hook.sh"
hook_init claim-guard 25
[ -n "$HOOK_CORE" ] || exit 0
hook_need_jq 'worktree|checkout|switch|branch'
[ "$HOOK_TOOL" = Bash ] || exit 0
CMD=$(hook_field .tool_input.command)
# `git` too: a git alias (git co = checkout -b) or a wrapper names no branch verb (ruling R25)
grep -Eiq 'worktree|checkout|switch|branch|\bgit\b' <<<"$CMD" || exit 0

hook_parse "$CMD"
if [ -z "$PARSED" ]; then
  grep -q 't/' <<<"$CMD" || exit 0
  hook_fail_closed
  hook_block "cannot read this branch command exactly; write it as: git worktree add <dir> -b t/<n>-<slug>"
fi

# _managed_dir <dir>: 0 when <dir>'s origin is a managed repo, or the config cannot be read (in scope).
_managed_dir() {
  local r
  r=$(hook_repo_of "$1") || return 0
  [ -n "$r" ]
}

# Scope pass: ticket-named branches in a managed repo (an unreadable config counts as in scope).
INSCOPE=()
while IFS= read -r b; do
  hook_tick   # R35f
  [ -n "$b" ] || continue
  name=$(jq -r '.name // empty' <<<"$b" | tr -d '\r')
  [[ "$name" =~ ^t/[1-9][0-9]*- ]] || continue
  d=$(jq -r '.dir // empty' <<<"$b" | tr -d '\r')
  if [ -n "$d" ]; then d=$(hook_abs "$d"); else d="${HOOK_CWD:-.}"; fi
  rc=0; repo=$(hook_repo_of "$d") || rc=1
  if [ "$rc" -ne 0 ] || [ -n "$repo" ]; then INSCOPE+=("$d"$'\t'"$name"); fi
done < <(jq -c '.branches[]' <<<"$PARSED" | tr -d '\r')

# R20 + R25: an unreadable branch command (opaque segment, or a git alias expanding to one) is in scope when the
# parser cannot read its dir, when its literal dir or the hook cwd is managed, or when the text names a managed
# slug; in scope, it matters only when it could name a ticket branch (the text mentions t/, or a segment is
# non-literal).
OPAQUE_HIT=0
# an alias counts only when its expansion is a creation form (an alias for plain `checkout` is the DWIM gap, README)
hook_opaque_rows 'worktree|checkout|switch|branch' 'worktree|-[bBcC]\b|--(force-)?create|--orphan|^\s*branch\b|^!.*(checkout|switch|branch)'
if [ "${#HOOK_OPQ_ROWS[@]}" -gt 0 ]; then
  hook_opaque_hit _managed_dir && OPAQUE_HIT=1
  rc=0; mrepos=$(hook_managed_repos) || rc=1
  if [ "$rc" -ne 0 ]; then OPAQUE_HIT=1; fi
  while IFS= read -r m; do
    hook_tick   # R35f
    [ -n "$m" ] || continue
    if [[ "${CMD,,}" == *"${m,,}"* ]]; then OPAQUE_HIT=1; fi
  done <<<"$mrepos"
  if [ "$OPAQUE_HIT" -eq 1 ]; then
    OPQ=$(jq -r '.opaque[], (.aliases // [])[].raw' <<<"$PARSED" | tr -d '\r')
    # M4: an `any` row (an alias from injected config) may name the ticket only inside that config: never dropped
    ANY=$(jq -r '[(.opaqueDirs // [])[] | select(.any == true)] | length' <<<"$PARSED" | tr -d '\r')
    if [ "$ANY" = 0 ] && ! grep -q 't/' <<<"$CMD" && ! grep -Eq '[$`(]' <<<"$OPQ"; then OPAQUE_HIT=0; fi
  fi
fi
[ "${#INSCOPE[@]}" -gt 0 ] || [ "$OPAQUE_HIT" -eq 1 ] || exit 0

hook_fail_closed
[ "$OPAQUE_HIT" -eq 0 ] || hook_block "cannot read this branch command exactly; write it as: git worktree add <dir> -b t/<n>-<slug>"

export HOOK_NET_TIMEOUT="${DEVFW_HOOK_NET_TIMEOUT:-20}"
for e in "${INSCOPE[@]}"; do
  hook_tick   # R35f
  d="${e%%$'\t'*}"; name="${e#*$'\t'}"
  [[ "$name" =~ ^t/([1-9][0-9]*)- ]]
  n="${BASH_REMATCH[1]}"
  rc=0
  hook_claim_ok "$d" "$name" origin || rc=$?
  [ "$rc" -ne 3 ] || hook_block "t/$n-… has no claim on origin; the orchestrator claims before a worker starts (bin/claim)"
  [ "$rc" -eq 0 ] || hook_block "cannot verify the claim for $name (fetch failed)"
done
exit 0
