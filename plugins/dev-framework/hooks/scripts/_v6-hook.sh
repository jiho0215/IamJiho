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
  # stdout goes to a temp FILE, not a $( ... ) pipe: a pipe is read until EOF, so a grandchild that outlives the
  # command (a background helper, a native process a Windows timeout cannot kill) holding stdout would keep the
  # hook waiting past the deadline. Waiting on `timeout` alone ends at the deadline.
  local __hn_f
  __hn_f=$(mktemp 2>/dev/null) || { printf -v "$__hn_v" '%s' ""; return 125; }
  case "$__hn_e" in
    null)  timeout "$__hn_s" "$@" >"$__hn_f" 2>/dev/null || __hn_rc=$? ;;
    merge) timeout "$__hn_s" "$@" >"$__hn_f" 2>&1 || __hn_rc=$? ;;
    *)     timeout "$__hn_s" "$@" >"$__hn_f" 2>"$__hn_e" || __hn_rc=$? ;;
  esac
  __hn_o=$(cat "$__hn_f" 2>/dev/null) || __hn_o=""
  rm -f "$__hn_f" 2>/dev/null || true
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
  # A missing jq never blocks here, before scope (ruling R24): each hook calls hook_need_jq with its own tokens.
  HOOK_HAVE_JQ=1
  command -v jq >/dev/null 2>&1 || HOOK_HAVE_JQ=0
  # the parser reads a leading ~ / $HOME as this literal path (ruling R20)
  if [ -n "${HOME:-}" ]; then DEVFW_PARSE_HOME=$(devfw_path "$HOME" 2>/dev/null) || DEVFW_PARSE_HOME=""; export DEVFW_PARSE_HOME; fi
  HOOK_TOOL=$(hook_field .tool_name)
  HOOK_CWD=$(hook_field .cwd)
  HOOK_AGENT_ID=$(hook_field .agent_id)
}

# hook_need_jq <ERE>: ruling R24. With jq present, returns. Without jq: if the RAW hook input matches <ERE> (the
# hook's guarded tokens), blocks "jq not found"; otherwise exits 0 (not this hook's business). Call it right after
# the DEVFW_CORE_DIR check, before anything that reads a field (fields read as empty without jq).
hook_need_jq() {
  [ "$HOOK_HAVE_JQ" -eq 0 ] || return 0
  grep -Eiq -- "$1" <<<"${HOOK_JSON:-}" || exit 0   # -i: GIT PUSH (R27)
  hook_block "jq not found (needed to read this command and the config); install jq or run it without the dev-framework hooks"
}

