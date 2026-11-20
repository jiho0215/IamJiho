#!/bin/bash
# dispatch.sh <hook-name> <hooks-dir> [args...]: the one entry point of the dev-framework git hooks. The shims in
# <state>/git-hooks/<hash>/ SOURCE it (one bash process per hook run) with their own name and dir, plus git's args;
# git's stdin is ours. Executing it (`bash dispatch.sh ...`, as an older shim does) works the same.
#   1. source bin/_lib.sh FIRST (MSYS_NO_PATHCONV / MSYS2_ARG_CONV_EXCL: a `src:dst` refspec must reach git.exe
#      unconverted), then bin/_scope.sh and _git-lib.sh;
#   2. gk_init; source this hook's rules, hooks/git/rules/<hook-name>.sh, when present;
#   3. the fast path (gk_fast): exit 0 at once when there is provably no repo hook to chain (a valid chain cache
#      entry, and no executable <dir>/<hook>) AND nothing for the rule to check (no rules file, or <fn>_idle says so);
#   4. otherwise the full path: save stdin to a temp file (it is read twice: by our rules and by the repo's own
#      hook), run the rule (a block exits here, before the chain), then gk_chain, and exit with its code.
# The fast path runs no external command (no fork); every branch it cannot decide takes the full path.
# DEVFW_GK_TRACE=1 (tests only; off by default) appends to <state>/dispatch.log one line per run
# (<hook>\t<pwd>\t<args>), then `fast\t<hook>\t<args>` or `full\t<hook>\t<why>`.
case "${BASH_SOURCE[0]}" in
  /*|[A-Za-z]:/*) GK_DISPATCH_DIR="${BASH_SOURCE[0]%/*}" ;;
  *) GK_DISPATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ;;
esac
# The caller's MSYS path-conversion settings, captured BEFORE bin/_lib.sh overrides them: our own git.exe calls run
# with conversion off, but the repo's own hook (gk_chain) runs with exactly the caller's values ("unset" or "set:<v>").
if [ -n "${MSYS_NO_PATHCONV+x}" ]; then GK_CALLER_MSYS_NO_PATHCONV="set:$MSYS_NO_PATHCONV"; else GK_CALLER_MSYS_NO_PATHCONV=unset; fi
if [ -n "${MSYS2_ARG_CONV_EXCL+x}" ]; then GK_CALLER_MSYS2_ARG_CONV_EXCL="set:$MSYS2_ARG_CONV_EXCL"; else GK_CALLER_MSYS2_ARG_CONV_EXCL=unset; fi
. "$GK_DISPATCH_DIR/../../bin/_lib.sh"
. "$GK_DISPATCH_DIR/../../bin/_scope.sh"
. "$GK_DISPATCH_DIR/_git-lib.sh"

GK_NAME="${1:-}"; GK_DIR_ARG="${2:-}"
shift 2 2>/dev/null || true
case "$GK_NAME" in
  pre-push|reference-transaction|pre-commit) ;;
  *) echo "devfw git-hook: unknown hook '${GK_NAME}'; start a new session" >&2; exit 1 ;;
esac
gk_init "$GK_NAME" "$GK_DIR_ARG"

# Recursion bound: our dir chained to itself (a mis-resolved hooks dir) would otherwise nest without end. Legit
# nesting (a repo hook that runs git, which runs our hooks again) stays far below the bound.
GK_DEPTH="${DEVFW_GK_DEPTH:-0}"
[[ "$GK_DEPTH" =~ ^[0-9]{1,3}$ ]] || GK_DEPTH=0
[ "$GK_DEPTH" -lt 8 ] || gk_block "git hooks nested $GK_DEPTH deep (a hook dir that chains to itself?); not running"
export DEVFW_GK_DEPTH=$((GK_DEPTH + 1))

GK_TRACE=""
if [ "${DEVFW_GK_TRACE:-}" = 1 ] && [ -n "$GK_STATE" ]; then
  GK_TRACE="$GK_STATE/dispatch.log"
  { mkdir -p "$GK_STATE" && printf '%s\t%s\t%s\n' "$GK_NAME" "$PWD" "$*" >> "$GK_TRACE"; } 2>/dev/null || true
fi

GK_RULES="$GK_DISPATCH_DIR/rules/$GK_NAME.sh"
GK_RULE_FN=""
if [ -f "$GK_RULES" ]; then
  . "$GK_RULES"
  case "$GK_NAME" in
    pre-push)              GK_RULE_FN=gk_pre_push ;;
    reference-transaction) GK_RULE_FN=gk_ref_tx ;;
    pre-commit)            GK_RULE_FN=gk_pre_commit ;;
  esac
  declare -F "$GK_RULE_FN" >/dev/null || gk_block "rules/$GK_NAME.sh defines no $GK_RULE_FN; start a new session"
fi

if gk_fast "$@"; then
  [ -z "$GK_TRACE" ] || { printf 'fast\t%s\t%s\n' "$GK_NAME" "$*" >> "$GK_TRACE"; } 2>/dev/null || true
  exit 0
fi
[ -z "$GK_TRACE" ] || { printf 'full\t%s\t%s\n' "$GK_NAME" "$GK_FAST_WHY" >> "$GK_TRACE"; } 2>/dev/null || true

GK_STDIN=$(mktemp 2>/dev/null) || gk_block "cannot create a temp file"
trap 'rm -f "$GK_STDIN" ${GK_CACHE_TMP:+"$GK_CACHE_TMP"} 2>/dev/null' EXIT
if [ "$GK_STDIN_TAKEN" = 1 ]; then
  # gk_fast already read part (or all) of stdin, byte-exact: write that part, then the rest
  printf '%s' "$GK_STDIN_DATA" > "$GK_STDIN" || gk_block "cannot read the hook input"
  [ "$GK_STDIN_EOF" = 1 ] || cat >> "$GK_STDIN" || gk_block "cannot read the hook input"
elif [ -t 0 ]; then : > "$GK_STDIN"
else cat > "$GK_STDIN" || gk_block "cannot read the hook input"; fi

if [ -n "$GK_RULE_FN" ]; then
  # a rule returns 0 or calls gk_block; any other return is a rule bug and blocks (fail closed)
  GK_RC=0
  case "$GK_NAME" in
    pre-push)              gk_pre_push "${1:-}" "${2:-}" "$GK_STDIN" || GK_RC=$? ;;
    reference-transaction) gk_ref_tx "${1:-}" "$GK_STDIN" || GK_RC=$? ;;
    pre-commit)            gk_pre_commit || GK_RC=$? ;;
  esac
  [ "$GK_RC" -eq 0 ] || gk_block "internal error: $GK_RULE_FN returned $GK_RC"
fi

GK_RC=0
gk_chain "$GK_NAME" "$GK_STDIN" "$@" || GK_RC=$?
exit "$GK_RC"
