#!/bin/bash
# plan-edit-guard: PreToolUse hook. Only the lease holder may edit the plan (<core>/<plan.path>).
#
# Rules, in order: (1) no DEVFW_CORE_DIR -> allow. (2) Scope, decided locally with no network: an
# Edit/Write/MultiEdit/NotebookEdit target under the plan dir, or a Bash `git commit` run in core whose staged
# or tracked-modified files (union of `diff --cached` and `diff HEAD`, ruling R2) touch the plan dir; an opaque
# command line in core is in scope (simple rule). Out of scope -> allow, without fetching. (3) fail closed.
# (4) Subagents never edit the plan. NOTE: this clause is convention-backed until Q2 (does a subagent's
# PreToolUse payload carry agent_id?) is measured with tests/v6/manual/hook-probe.sh; it is gated on
# HOOK_AGENT_ID being non-empty. (5) `bin/lease check`: exit 4 -> lease mismatch, 3 -> no lease, other -> cannot
# verify (a 124 timeout, DEVFW_HOOK_NET_TIMEOUT, default 20s, lands here). (6) allow.
# Opaque scope (R9): an opaque segment mentioning commit is in scope if cwd is in core, the command text names
# the core path, or a cd has a non-literal argument. RESIDUAL, accepted: an opaque command (e.g. eval) with no
# core path in its text, run from a cwd outside core, is not seen; other projects must not be blocked.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_v6-hook.sh"
hook_init plan-edit-guard
[ -n "$HOOK_CORE" ] || exit 0

PLAN=$(hook_cfg '.plan.path' 'docs/plan') || hook_block "cannot read the config; not allowing a plan edit"
PLAN=$(_hook_lex "$PLAN")
PLAN_DIR="$HOOK_CORE/$PLAN"

# _abs <path>: absolute against HOOK_CWD when relative.
_abs() {
  case "$1" in
    /*|[A-Za-z]:*|\\*) printf '%s\n' "$1" ;;
    *) if [ -n "$HOOK_CWD" ]; then printf '%s/%s\n' "$HOOK_CWD" "$1"; else printf '%s\n' "$1"; fi ;;
  esac
}

# _text_names_core <text>: does the raw text contain the core path as C:/x, /c/x or with backslashes?
_text_names_core() {
  local t="${1//\\//}" c="$HOOK_CORE" alt=""
  case "${OSTYPE:-}" in msys*|cygwin*) t="${t,,}"; c="${c,,}" ;; esac
  [[ "$c" =~ ^([a-z]):/(.*)$ ]] && alt="/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  [[ "$t" == *"$c"* ]] && return 0
  [ -n "$alt" ] && [[ "$t" == *"$alt"* ]]
}

# _commit_touches_plan <dir>: does a commit run from <dir> carry a plan file? A git failure counts as yes.
_commit_touches_plan() {
  local d names a b ra=0 rb=0 n
  d=$(devfw_path "$1")
  a=$(git -C "$d" diff --cached --name-only 2>/dev/null) || ra=1
  b=$(git -C "$d" diff --name-only HEAD 2>/dev/null) || rb=1
  [ "$ra$rb" != 11 ] || return 0
  names=$(printf '%s\n%s\n' "$a" "$b" | tr -d '\r')
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [[ "$n" == "$PLAN/"* || "$n" == "$PLAN" ]] && return 0
  done <<<"$names"
  return 1
}

IN_SCOPE=0
case "$HOOK_TOOL" in
  Edit|Write|MultiEdit|NotebookEdit)
    TARGET=$(hook_field '.tool_input.file_path // .tool_input.notebook_path')
    if [ -n "$TARGET" ] && hook_under "$(_abs "$TARGET")" "$PLAN_DIR"; then IN_SCOPE=1; fi
    ;;
  Bash)
    CMD=$(hook_field .tool_input.command)
    grep -q 'commit' <<<"$CMD" || exit 0
    PARSED=$(node "$(devfw_path "$HOOK_LIB_DIR/../../bin/hook-parse")" <<<"$CMD" | tr -d '\r') || PARSED=""
    if [ -z "$PARSED" ] || ! jq -e . >/dev/null 2>&1 <<<"$PARSED"; then
      IN_SCOPE=1   # the parser failed on a command that mentions commit: cannot tell, so check the lease
    else
      # R9: an opaque segment that mentions commit is in scope when cwd is in core, or the raw text names the
      # core path (C:/..., /c/..., backslash forms), or a cd has a non-literal argument (unknowable dir).
      if [ "$(jq -r '[.opaque[] | select(test("commit"))] | length' <<<"$PARSED" | tr -d '\r')" -gt 0 ]; then
        if [ -n "$HOOK_CWD" ] && hook_under "$HOOK_CWD" "$HOOK_CORE"; then IN_SCOPE=1; fi
        _text_names_core "$CMD" && IN_SCOPE=1
        grep -Eq '(^|[;&|({[:space:]])cd[[:space:]]+[^;&|]*[$`(]' <<<"$CMD" && IN_SCOPE=1
      fi
      while IFS= read -r d; do
        d=$(jq -r '.' <<<"$d" | tr -d '\r')
        [ "$d" != null ] || d=""
        [ -n "$d" ] && d=$(_abs "$d") || d="$HOOK_CWD"
        [ -n "$d" ] || continue
        hook_under "$d" "$HOOK_CORE" || continue
        if _commit_touches_plan "$d"; then IN_SCOPE=1; fi
      done < <(jq -c '.commits[] | .dir' <<<"$PARSED" | tr -d '\r')
    fi
    ;;
esac
[ "$IN_SCOPE" -eq 1 ] || exit 0

hook_fail_closed
if [ -n "$HOOK_AGENT_ID" ]; then
  hook_block "subagents never edit the plan; return the change to the main session"
fi
rc=0
OUT=$(timeout "${DEVFW_HOOK_NET_TIMEOUT:-20}" "${DEVFW_BIN_DIR:-$HOOK_LIB_DIR/../../bin}/lease" check --core-dir "$(devfw_path "$HOOK_CORE")" 2>&1) || rc=$?
OUT="${OUT//$'\r'/}"
case "$rc" in
  0) exit 0 ;;
  4) hook_block "${OUT:-lease mismatch}" "the plan belongs to another orchestrator; do not edit it" ;;
  3) hook_block "no lease: ${OUT:-missing lease line or local token}" ;;
  *) hook_block "cannot verify the lease (fetch failed); not allowing a plan edit" "$OUT" ;;
esac
