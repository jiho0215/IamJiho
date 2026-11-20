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
# No fork when the dir is already in normal C:/ form (what git passes a shim as $0 under our absolute hooksPath):
# cygpath -m would return it unchanged. Any other form (/c/..., /tmp/..., c:/, C:\, //, /./, /../) goes through
# cygpath as before.
gk_init() {
  GK_HOOK="$1"
  GK_HK="$2"
  case "$2" in
    [A-Z]:/*) case "$2" in *//*|*/./*|*/../*|*/.|*/..|*\\*) _gk_cygpath_hk "$2" ;; esac ;;
    *) _gk_cygpath_hk "$2" ;;
  esac
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
  # = $(tr -d '\r' < managed.tsv), with builtins: every CR dropped, trailing newlines dropped
  GK_MANAGED=""
  IFS= read -r -d '' GK_MANAGED < "$GK_HK/managed.tsv" || true
  GK_MANAGED="${GK_MANAGED//$'\r'/}"
  while [ "${GK_MANAGED%$'\n'}" != "$GK_MANAGED" ]; do GK_MANAGED="${GK_MANAGED%$'\n'}"; done
}
_gk_cygpath_hk() { if command -v cygpath >/dev/null 2>&1; then GK_HK=$(cygpath -m -- "$1" 2>/dev/null) || GK_HK="$1"; fi; }

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
  local name="$1" in="$2"
  shift 2
  _gk_chain_dir "$name"
  _gk_chain_target "$name" || return 0
  local rc=0
  # in a subshell, with the caller's MSYS path-conversion settings restored (dispatch.sh captured them before
  # bin/_lib.sh switched conversion off for our own git.exe calls)
  ( _gk_restore_caller_env; "$GK_CHAIN_DIR/$name" "$@" ) < "$in" || rc=$?
  return "$rc"
}

# _gk_chain_target <hook-name>: 0 when GK_CHAIN_DIR holds a hook to chain: <dir>/<name> is an executable file and
# <dir> is not our own hook dir. Builtins only; tested live on every run (the hook FILE is never cached).
_gk_chain_target() {
  [ -f "$GK_CHAIN_DIR/$1" ] && [ -x "$GK_CHAIN_DIR/$1" ] && [ ! "$GK_CHAIN_DIR" -ef "$GK_HK" ]
}

# _gk_chain_dir <hook-name>: GK_CHAIN_DIR = the repo's own hooks dir: from a valid chain cache entry, else resolved
# through git (_gk_chain_resolve, which blocks when it cannot) and then cached (best effort). The refresh stamp is
# made BEFORE git reads any config, so a config edited while the refresh runs is never cached as unchanged.
_gk_chain_dir() {
  _gk_cache_load && return 0
  local stamp=""
  if [ -n "$GK_CACHE_FILE" ]; then
    [ -d "${GK_CACHE_FILE%/*}" ] || mkdir -p "${GK_CACHE_FILE%/*}" 2>/dev/null
    stamp="$GK_CACHE_FILE.s$$"
    { printf x > "$stamp"; } 2>/dev/null || stamp=""
    GK_CACHE_TMP="$stamp"
  fi
  _gk_chain_resolve "$1"
  [ -z "$stamp" ] || _gk_cache_store "$stamp"
}

# _gk_chain_resolve <hook-name>: GK_CHAIN_DIR resolved through git (the rule described at gk_chain).
_gk_chain_resolve() {
  local name="$1" line scope val hp="" set=0 top dir
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
  GK_CHAIN_DIR="$dir"
}

