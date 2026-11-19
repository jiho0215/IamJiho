#!/bin/bash
# dispatch.sh <hook-name> <hooks-dir> [args...]: the one entry point of the dev-framework git hooks. The shims in
# <state>/git-hooks/<hash>/ exec it with their own name and dir, plus git's args; git's stdin is ours.
#   1. source bin/_lib.sh FIRST (MSYS_NO_PATHCONV / MSYS2_ARG_CONV_EXCL: a `src:dst` refspec must reach git.exe
#      unconverted), then bin/_scope.sh and _git-lib.sh;
#   2. gk_init; save stdin to a temp file (it is read twice: by our rules and by the repo's own hook);
#   3. run this hook's rules, hooks/git/rules/<hook-name>.sh, when present (a block exits here, before the chain);
#   4. gk_chain: run the hook git would have run without us, and exit with its code.
# DEVFW_GK_TRACE=1 (tests only; off by default) appends one line per run to <state>/dispatch.log.
GK_DISPATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

if [ "${DEVFW_GK_TRACE:-}" = 1 ] && [ -n "$GK_STATE" ]; then
  { mkdir -p "$GK_STATE" && printf '%s\t%s\t%s\n' "$GK_NAME" "$(pwd)" "$*" >> "$GK_STATE/dispatch.log"; } 2>/dev/null || true
fi

GK_STDIN=$(mktemp 2>/dev/null) || gk_block "cannot create a temp file"
trap 'rm -f "$GK_STDIN" 2>/dev/null' EXIT
if [ -t 0 ]; then : > "$GK_STDIN"; else cat > "$GK_STDIN" || gk_block "cannot read the hook input"; fi

GK_RULES="$GK_DISPATCH_DIR/rules/$GK_NAME.sh"
if [ -f "$GK_RULES" ]; then
  . "$GK_RULES"
  case "$GK_NAME" in
    pre-push)              GK_RULE_FN=gk_pre_push ;;
    reference-transaction) GK_RULE_FN=gk_ref_tx ;;
    pre-commit)            GK_RULE_FN=gk_pre_commit ;;
  esac
  declare -F "$GK_RULE_FN" >/dev/null || gk_block "rules/$GK_NAME.sh defines no $GK_RULE_FN; start a new session"
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
