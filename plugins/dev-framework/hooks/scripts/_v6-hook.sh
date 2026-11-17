#!/bin/bash
# Shared library for dev-framework v6 guard hooks. Source it; do not execute it.
#
# Shape of a guard:  hook_init <name>  ->  decide scope (no network, nothing that can fail; out of scope
# -> exit 0)  ->  hook_fail_closed  ->  checks, each failure ending in hook_block.
# Never call hook_block inside $( ... ): exit would leave only the subshell.

HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# devfw_path, devfw_require; also exports MSYS_NO_PATHCONV for Git Bash.
. "$HOOK_LIB_DIR/../../bin/_lib.sh"

# ---- run deadline (ruling R19) ----
# A hooks.json timeout does not block (fail-open), so each hook run has ONE budget, strictly below its hooks.json
# timeout (>= 5 s margin for local node/jq/git work), counted from when this library is sourced. Every network call
# goes through hook_net, which bounds it by min(its per-call bound, the time left). No time left before a call
# blocks. DEVFW_HOOK_BUDGET overrides the budget (tests; user-controlled, like DEVFW_HOOK_NET_TIMEOUT).
_hook_now_ms() {  # sets HOOK_NOW_MS (epoch milliseconds)
  local r="${EPOCHREALTIME:-}"
  if [ -n "$r" ]; then r="${r//[.,]/}"; HOOK_NOW_MS=$(( 10#${r:0:${#r}-3} ))
  else HOOK_NOW_MS=$(( $(date +%s) * 1000 )); fi
}
_hook_set_budget() {  # _hook_set_budget <seconds>
  HOOK_BUDGET="$1"
  [[ "${DEVFW_HOOK_BUDGET:-}" =~ ^[0-9]+$ ]] && HOOK_BUDGET="$DEVFW_HOOK_BUDGET"
  export HOOK_DEADLINE_MS=$(( HOOK_START_MS + HOOK_BUDGET * 1000 ))
}
_hook_now_ms; HOOK_START_MS=$HOOK_NOW_MS
_hook_set_budget 25

# hook_net <out-var> <stderr: null|merge|<file>> <per-call-seconds> <command> [args...]: run the command with its
# stdout in <out-var>, bounded by min(per-call, time left in the run budget); returns the command's exit code
# (124 on a timeout). When less than 1 s is left it does not run the command: it blocks (hook_block), or, with
# HOOK_BUDGET_SOFT=1 (the digest, which must always exit 0), returns 124. Call it in the hook's own shell, never
# inside $( ... ), and never redirect its stderr (that is where a block message goes).
hook_net() {
  local __hn_v="$1" __hn_e="$2" __hn_t="$3" __hn_left __hn_cap __hn_s __hn_o="" __hn_rc=0
  shift 3
  _hook_now_ms
  __hn_left=$(( HOOK_DEADLINE_MS - HOOK_NOW_MS ))
  if [ "$__hn_left" -lt 1000 ]; then
    printf -v "$__hn_v" '%s' ""
    [ -z "${HOOK_BUDGET_SOFT:-}" ] || return 124
    hook_block "time budget ran out (${HOOK_BUDGET}s per run) before a network call; not allowing this (retry when the network is faster)"
  fi
  __hn_cap=$__hn_left
  if [[ "$__hn_t" =~ ^[0-9]+$ ]] && [ $(( __hn_t * 1000 )) -lt "$__hn_cap" ]; then __hn_cap=$(( __hn_t * 1000 )); fi
  printf -v __hn_s '%d.%03d' $(( __hn_cap / 1000 )) $(( __hn_cap % 1000 ))
  case "$__hn_e" in
    null)  __hn_o=$(timeout "$__hn_s" "$@" 2>/dev/null) || __hn_rc=$? ;;
    merge) __hn_o=$(timeout "$__hn_s" "$@" 2>&1) || __hn_rc=$? ;;
    *)     __hn_o=$(timeout "$__hn_s" "$@" 2>"$__hn_e") || __hn_rc=$? ;;
  esac
  printf -v "$__hn_v" '%s' "$__hn_o"
  return "$__hn_rc"
}

# hook_init <hook-name> [<run-budget-seconds>]: read the hook's stdin JSON once and set the run budget (default
# 25; every wired hook passes its own, fenced by tests/v6/hooks/hooks-json.test.sh). Empty or non-JSON stdin
# leaves every field empty; the caller decides what that means for scope.
hook_init() {
  HOOK_NAME="$1"
  _hook_set_budget "${2:-25}"
  HOOK_JSON=""
  if [ ! -t 0 ]; then HOOK_JSON=$(cat 2>/dev/null) || HOOK_JSON=""; fi
  HOOK_CORE=""
  [ -z "${DEVFW_CORE_DIR:-}" ] || HOOK_CORE=$(_hook_norm "$DEVFW_CORE_DIR")
  if [ -n "$HOOK_CORE" ] && ! command -v jq >/dev/null 2>&1; then
    hook_block "jq not found (needed to read the hook input and the config)"
  fi
  HOOK_TOOL=$(hook_field .tool_name)
  HOOK_CWD=$(hook_field .cwd)
  HOOK_AGENT_ID=$(hook_field .agent_id)
}

