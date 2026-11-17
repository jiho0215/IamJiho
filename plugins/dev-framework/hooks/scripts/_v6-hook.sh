#!/bin/bash
# Shared library for dev-framework v6 guard hooks. Source it; do not execute it.
#
# Shape of a guard:  hook_init <name>  ->  decide scope (no network, nothing that can fail; out of scope
# -> exit 0)  ->  hook_fail_closed  ->  checks, each failure ending in hook_block.
# Never call hook_block inside $( ... ): exit would leave only the subshell.

HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# devfw_path, devfw_require; also exports MSYS_NO_PATHCONV for Git Bash.
. "$HOOK_LIB_DIR/../../bin/_lib.sh"

# hook_init <hook-name>: read the hook's stdin JSON once. Empty or non-JSON stdin leaves every field empty;
# the caller decides what that means for scope.
hook_init() {
  HOOK_NAME="$1"
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
  echo "devfw ${HOOK_NAME:-hook}: $1" >&2
  shift
  local l
  for l in "$@"; do echo "$l" >&2; done
  exit 2
}

# hook_fail_closed: from here on, any failing command, and any exit other than 0 or 2 (an unbound variable,
# a stray `exit 1`), blocks. Call it only after the scope decision.
hook_fail_closed() {
  set -o errtrace -o pipefail
  trap 'hook_block "internal error at line $LINENO"' ERR
  trap '_hook_exit_guard $?' EXIT
}
_hook_exit_guard() {
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

# hook_claim_ok <repo-dir> <branch>: is <branch> (t/<n>-<slug>) claimed on origin right now? Fresh reads:
# ls-remote finds the default branch and whether <branch> exists, then one fetch into refs/devfw/claim-check/
# (--no-write-fetch-head: no FETCH_HEAD race; --refmap=: no remote-tracking updates; --no-tags).
# Exit 0 claimed (a commit in base..<branch> carries "Claim-Issue: <n>"), 3 not claimed (no issue number in
# the name, branch missing, or no such trailer), 1 network/git error.
hook_claim_ok() {
  local dir branch="$2" n ls base body t="${HOOK_NET_TIMEOUT:-60}"
  dir=$(devfw_path "$1")
  [[ "$branch" =~ ^t/([1-9][0-9]*)- ]] || return 3
  n="${BASH_REMATCH[1]}"
  git check-ref-format "refs/heads/$branch" || return 3
  ls=$(timeout "$t" git -C "$dir" ls-remote --symref origin HEAD "refs/heads/$branch" 2>/dev/null) || return 1
  ls="${ls//$'\r'/}"
  base=$(sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]HEAD$#\1#p' <<<"$ls" | head -1)
  [ -n "$base" ] || return 1
  awk -v r="refs/heads/$branch" '$2 == r { f = 1 } END { exit !f }' <<<"$ls" || return 3
  timeout "$t" git -C "$dir" -c gc.auto=0 -c maintenance.auto=false fetch -q --no-tags --no-write-fetch-head \
    --refmap= --no-recurse-submodules origin \
    "+refs/heads/$branch:refs/devfw/claim-check/$branch" "+refs/heads/$base:refs/devfw/claim-check/base" \
    2>/dev/null || return 1
  body=$(git -C "$dir" log --format=%B "refs/devfw/claim-check/base..refs/devfw/claim-check/$branch" 2>/dev/null) \
    || return 1
  grep -q "^Claim-Issue: $n\$" <<<"${body//$'\r'/}" && return 0
  return 3
}