# --- the chain cache (speed only: a miss, or any doubt, means resolving through git again)
# <state>/git-hooks/.chain/<name> holds what _gk_chain_resolve found for one KEY (the work tree cwd plus every env
# var that changes which repo or which config files git reads), and the config files that decided it:
#   devfw-chain 1
#   key <key>
#   dir <resolved hooks dir>
#   f <path>      a config file git read (or would read): holds while it is a regular file OLDER than this cache file
#   a <path>      a config file git would read that did not exist: holds while it is still absent
#   end
# Another version, another key, a missing dir or end line, or any other line is a miss. <name> comes from the cwd
# and GIT_DIR only, so two keys may share a file; the key line is what decides. Configs that use include.path /
# includeIf (a target can appear later, or depend on the branch) are never cached. Only the hooks DIR is cached:
# <dir>/<hook> is tested on every run.
GK_CACHE_KEY_VARS=(PWD GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM
  HOME XDG_CONFIG_HOME USERPROFILE HOMEDRIVE HOMEPATH GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM)

# _gk_cache_key: GK_CACHE_KEY and GK_CACHE_FILE (empty when there is no state dir). Builtins only.
_gk_cache_key() {
  local v n
  GK_CACHE_KEY="v1"; GK_CACHE_FILE=""
  for v in "${GK_CACHE_KEY_VARS[@]}"; do
    if [ -n "${!v+x}" ]; then GK_CACHE_KEY+=$'\037'"$v=${!v}"; else GK_CACHE_KEY+=$'\037'"$v"; fi
  done
  GK_CACHE_KEY+=$'\037'
  [ -n "${GK_STATE:-}" ] || return 0
  n="$PWD|${GIT_DIR-}"; n="${n//[^A-Za-z0-9._-]/_}"
  [ "${#n}" -le 100 ] || n="${n: -100}"
  GK_CACHE_FILE="$GK_STATE/git-hooks/.chain/$n"
}

# _gk_cache_load: 0 and GK_CHAIN_DIR when the cache entry for this key holds (see the format above). Builtins only.
_gk_cache_load() {
  _gk_cache_key
  local c="$GK_CACHE_FILE" line n=0 dir="" done=0
  [ -n "$c" ] && [ -f "$c" ] || return 1
  while IFS= read -r line; do
    n=$((n + 1))
    case "$n:$line" in
      1:"devfw-chain 1") ;;
      2:"key $GK_CACHE_KEY") ;;
      3:"dir "?*) dir="${line#dir }" ;;
      [12]:*|3:*) return 1 ;;
      *:"f "?*) [ -f "${line#f }" ] && [ "$c" -nt "${line#f }" ] || return 1 ;;
      *:"a "?*) [ ! -e "${line#a }" ] && [ ! -L "${line#a }" ] || return 1 ;;
      *:end) done=1; break ;;
      *) return 1 ;;
    esac
  done < "$c"
  [ "$done" = 1 ] || return 1
  GK_CHAIN_DIR="$dir"
}