# hook_field <jq-filter>: that field of HOOK_JSON (false and 0 print as such), or nothing.
hook_field() {
  local v
  [ -n "${HOOK_JSON:-}" ] || return 0
  v=$(jq -r "($1) | if . == null then empty else . end" <<<"$HOOK_JSON" 2>/dev/null) || return 0
  [ -z "$v" ] || printf '%s\n' "${v//$'\r'/}"
}

# hook_block <reason> [more lines...]: stderr line 1 is "devfw <hook>: <reason>"; exit 2 (blocks the tool call).
hook_block() {
  trap - ERR EXIT
  _hook_cleanup
  echo "devfw ${HOOK_NAME:-hook}: $1" >&2
  shift
  local l
  for l in "$@"; do echo "$l" >&2; done
  exit 2
}

# HOOK_CLEANUP: optional name of a function (e.g. one removing temp files) run once on the way out: from
# hook_block, and from the EXIT trap hook_fail_closed sets (so a plain `exit 0` after it runs it too). Its output
# and failure are ignored.
_hook_cleanup() {
  local f="${HOOK_CLEANUP:-}"
  HOOK_CLEANUP=""
  [ -z "$f" ] || "$f" >/dev/null 2>&1 || true
}

# hook_fail_closed: from here on, any failing command, and any exit other than 0 or 2 (an unbound variable,
# a stray `exit 1`), blocks. Call it only after the scope decision.
hook_fail_closed() {
  set -o errtrace -o pipefail
  trap 'hook_block "internal error at line $LINENO"' ERR
  trap '_hook_exit_guard $?' EXIT
}
_hook_exit_guard() {
  _hook_cleanup
  case "$1" in
    0|2) ;;
    *) trap - EXIT; echo "devfw ${HOOK_NAME:-hook}: internal error (exit $1)" >&2; exit 2 ;;
  esac
}

# _hook_lex <path>: backslashes to /, "." and ".." resolved lexically, trailing / dropped. A leading ".." of a
# relative path is kept; one above an absolute root is dropped.
_hook_lex() {
  local p="${1//\\//}" lead="" seg out
  local -a segs parts=()
  case "$p" in
    [A-Za-z]:/*) lead="${p:0:2}/"; p="${p:3}" ;;
    /*) lead="/"; p="${p#/}" ;;
  esac
  IFS=/ read -r -a segs <<<"$p"
  for seg in "${segs[@]}"; do
    case "$seg" in
      ''|.) ;;
      ..) if [ ${#parts[@]} -gt 0 ] && [ "${parts[-1]}" != .. ]; then unset 'parts[-1]';
          elif [ -z "$lead" ]; then parts+=(..); fi ;;
      *) parts+=("$seg") ;;
    esac
  done
  out="$lead$(IFS=/; printf '%s' "${parts[*]}")"
  [ "$out" = / ] || out="${out%/}"
  [ -n "$out" ] || out=.
  printf '%s\n' "$out"
}

# _hook_norm <path>: lexical resolve, then cygpath -m when present (it cannot convert a path whose ".."
# crosses a missing directory, so ".." goes first), then resolve again for what cygpath produced.
_hook_norm() {
  local p
  p=$(_hook_lex "$1")
  if command -v cygpath >/dev/null 2>&1; then p=$(cygpath -m -- "$p" 2>/dev/null) || p=$(_hook_lex "$1"); fi
  _hook_lex "$p"
}

# hook_under <path> <dir>: exit 0 if path is dir or inside it. Case-insensitive on Windows. Relative paths
# are compared as given: resolve them against HOOK_CWD first if that is what you mean.
hook_under() {
  local p d
  p=$(_hook_norm "$1")
  d=$(_hook_norm "$2")
  case "${OSTYPE:-}" in msys*|cygwin*) p="${p,,}"; d="${d,,}" ;; esac
  [ "$p" = "$d" ] && return 0
  case "$d" in */) [[ "$p" == "$d"* ]]; return ;; esac
  [[ "$p" == "$d/"* ]]
}

