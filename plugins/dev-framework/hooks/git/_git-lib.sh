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
# through git (_gk_chain_resolve, which blocks when it cannot) and then cached (best effort). A refresh runs in this
# order: stamp, watch list (_gk_cache_watch), resolve, write, recheck (_gk_cache_store). Every config file the resolver
# could have read is therefore on the watch list before it reads, and the recheck after it refuses the entry when
# any of them was edited (not older than the stamp), deleted or replaced (no longer a regular file), or created (an
# absent one now exists) while the refresh ran.
_gk_chain_dir() {
  _gk_cache_load && return 0
  local stamp="" watched=0
  if [ -n "$GK_CACHE_FILE" ]; then
    [ -d "${GK_CACHE_FILE%/*}" ] || mkdir -p "${GK_CACHE_FILE%/*}" 2>/dev/null
    stamp="$GK_CACHE_FILE.s$$"
    { printf x > "$stamp"; } 2>/dev/null || stamp=""
    GK_CACHE_TMP="$stamp"
  fi
  [ -z "$stamp" ] || ! _gk_cache_watch || watched=1
  _gk_chain_resolve "$1"
  [ "$watched" = 0 ] || _gk_cache_store "$stamp"
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
# On success also GK_CACHE_OK=1 and GK_CACHE_WATCHED = the entry's `f` files: every non-command config file git
# reads for this key (an entry is never written for a config that uses an include), which a rule's <fn>_idle may
# scan (_gk_config_may_name).
_gk_cache_load() {
  _gk_cache_key
  GK_CACHE_OK=0; GK_CACHE_WATCHED=()
  local c="$GK_CACHE_FILE" line n=0 dir="" done=0
  [ -n "$c" ] && [ -f "$c" ] || return 1
  while IFS= read -r line; do
    n=$((n + 1))
    case "$n:$line" in
      1:"devfw-chain 1") ;;
      2:"key $GK_CACHE_KEY") ;;
      3:"dir "?*) dir="${line#dir }" ;;
      [12]:*|3:*) return 1 ;;
      *:"f "?*) [ -f "${line#f }" ] && [ "$c" -nt "${line#f }" ] || return 1; GK_CACHE_WATCHED+=("${line#f }") ;;
      *:"a "?*) [ ! -e "${line#a }" ] && [ ! -L "${line#a }" ] || return 1 ;;
      *:end) done=1; break ;;
      *) return 1 ;;
    esac
  done < "$c"
  [ "$done" = 1 ] || return 1
  GK_CHAIN_DIR="$dir"
  GK_CACHE_OK=1
}

# _gk_cache_watch: the watch list, collected BEFORE the resolver reads config: GK_WATCH_F (config files that exist,
# each a regular file) and GK_WATCH_A (config files git would read that are absent). 1 (do not cache) when a config
# uses an include, a config file origin is not a plain file path, a path or the key has a newline, an existing path
# is not a regular file, or git cannot list them.
_gk_cache_watch() {
  local out line scope origin key p
  local -a cand=()
  GK_WATCH_F=(); GK_WATCH_A=()
  [[ "$GK_CACHE_KEY" != *$'\n'* ]] || return 1
  out=$(git config --list --show-origin --show-scope --name-only 2>/dev/null) || return 1
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    scope="${line%%$'\t'*}"; line="${line#*$'\t'}"; origin="${line%%$'\t'*}"; key="${line#*$'\t'}"
    [ "$scope" != command ] || continue
    case "${key,,}" in include.*|includeif.*) return 1 ;; esac
    case "$origin" in
      file:\"*) return 1 ;;
      file:?*) cand+=("${origin#file:}") ;;
      *) return 1 ;;
    esac
  done <<<"$out"
  out=$(git var -l 2>/dev/null) || return 1
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in GIT_CONFIG_SYSTEM=?*|GIT_CONFIG_GLOBAL=?*) cand+=("${line#*=}") ;; esac
  done <<<"$out"
  out=$(git rev-parse --path-format=absolute --git-common-dir --git-dir 2>/dev/null) || return 1
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [ -z "$line" ] || cand+=("$line/config" "$line/config.worktree")
  done <<<"$out"
  # (show-origin may print a path relative to the cwd, `.git/config`; the cwd is part of the key, so it stays valid)
  for p in "${cand[@]}"; do
    [[ "$p" != *$'\n'* ]] || return 1
    if [ -e "$p" ] || [ -L "$p" ]; then
      [ -f "$p" ] || return 1
      GK_WATCH_F+=("$p")
    else
      GK_WATCH_A+=("$p")
    fi
  done
  return 0
}

