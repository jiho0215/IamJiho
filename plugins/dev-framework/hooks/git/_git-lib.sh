#!/bin/bash
# Shared library of the dev-framework git hooks. Sourced by hooks/git/dispatch.sh after bin/_lib.sh and
# bin/_scope.sh; do not execute it.
#
# The hook dir (<state>/git-hooks/<hash>/, written by bin/git-hooks install) holds the shims plus:
#   scope.env    fixed KEY=value lines (DEVFW_HK_*), read line by line here, never sourced;
#   managed.tsv  <lowercase owner/name> TAB <default branch> TAB <merge method>, one line per managed repo.
# A git hook blocks by exiting non-zero: gk_block prints "devfw <hook>: <reason>" and exits 1.

# gk_init <hook-name> <hooks-dir>: set GK_HOOK, GK_HK (the hook dir, cygpath -m form), the GK_* values of scope.env,
# GK_MANAGED (the managed.tsv text) and GK_SESSION (DEVFW_SESSION_ID when it is a valid id, else empty).
# A hook dir without a readable scope.env or managed.tsv is a broken install: it blocks.
gk_init() {
  GK_HOOK="$1"
  GK_HK="$2"
  if command -v cygpath >/dev/null 2>&1; then GK_HK=$(cygpath -m -- "$2" 2>/dev/null) || GK_HK="$2"; fi
  GK_CORE=""; GK_CONFIG=""; GK_CONFIG_HASH=""; GK_PLAN_REPO=""; GK_PLAN_PATH=""; GK_PLAN_BRANCH=""
  GK_ALLOW_FORCE=""; GK_STATE=""; GK_BIN=""; GK_MANAGED=""
  GK_SESSION=""
  if [[ "${DEVFW_SESSION_ID:-}" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then GK_SESSION="$DEVFW_SESSION_ID"; fi
  [ -f "$GK_HK/scope.env" ] && [ -f "$GK_HK/managed.tsv" ] \
    || gk_block "the git-hook install at $GK_HK is broken (scope.env or managed.tsv missing); start a new session"
  local line k v
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      DEVFW_HK_CORE) GK_CORE="$v" ;;
      DEVFW_HK_CONFIG) GK_CONFIG="$v" ;;
      DEVFW_HK_CONFIG_HASH) GK_CONFIG_HASH="$v" ;;
      DEVFW_HK_PLAN_REPO) GK_PLAN_REPO="$v" ;;
      DEVFW_HK_PLAN_PATH) GK_PLAN_PATH="$v" ;;
      DEVFW_HK_PLAN_BRANCH) GK_PLAN_BRANCH="$v" ;;
      DEVFW_HK_ALLOW_FORCE) GK_ALLOW_FORCE="$v" ;;
      DEVFW_HK_STATE) GK_STATE="$v" ;;
      DEVFW_HK_BIN) GK_BIN="$v" ;;
    esac
  done < "$GK_HK/scope.env"
  GK_MANAGED=$(tr -d '\r' < "$GK_HK/managed.tsv")
}

# gk_block <reason> [<repo> [<ref>]]: stderr "devfw <hook>: <reason>", one JSON row appended to
# <state>/shadow/new.jsonl (best effort), exit 1. Never call it inside $( ... ).
gk_block() {
  echo "devfw ${GK_HOOK:-git-hook}: $1" >&2
  if [ -n "${GK_STATE:-}" ]; then
    {
      mkdir -p "$GK_STATE/shadow" &&
        jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg session "${GK_SESSION:-}" --arg hook "${GK_HOOK:-}" \
          --arg reason "$1" --arg repo "${2:-}" --arg ref "${3:-}" \
          '{at:$at, session:$session, hook:$hook, reason:$reason, repo:$repo, ref:$ref}' \
          | tr -d '\r' >> "$GK_STATE/shadow/new.jsonl"
    } >/dev/null 2>&1 || true
  fi
  exit 1
}

# gk_managed <url-or-empty>...: the managed slug (lowercase owner/name, as in managed.tsv) that the first matching
# argument names, else nothing. No network.
gk_managed() {
  local a s
  for a in "$@"; do
    [ -n "$a" ] || continue
    s=$(scope_slug "${a//$'\r'/}")
    [ -n "$s" ] || continue
    s="${s,,}"
    if [ -n "$(awk -F'\t' -v s="$s" '$1 == s { print; exit }' <<<"$GK_MANAGED")" ]; then
      printf '%s\n' "$s"; return 0
    fi
  done
  return 0
}

# gk_default_of <slug>: that managed repo's default branch (managed.tsv), else main.
gk_default_of() {
  local d
  d=$(awk -F'\t' -v s="${1,,}" '$1 == s { print $2; exit }' <<<"$GK_MANAGED")
  printf '%s\n' "${d:-main}"
}