# hook_cfg <jq-filter> [default]: read ${DEVFW_CONFIG:-$HOOK_CORE/orchestrator.json}. Prints the value (one
# line per output), else the default. Returns 1 when the file exists but cannot be read, or when
# DEVFW_CONFIG names a missing file (same rule as lib/config.js).
hook_cfg() {
  local file="${DEVFW_CONFIG:-}" v
  if [ -z "$file" ] && [ -n "${HOOK_CORE:-}" ]; then file="$HOOK_CORE/orchestrator.json"; fi
  if [ -n "${DEVFW_CONFIG:-}" ] && [ ! -f "$file" ]; then return 1; fi
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    [ $# -lt 2 ] || printf '%s\n' "$2"
    return 0
  fi
  v=$(jq -r "($1) | if . == null then empty else . end" "$(devfw_path "$file")" 2>/dev/null) || return 1
  v="${v//$'\r'/}"
  if [ -z "$v" ] && [ $# -ge 2 ]; then v="$2"; fi
  [ -z "$v" ] || printf '%s\n' "$v"
}

# hook_managed_repos: plan.repo and every repos.*.github, one per line.
hook_managed_repos() {
  hook_cfg '.plan.repo, ((.repos // {}) | .[] | .github)'
}

# _hook_slug <url>: owner/name for the three GitHub URL forms, else nothing.
_hook_slug() {
  local u="${1%/}"
  u="${u%.git}"
  if [[ "$u" =~ ^https://([^/@]+@)?github\.com/([^/]+)/([^/]+)$ ]]; then
    printf '%s/%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  elif [[ "$u" =~ ^(git@github\.com:|ssh://git@github\.com/)([^/]+)/([^/]+)$ ]]; then
    printf '%s/%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  fi
}

# hook_repo_for_remote <dir> <remote>: the managed owner/name (config spelling) that <remote> of the repo at
# <dir> points to, read from the RAW url (git config, never `git remote get-url`, which applies insteadOf).
# <remote> may also be a URL, as in `git push https://github.com/o/n.git`. Prints nothing when unmanaged.
# No network. Returns 1 only when the config cannot be read.
hook_repo_for_remote() {
  local url slug managed m
  case "$2" in
    *://*|*@*:*) url="$2" ;;
    *) url=$(git -C "$(devfw_path "$1")" config --get "remote.$2.url" 2>/dev/null) || url="" ;;
  esac
  slug=$(_hook_slug "${url//$'\r'/}")
  [ -n "$slug" ] || return 0
  managed=$(hook_managed_repos) || return 1
  while IFS= read -r m; do
    if [ -n "$m" ] && [ "${m,,}" = "${slug,,}" ]; then printf '%s\n' "$m"; return 0; fi
  done <<<"$managed"
  return 0
}

# hook_repo_of <dir>: hook_repo_for_remote <dir> origin.
hook_repo_of() {
  hook_repo_for_remote "$1" origin
}

# hook_claim_ok <repo-dir> <branch> [<remote>]: is <branch> (t/<n>-<slug>) claimed on <remote> (a name or URL; default origin) right now? Fresh reads:
# ls-remote finds the default branch and whether <branch> exists, then one fetch into refs/devfw/claim-check/
# (--no-write-fetch-head: no FETCH_HEAD race; --refmap=: no remote-tracking updates; --no-tags).
# Exit 0 claimed (a commit in base..<branch> carries "Claim-Issue: <n>"), 3 not claimed (no issue number in
# the name, branch missing, or no such trailer), 1 network/git error.
hook_claim_ok() {
  local dir branch="$2" remote="${3:-origin}" n ls base body t="${HOOK_NET_TIMEOUT:-60}"
  dir=$(devfw_path "$1")
  [[ "$branch" =~ ^t/([1-9][0-9]*)- ]] || return 3
  n="${BASH_REMATCH[1]}"
  git check-ref-format "refs/heads/$branch" || return 3
  hook_net ls null "$t" git -C "$dir" ls-remote --symref "$remote" HEAD "refs/heads/$branch" || return 1
  ls="${ls//$'\r'/}"
  base=$(sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]HEAD$#\1#p' <<<"$ls" | head -1)
  [ -n "$base" ] || return 1
  awk -v r="refs/heads/$branch" '$2 == r { f = 1 } END { exit !f }' <<<"$ls" || return 3
  hook_net body null "$t" git -C "$dir" -c gc.auto=0 -c maintenance.auto=false fetch -q --no-tags --no-write-fetch-head \
    --refmap= --no-recurse-submodules "$remote" \
    "+refs/heads/$branch:refs/devfw/claim-check/$branch" "+refs/heads/$base:refs/devfw/claim-check/base" \
    || return 1
  body=$(git -C "$dir" log --format=%B "refs/devfw/claim-check/base..refs/devfw/claim-check/$branch" 2>/dev/null) \
    || return 1
  grep -q "^Claim-Issue: $n\$" <<<"${body//$'\r'/}" && return 0
  return 3
}