# _gk_cache_store <stamp>: write the entry GK_CACHE_KEY -> GK_CHAIN_DIR with the watch list _gk_cache_watch took
# before the resolver ran, best effort; <stamp> was written before both. The entry is renamed into place only when,
# AFTER it is written, every GK_WATCH_F file is still a regular file older than <stamp> (`-nt` alone is true for a
# missing file, so the -f is what catches a deletion) and every GK_WATCH_A path is still absent. Else nothing is
# stored and the next run resolves again.
_gk_cache_store() {
  local stamp="$1" p tmp="$GK_CACHE_FILE.t$$"
  [[ "$GK_CHAIN_DIR" != *$'\n'* ]] || return 0
  {
    printf 'devfw-chain 1\nkey %s\ndir %s\n' "$GK_CACHE_KEY" "$GK_CHAIN_DIR"
    [ "${#GK_WATCH_F[@]}" -eq 0 ] || printf 'f %s\n' "${GK_WATCH_F[@]}"
    [ "${#GK_WATCH_A[@]}" -eq 0 ] || printf 'a %s\n' "${GK_WATCH_A[@]}"
    printf 'end\n'
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" "$stamp" 2>/dev/null; return 0; }
  local okk=1
  for p in "${GK_WATCH_F[@]}"; do [ -f "$p" ] && [ "$stamp" -nt "$p" ] || { okk=0; break; }; done
  for p in "${GK_WATCH_A[@]}"; do [ ! -e "$p" ] && [ ! -L "$p" ] || { okk=0; break; }; done
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

# _gk_config_may_name <lowercase text>: 0 when <text> may appear in a config value git reads for this repo, so
# "some remote URL names <text>" cannot be ruled out; 1 only when it provably does not. The haystack: the command
# scope (GIT_CONFIG_PARAMETERS and every GIT_CONFIG_VALUE_<i> below GIT_CONFIG_COUNT) and every file of the valid
# chain-cache entry (GK_CACHE_WATCHED, set by _gk_cache_load), compared case-insensitively with backslash-newline
# continuations joined. Without a valid entry (GK_CACHE_OK != 1), an empty <text>, or a malformed GIT_CONFIG_COUNT,
# it answers 0. Builtins only (for a rule's <fn>_idle).
_gk_config_may_name() {
  local want="${1,,}" f txt i v
  [ -n "$want" ] && [ "${GK_CACHE_OK:-0}" = 1 ] || return 0
  txt="${GIT_CONFIG_PARAMETERS-}"; [[ "${txt,,}" != *"$want"* ]] || return 0
  if [ -n "${GIT_CONFIG_COUNT-}" ]; then
    [[ "$GIT_CONFIG_COUNT" =~ ^[0-9]{1,4}$ ]] || return 0
    for ((i = 0; i < GIT_CONFIG_COUNT; i++)); do
      v="GIT_CONFIG_VALUE_$i"; txt="${!v-}"
      [[ "${txt,,}" != *"$want"* ]] || return 0
    done
  fi
  for f in "${GK_CACHE_WATCHED[@]}"; do
    txt=""
    [ -f "$f" ] || return 0
    IFS= read -r -d '' txt < "$f" || true
    txt="${txt//$'\r'/}"; txt="${txt//\\$'\n'/}"
    [[ "${txt,,}" != *"$want"* ]] || return 0
  done
  return 1
}

# _gk_head_ref: GK_HEAD_REF = the ref HEAD points at (refs/heads/<branch>), or "" for a detached HEAD, read from
# <git dir>/HEAD with builtins. The git dir: GIT_DIR (git exports it to hooks in a linked worktree), else $PWD/.git
# (a hook's cwd is the work tree top), following a `gitdir: <path>` file. 1 when it cannot be decided this way: no git
# dir found, no readable HEAD, a reftable repo (its HEAD file holds the placeholder `ref: refs/heads/.invalid`), or
# any other content; the caller then asks git (or, in an <fn>_idle, takes the full path).
_gk_head_ref() {
  local gd="${GIT_DIR-}" line=""
  GK_HEAD_REF=""
  if [ -z "$gd" ]; then
    gd="$PWD/.git"
    if [ -f "$gd" ]; then
      IFS= read -r line < "$gd" || [ -n "$line" ] || return 1
      line="${line%$'\r'}"
      case "$line" in "gitdir: "?*) gd="${line#gitdir: }" ;; *) return 1 ;; esac
    fi
  fi
  case "$gd" in /*|[A-Za-z]:/*) ;; *) gd="$PWD/$gd" ;; esac
  [ -f "$gd/HEAD" ] || return 1
  line=""
  IFS= read -r line < "$gd/HEAD" || [ -n "$line" ] || return 1
  line="${line%$'\r'}"
  case "$line" in
    "ref: refs/heads/.invalid") return 1 ;;
    "ref: refs/heads/"?*) GK_HEAD_REF="${line#ref: }" ;;
    *) [[ "$line" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1 ;;
  esac
  return 0
}

# gk_managed_remotes: GK_MREMOTES = the remotes whose raw URL (remote.<r>.url, never the insteadOf result) is managed,
# in config order; GK_MSLUG = the first one's slug (for block rows). A remote name is the key minus `remote.` and
# `.url`, so a name with dots works. One git call (plus gk_managed per remote).
gk_managed_remotes() {
  local line key url r u
  GK_MREMOTES=(); GK_MSLUG=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    key="${line%% *}"; url="${line#* }"
    r="${key#remote.}"; r="${r%.url}"
    u=$(gk_managed "$url")
    [ -n "$u" ] || continue
    GK_MREMOTES+=("$r")
    [ -n "$GK_MSLUG" ] || GK_MSLUG="$u"
  done < <(git config --get-regexp '^remote\..*\.url$' 2>/dev/null)
  return 0
}

# gk_t_evidence <ref> <slug> [<tracking ref created or updated by the same transaction>...]: the LOCAL claim evidence
# for the local branch <ref> = refs/heads/t/... (GK_MREMOTES set by gk_managed_remotes, non-empty). No network.
#   - a t/ name must be all lowercase (bin/claim's slugs always are; on a case-insensitive file system a loose
#     tracking ref also matches a case variant, so an upper-case name could borrow another slug's evidence);
#   - a t/ branch with no issue number is not a ticket branch: 0;
#   - t/<n>-<slug>: 0 when some managed remote <r> has refs/remotes/<r>/t/<n>-<slug>, or it is one of the extra args;
#     else blocks: "issue <n> is claimed as t/<n>-<other>" when a managed remote holds another slug for <n>, otherwise
#     "no claim for issue <n> (no <r>/<branch>); run bin/claim, then git fetch <r> +refs/heads/<branch>:refs/remotes/<r>/<branch>"
#     with <r> = the first managed remote.
# Shared by reference-transaction (a branch being created) and pre-commit (the current branch).
gk_t_evidence() {
  local ref="$1" slug="$2" b n r t u other
  shift 2
  b="${ref#refs/heads/}"
  [ "$b" = "${b,,}" ] || gk_block "branch names under t/ must be lowercase ($b); use ${b,,}" "$slug" "$ref"
  [[ "$b" =~ ^t/([1-9][0-9]*)- ]] || return 0
  n="${BASH_REMATCH[1]}"
  for r in "${GK_MREMOTES[@]}"; do
    t="refs/remotes/$r/$b"
    if git show-ref --verify -q "$t" 2>/dev/null; then return 0; fi
    for u in "$@"; do
      [ "$u" != "$t" ] || return 0
    done
  done
  other=""
  for r in "${GK_MREMOTES[@]}"; do
    other=$(git for-each-ref --count=1 --format='%(refname)' "refs/remotes/$r/t/$n-*" 2>/dev/null | tr -d '\r')
    [ -z "$other" ] || { other="${other#refs/remotes/$r/}"; break; }
  done
  [ -z "$other" ] || gk_block "issue $n is claimed as $other" "$slug" "$ref"
  r="${GK_MREMOTES[0]}"
  gk_block "no claim for issue $n (no $r/$b); run bin/claim, then git fetch $r +refs/heads/$b:refs/remotes/$r/$b" "$slug" "$ref"
}

# gk_lease_check <reason prefix> <slug> <ref>: `bin/lease check --core-dir GK_CORE` (it fetches the plan branch, so
# through gk_net), run with the git env that locates the CURRENT repo removed (git exports GIT_DIR in a linked worktree
# and GIT_INDEX_FILE always; lease must read the core clone, not this repo). 0 when it passes; else blocks with
# <prefix> + by lease's exit code: 4 "only the lease holder commits plan changes: <lease's first stderr line>",
# 3 "no lease: <line>", any other "cannot verify the lease (lease exit <rc>: <line>)".
gk_lease_check() {
  local pre="$1" slug="$2" ref="$3" out rc=0 err
  local -a iso=(-u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_OBJECT_DIRECTORY
                -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_PREFIX)
  gk_net out 20 env "${iso[@]}" "$GK_BIN/lease" check --core-dir "$GK_CORE" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  err="${GK_NET_ERR%%$'\n'*}"
  case "$rc" in
    4) gk_block "${pre}only the lease holder commits plan changes: $err" "$slug" "$ref" ;;
    3) gk_block "${pre}no lease: $err" "$slug" "$ref" ;;
    *) gk_block "${pre}cannot verify the lease (lease exit $rc: $err)" "$slug" "$ref" ;;
  esac
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