# hook_raw_str <key>: the first "<key>":"<string>" of the RAW hook input, JSON escapes \\ and \" undone. For the
# jq-missing path only (R24); anything else uses hook_field.
hook_raw_str() {
  local v
  v=$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\(\([^\"\\\\]\|\\\\.\)*\)\".*/\1/p" <<<"${HOOK_JSON:-}" | head -1)
  v="${v//\\\\/$'\001'}"; v="${v//\\\"/\"}"; v="${v//$'\001'/\\}"
  printf '%s\n' "$v"
}

# hook_abs <path> [<base>]: <path> made absolute against <base> (default HOOK_CWD) when relative: /x, C:x, \x and
# \\server\share are absolute. With no base, prints <path> as given.
hook_abs() {
  local b="${2-${HOOK_CWD:-}}"
  case "$1" in
    /*|[A-Za-z]:*|\\*) printf '%s\n' "$1" ;;
    *) if [ -n "$b" ]; then printf '%s/%s\n' "$b" "$1"; else printf '%s\n' "$1"; fi ;;
  esac
}

# hook_parse <command>: sets PARSED to lib/hook-cmd.js's JSON for <command>, or empty when the parser fails.
hook_parse() {
  PARSED=$(node "$(devfw_path "$HOOK_LIB_DIR/../../bin/hook-parse")" <<<"$1" | tr -d '\r') || PARSED=""
  if [ -n "$PARSED" ] && ! jq -e . >/dev/null 2>&1 <<<"$PARSED"; then PARSED=""; fi
}

# hook_opaque_rows <jq-regex> [<alias-regex>]: rulings R20/R25/R35, the ONE place opaque scope facts are read. From
# $PARSED, every opaque segment matching <jq-regex> (case-insensitive; R33: as a whole word) or flagged `any` (R30: an alias defined by
# injected config, whose expansion the hook cannot read), plus every git/gh alias call whose
# expansion matches <alias-regex> (default: <jq-regex>), becomes a row "<unknown 0|1><TAB><dir>" in the array HOOK_OPQ_ROWS (dir empty = the hook cwd). Scope pass: no
# network (git config / gh alias list are local; gh is bounded by hook_net). An alias of a dir the parser cannot
# read is looked up from the hook cwd (global aliases). A failing `gh alias list` makes each gh alias call a row of
# kind 2 ("2<TAB>": unresolved), in scope only when the hook cwd is (R25). Never call it inside $( ... ).
# R29: an alias is followed step by step (repo config then global for git; `gh alias list` for gh), at most 10
# steps. The call is a row when any step's expansion starts with `!` (a shell command), matches <alias-regex>,
# starts with an option, or names a next word that is neither an alias nor a command (parser's gitCommands /
# ghCommands), or when the chain is longer than 10. A name that is no alias at its FIRST step is not a row (git /
# gh fail, or run an external git-<name>; as before).
# R29a: with <bang-regex>, a `!` step counts only when its text matches <bang-regex>; otherwise the call is a row of
# kind 3 ("3<TAB><abs dir>": the dir the alias was looked up in), which the guard counts only when that dir is
# managed. Without it, every `!` step counts (kind 0/1).
hook_opaque_rows() {
  local re="$1" are="${2:-$1}" bre="${3:-}" row tool name dir unk d val ghl="" ghrc=-1 n nx depth hit w
  local -A cmds=()
  HOOK_OPQ_ROWS=()
  while IFS= read -r row; do
    [ -n "$row" ] && HOOK_OPQ_ROWS+=("$row")
  # R33: the verb must stand as a word in the row text (mergeStateStatus, --merges, pushd are not merge / push): no
  # word character right before it, and none right after it unless it ends in one that is not a word char (pulls/5)
  # R35: a row that carries `mentions` (the parser's unaccounted-mention row: the whole command, unknown dir) is this
  # guard's when one of those mentions holds its verb; the rest of the command text does not count for it.
  done < <(jq -r --arg re "$re" '("(?<![A-Za-z0-9_])(?:" + $re + ")(?:(?<=[^A-Za-z0-9_])|(?![A-Za-z0-9_]))") as $wre
      | [.opaque, (.opaqueDirs // [])] | transpose[]
      | select((if ((.[1].mentions | type) == "array") then any(.[1].mentions[]; test($wre; "i"))
                else ((.[0] // "") | test($wre; "i")) end) or (.[1].any == true))
      | "\(if .[1].unknown == false then 0 else 1 end)\t\(.[1].dir // "")"' <<<"$PARSED" | tr -d '\r')
  while IFS= read -r w; do
    [ -n "$w" ] && cmds["$w"]=1
  done < <(jq -r '((.gitCommands // [])[] | "git:\(.)"), ((.ghCommands // [])[] | "gh:\(.)")' <<<"$PARSED" | tr -d '\r')
  while IFS=$'\037' read -r tool name dir unk; do   # \037: an empty dir must not collapse (tab is IFS whitespace)
    [ -n "$tool" ] || continue
    if [ "$unk" = true ] || [ -z "$dir" ]; then d="${HOOK_CWD:-.}"; else d=$(hook_abs "$dir"); fi
    if [ "$tool" = gh ] && [ "$ghrc" -lt 0 ]; then
      ghrc=0; hook_net ghl null 5 gh alias list || ghrc=$?; ghl="${ghl//$'\r'/}"
    fi
    if [ "$tool" = gh ] && [ "$ghrc" -ne 0 ]; then HOOK_OPQ_ROWS+=("2"$'\t'); continue; fi   # cannot list gh aliases: kind 2
    n="$name"; depth=0; hit=0
    while :; do
      depth=$((depth + 1))
      if [ "$depth" -gt 10 ]; then hit=1; break; fi                 # too deep (or a loop)
      if [ "$tool" = git ]; then
        val=$(git -C "$(devfw_path "$d")" config --get "alias.$n" 2>/dev/null | tr -d '\r') || val=""
      else
        val=$(awk -v n="$n" 'index($0, n ":") == 1 { print substr($0, length(n) + 2); exit }' <<<"$ghl")
        val="${val# }"
      fi
      if [ -z "$val" ]; then [ "$depth" -eq 1 ] || hit=1; break; fi  # later step: names an alias that does not resolve
      # a shell alias: unreadable. (For real aliases the unresolved-step clause would also catch it on the next step, since
      # "!word" is never an alias or a command; keep BOTH: deleting that clause would leave shell aliases to this one,
      # and the R29a narrowing below needs a `!` step to stop here rather than fall through to it.)
      if [ "${val:0:1}" = '!' ]; then
        if [ -z "$bre" ] || jq -en --arg v "$val" --arg re "$bre" '$v | test($re; "i")' >/dev/null 2>&1; then hit=1
        else hit=3; fi
        break
      fi
      if jq -en --arg v "$val" --arg re "$are" '$v | test($re; "i")' >/dev/null 2>&1; then hit=1; break; fi
      read -r nx _ <<<"$val"
      case "$nx" in -*|'') hit=1; break ;; esac                       # options first: not read here
      [ -z "${cmds["$tool:${nx,,}"]:-}" ] || break                    # a command the regex did not match: harmless
      n="$nx"
    done
    if [ "$hit" -eq 3 ]; then HOOK_OPQ_ROWS+=("3"$'\t'"$d"); continue; fi   # R29a: counts only where $d is managed
    [ "$hit" -eq 1 ] || continue
    HOOK_OPQ_ROWS+=("$([ "$unk" = true ] && echo 1 || echo 0)"$'\t'"$dir")
  done < <(jq -r '(.aliases // [])[] | [.tool, .name, (.dir // ""), (.unknown | tostring)] | join("\u001f")' <<<"$PARSED" | tr -d '\r')
}

# hook_opaque_hit <pred-fn>: 0 when any HOOK_OPQ_ROWS row is in scope: its dir is unknown, or <pred-fn> <dir>
# (the row's literal dir made absolute, and the hook cwd) returns 0. <pred-fn> returns 0 for "in scope" and must
# count its own errors as in scope.
hook_opaque_hit() {
  local row u d
  [ "${#HOOK_OPQ_ROWS[@]}" -gt 0 ] || return 1
  "$1" "${HOOK_CWD:-.}" && return 0
  for row in "${HOOK_OPQ_ROWS[@]}"; do
    u="${row%%$'\t'*}"; d="${row#*$'\t'}"
    [ "$u" != 1 ] || return 0   # kind 2 falls through: only the cwd test above applies to it
    if [ -n "$d" ] && "$1" "$(hook_abs "$d")"; then return 0; fi
  done
  return 1
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
  # per-process refs (M1): claim-guard and push-guard run in parallel and must not lock the same ref; deleted after
  # the read (a killed run can leave one behind under refs/devfw/claim-check/<pid>/, harmless).
  local cr="refs/devfw/claim-check/$$" rc=3
  hook_net body null "$t" git -C "$dir" -c gc.auto=0 -c maintenance.auto=false fetch -q --no-tags --no-write-fetch-head \
    --refmap= --no-recurse-submodules "$remote" \
    "+refs/heads/$branch:$cr/b/$branch" "+refs/heads/$base:$cr/base" \
    || { _hook_claim_refs_rm "$dir" "$cr"; return 1; }
  if body=$(git -C "$dir" log --format=%B "$cr/base..$cr/b/$branch" 2>/dev/null); then
    grep -q "^Claim-Issue: $n\$" <<<"${body//$'\r'/}" && rc=0
  else rc=1; fi
  _hook_claim_refs_rm "$dir" "$cr"
  return "$rc"
}
_hook_claim_refs_rm() {  # _hook_claim_refs_rm <dir> <ref-prefix>: delete this run's claim-check refs
  local r
  while IFS= read -r r; do
    [ -n "$r" ] && git -C "$1" update-ref -d "$r" >/dev/null 2>&1
  done < <(git -C "$1" for-each-ref --format='%(refname)' "$2/" 2>/dev/null | tr -d '\r')
  return 0
}