# gk_latched: 0 when this session is latched (<state>/latch/<session> exists). No session is never latched.
gk_latched() {
  [ -n "${GK_SESSION:-}" ] && [ -n "${GK_STATE:-}" ] && [ -e "$GK_STATE/latch/$GK_SESSION" ]
}

# gk_net <outvar> <seconds> <cmd...>: run <cmd...> under `timeout <seconds>`; its stdout goes to the variable
# <outvar> in the caller's shell, its stderr to GK_NET_ERR; returns the command's exit code (124 on a timeout).
# A missing `timeout` binary blocks. Output goes through temp files, not a $( ... ) pipe, so a grandchild holding
# stdout cannot keep the hook waiting. Never call it inside $( ... ).
gk_net() {
  local __gn_v="$1" __gn_t="$2" __gn_o __gn_e __gn_rc=0
  shift 2
  command -v timeout >/dev/null 2>&1 || gk_block "timeout not found (needed to bound network calls); install coreutils"
  __gn_o=$(mktemp 2>/dev/null) || { printf -v "$__gn_v" '%s' ""; GK_NET_ERR="mktemp failed"; return 125; }
  __gn_e=$(mktemp 2>/dev/null) || { rm -f "$__gn_o"; printf -v "$__gn_v" '%s' ""; GK_NET_ERR="mktemp failed"; return 125; }
  timeout "$__gn_t" "$@" >"$__gn_o" 2>"$__gn_e" || __gn_rc=$?
  printf -v "$__gn_v" '%s' "$(cat "$__gn_o" 2>/dev/null)"
  GK_NET_ERR=$(tr -d '\r' < "$__gn_e" 2>/dev/null) || GK_NET_ERR=""
  rm -f "$__gn_o" "$__gn_e" 2>/dev/null || true
  return "$__gn_rc"
}

# scope_net for bin/_scope.sh: gk_net with the constant per-call bound of the git hooks (20 s; not an env knob).
scope_net() { gk_net "$1" 20 "${@:3}"; }

# gk_chain <hook-name> <stdin-file> <args...>: run the hook git would have run without us (same args, same stdin),
# return its exit code. The repo's own hooks dir: the last core.hooksPath value whose scope is not `command` (ours
# is delivered in the command scope), a relative one resolved against the work tree top (git's own rule: relative
# to where hooks run); else <git common dir>/hooks. Returns 0 without running anything when that file is missing or
# not executable, or when its dir is our own hook dir (compared with -ef, never as strings: a hook's pwd prints
# /c/... while GK_HK is C:/...).
gk_chain() {
  local name="$1" in="$2" line scope val hp="" set=0 top dir
  shift 2
  while IFS= read -r line; do
    line="${line%$'\r'}"
    scope="${line%%$'\t'*}"; val="${line#*$'\t'}"
    [ "$scope" != command ] || continue
    hp="$val"; set=1
  done < <(git config --show-scope --type=path --get-all core.hooksPath 2>/dev/null)
  if [ "$set" -eq 1 ] && [ -n "$hp" ]; then
    case "$hp" in
      /*|[A-Za-z]:[/\\]*|\\\\*) dir="$hp" ;;
      *)
        top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$(git rev-parse --absolute-git-dir 2>/dev/null) \
          || gk_block "cannot find this repo's work tree to run its own $name hook"
        dir="${top%$'\r'}/$hp" ;;
    esac
  else
    top=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
      || gk_block "cannot find this repo's git dir to run its own $name hook"
    dir="${top%$'\r'}/hooks"
  fi
  [ -f "$dir/$name" ] && [ -x "$dir/$name" ] || return 0
  [ ! "$dir" -ef "$GK_HK" ] || return 0
  local rc=0
  # in a subshell, with the caller's MSYS path-conversion settings restored (dispatch.sh captured them before
  # bin/_lib.sh switched conversion off for our own git.exe calls)
  ( _gk_restore_caller_env; "$dir/$name" "$@" ) < "$in" || rc=$?
  return "$rc"
}

# _gk_restore_caller_env: MSYS_NO_PATHCONV and MSYS2_ARG_CONV_EXCL back to the caller's values from
# GK_CALLER_<var> ("unset" or "set:<value>"); a variable with no captured value is left as it is.
_gk_restore_caller_env() {
  local v c
  for v in MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL; do
    c="GK_CALLER_$v"; c="${!c-}"
    case "$c" in
      unset) unset "$v" ;;
      set:*) export "$v=${c#set:}" ;;
    esac
  done
}