# _gk_cache_store <stamp>: write the cache entry for GK_CACHE_KEY -> GK_CHAIN_DIR, best effort; <stamp> was written
# before the resolution read any config. Not stored (silently; the next run resolves again) when: a config uses an
# include, a config file origin is not a plain file path, a path or the key has a newline, or a watched file is not
# older than <stamp> (it may have changed while git read it). Written to a temp file and renamed into place.
_gk_cache_store() {
  local stamp="$1" out line scope origin key p tmp="$GK_CACHE_FILE.t$$"
  local -a fs=() as=() cand=()
  [[ "$GK_CACHE_KEY$GK_CHAIN_DIR" != *$'\n'* ]] || return 0
  out=$(git config --list --show-origin --show-scope --name-only 2>/dev/null) || return 0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    scope="${line%%$'\t'*}"; line="${line#*$'\t'}"; origin="${line%%$'\t'*}"; key="${line#*$'\t'}"
    [ "$scope" != command ] || continue
    case "${key,,}" in include.*|includeif.*) return 0 ;; esac
    case "$origin" in
      file:\"*) return 0 ;;
      file:?*) cand+=("${origin#file:}") ;;
      *) return 0 ;;
    esac
  done <<<"$out"
  out=$(git var -l 2>/dev/null) || return 0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in GIT_CONFIG_SYSTEM=?*|GIT_CONFIG_GLOBAL=?*) cand+=("${line#*=}") ;; esac
  done <<<"$out"
  out=$(git rev-parse --path-format=absolute --git-common-dir --git-dir 2>/dev/null) || return 0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [ -z "$line" ] || cand+=("$line/config" "$line/config.worktree")
  done <<<"$out"
  # (show-origin may print a path relative to the cwd, `.git/config`; the cwd is part of the key, so it stays valid)
  for p in "${cand[@]}"; do
    [[ "$p" != *$'\n'* ]] || return 0
    if [ -e "$p" ] || [ -L "$p" ]; then
      [ -f "$p" ] || return 0
      fs+=("$p")
    else
      as+=("$p")
    fi
  done
  {
    printf 'devfw-chain 1\nkey %s\ndir %s\n' "$GK_CACHE_KEY" "$GK_CHAIN_DIR"
    [ "${#fs[@]}" -eq 0 ] || printf 'f %s\n' "${fs[@]}"
    [ "${#as[@]}" -eq 0 ] || printf 'a %s\n' "${as[@]}"
    printf 'end\n'
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" "$stamp" 2>/dev/null; return 0; }
  # after the entry is written: every watched file still older than the stamp, every absent one still absent
  local okk=1
  for p in "${fs[@]}"; do [ "$stamp" -nt "$p" ] || { okk=0; break; }; done
  for p in "${as[@]}"; do [ ! -e "$p" ] && [ ! -L "$p" ] || { okk=0; break; }; done
  if [ "$okk" = 1 ]; then mv -f "$tmp" "$GK_CACHE_FILE" 2>/dev/null; fi
  rm -f "$tmp" "$stamp" 2>/dev/null
  return 0
}

# --- the fast path
# gk_stdin_take <max-lines>: read git's stdin (fd 0) into GK_STDIN_DATA with builtins, at most <max-lines> lines;
# GK_STDIN_EOF=1 when that was all of it. Bash reads a pipe one byte at a time, so exactly the bytes in
# GK_STDIN_DATA were consumed and the full path appends the rest with cat (byte-exact for text; git's hook input
# holds no NUL). Sets GK_STDIN_TAKEN=1.
gk_stdin_take() {
  local max="$1" n=0 line
  GK_STDIN_DATA=""; GK_STDIN_EOF=0; GK_STDIN_TAKEN=1
  if [ -t 0 ]; then GK_STDIN_EOF=1; return 0; fi
  while [ "$n" -lt "$max" ]; do
    if IFS= read -r line; then
      GK_STDIN_DATA+="$line"$'\n'; n=$((n + 1))
    else
      GK_STDIN_DATA+="$line"; GK_STDIN_EOF=1; return 0
    fi
  done
  return 0
}

# gk_fast <hook args...>: 0 when this run provably has nothing to do, so the dispatcher may exit 0 at once:
#   1 the chain: the repo's hooks dir comes from a valid cache entry (a miss -> full path, which refreshes it),
#   2 and it holds no hook to chain (_gk_chain_target, tested live),
#   3 and the rule has nothing to check: no rules file for this hook, or its <fn>_idle <hook args...> returns 0.
#     A rules file without <fn>_idle always runs (fail closed).
# Else 1, with GK_FAST_WHY = "cache miss" | "chain" | "rule". Never forks. A <fn>_idle that needs stdin reads it
# through gk_stdin_take only, so the full path still gets all of it.
gk_fast() {
  GK_STDIN_TAKEN=0; GK_STDIN_DATA=""; GK_STDIN_EOF=0; GK_FAST_WHY=""
  _gk_cache_load || { GK_FAST_WHY="cache miss"; return 1; }
  ! _gk_chain_target "$GK_NAME" || { GK_FAST_WHY="chain"; return 1; }
  [ -n "${GK_RULE_FN:-}" ] || return 0
  declare -F "${GK_RULE_FN}_idle" >/dev/null || { GK_FAST_WHY="rule"; return 1; }
  "${GK_RULE_FN}_idle" "$@" || { GK_FAST_WHY="rule"; return 1; }
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
