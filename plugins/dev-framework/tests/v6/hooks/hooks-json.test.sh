#!/bin/bash
# hooks-json: the wiring of hooks/hooks.json (Plan 3 Task 10).
# - jq parses it; every command is `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/<name>` and <name> exists and is
#   executable (git index mode 100755, since Windows' -x is not a real check);
# - no PreToolUse entry or hook carries `if` (a blocking hook pre-filters itself; an `if` is a silent skip);
# - every Edit matcher also names Write, MultiEdit and NotebookEdit;
# - the v6 rows of the Task 10 table are present with their timeouts; no EnterWorktree matcher (ruling R5);
# - one deadline per hook run (ruling R19): every v6 script's run budget (`hook_init <name> <N>`, else the
#   _v6-hook.sh default) plus a 5 s margin fits in its hooks.json timeout (a hook timeout does not block, so the
#   run must end first);
# - every network call (gh api/pr, git fetch/ls-remote, bin/lease, merge-gate, stop-check) in a wired script or
#   _v6-hook.sh goes through hook_net, and no bare `timeout` exists outside hook_net's own body.
# DEVFW_TEST_HOOKS_JSON overrides the file under test (used to show RED against an older hooks.json).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$DIR/../../.." && pwd)"
HJ="${DEVFW_TEST_HOOKS_JSON:-$PLUGIN/hooks/hooks.json}"
SCRIPTS="$PLUGIN/hooks/scripts"
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
p() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
J() { jq -r "$@" "$(p "$HJ")" | tr -d '\r'; }

jq . "$(p "$HJ")" >/dev/null 2>&1 || { echo "FAIL: jq cannot parse $HJ"; exit 1; }

# 1. commands: form, existence, executable bit.
PREFIX='bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/'
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  case "$cmd" in "$PREFIX"*) ;; *) fail "command not of the form '${PREFIX}<name>': $cmd"; continue ;; esac
  name=${cmd#"$PREFIX"}
  [[ "$name" =~ ^[A-Za-z0-9._-]+\.sh$ ]] || { fail "command carries more than a script name: $cmd"; continue; }
  [ -f "$SCRIPTS/$name" ] || { fail "script missing: hooks/scripts/$name"; continue; }
  mode=$(git -C "$PLUGIN" ls-files -s -- "hooks/scripts/$name" 2>/dev/null | awk '{print $1}' | tr -d '\r')
  if [ -n "$mode" ]; then [ "$mode" = 100755 ] || fail "hooks/scripts/$name is mode $mode in the git index, not 100755"
  else [ -x "$SCRIPTS/$name" ] || fail "hooks/scripts/$name is not executable"; fi
done < <(J '.hooks[][].hooks[].command')

# 1b. (I3) every file in bin/, every hooks/scripts/*.sh and every file under hooks/git/** (shim templates' dispatcher,
#     _git-lib.sh, rules/*.sh) is 100755 in the git index: hooks exec bin/merge-gate, bin/lease and bin/stop-check
#     directly, and a 100644 entry works on Windows only (Git Bash ignores the bit).
while IFS= read -r line; do
  [ -n "$line" ] || continue
  mode=${line%% *}; path=${line#*$'\t'}
  [ "$mode" = 100755 ] || fail "$path is mode $mode in the git index, not 100755"
done < <(git -C "$PLUGIN" ls-files -s -- bin hooks/scripts hooks/git | tr -d '\r' \
           | awk -F'\t' '$2 ~ /^bin\// || $2 ~ /^hooks\/scripts\/[^\/]*\.sh$/ || $2 ~ /^hooks\/git\//')
n=$(git -C "$PLUGIN" ls-files -- bin | wc -l)
[ "$n" -gt 0 ] || fail "no bin/ files in the git index (is the plugin checked out from git?)"
n=$(git -C "$PLUGIN" ls-files -- hooks/git | wc -l)
[ "$n" -gt 0 ] || fail "no hooks/git/ files in the git index (the mode fence would be vacuous)"

# 2. no `if` on any PreToolUse entry or hook.
n=$(J '[.hooks.PreToolUse // [] | .[] | select(has("if") or any(.hooks[]; has("if")))] | length')
[ "$n" = 0 ] || fail "$n PreToolUse entr(y/ies) carry an \"if\""

# 3. every Edit matcher names the full edit-tool family.
while IFS= read -r m; do
  [ -n "$m" ] || continue
  for tool in Edit Write MultiEdit NotebookEdit; do
    tr '|' '\n' <<<"$m" | grep -qx "$tool" || fail "matcher '$m' lacks $tool"
  done
done < <(J '.hooks[][] | .matcher | select(. != null) | select(split("|") | index("Edit"))')

# 4. the v6 rows (event, matcher, script, timeout).
EDITM='Edit|Write|MultiEdit|NotebookEdit'
row() {  # row <event> <matcher> <script> <timeout>
  local got
  got=$(J --arg e "$1" --arg m "$2" --arg c "$PREFIX$3" \
    '[.hooks[$e] // [] | .[] | select(.matcher == $m) | .hooks[] | select(.command == $c) | .timeout] | map(tostring) | join(",")')
  [ "$got" = "$4" ] || fail "$1 [$2] $3: timeout(s) '${got:-none}', want exactly one entry with $4"
}
row SessionStart '*' load-chronic-patterns.sh 3
row SessionStart '*' session-digest.sh 15
row PreToolUse "$EDITM" plan-edit-guard.sh 30
row PreToolUse "$EDITM" freeze-gate.sh 30
row PreToolUse Bash plan-edit-guard.sh 30
row PreToolUse Bash merge-gate-hook.sh 120
row PreToolUse Bash push-guard.sh 30
row PreToolUse Bash claim-guard.sh 30
row Stop '*' stop-backstop.sh 30
n=$(J '[.hooks[][] | .matcher // "" | split("|")[] | select(. == "EnterWorktree")] | length')
[ "$n" = 0 ] || fail "EnterWorktree is registered, but Q5 is unmeasured (ruling R5)"

# 5. one deadline per run (ruling R19): each v6 script sets its run budget with `hook_init <name> <N>`, and N plus
#    a 5 s margin for local work must fit in its hooks.json timeout. A script that sources _v6-hook.sh but passes
#    no budget gets the library default, which must fit too.
MARGIN=5
LIBDEF=$(grep -oE '^_hook_set_budget [0-9]+' "$SCRIPTS/_v6-hook.sh" | grep -oE '[0-9]+$' | head -1)
budget() {  # budget <script path>: its run budget in seconds; empty when it does not use _v6-hook.sh
  local f="$1" b
  grep -q '_v6-hook\.sh' "$f" || return 0
  b=$(grep -E '^[[:space:]]*hook_init[[:space:]]+[A-Za-z0-9_-]+' "$f" | head -1 | awk '{print $3}' | tr -d '\r')
  [[ "$b" =~ ^[0-9]+$ ]] || b="$LIBDEF"
  echo "$b"
}
[[ "$LIBDEF" =~ ^[0-9]+$ ]] || fail "cannot read _v6-hook.sh's default run budget"
while IFS=$'\t' read -r cmd to; do
  [ -n "$cmd" ] || continue
  name=${cmd#"$PREFIX"}; f="$SCRIPTS/$name"; [ -f "$f" ] || continue
  b=$(budget "$f")
  [ -n "$b" ] || continue
  [ $((b + MARGIN)) -le "$to" ] || fail "$name: run budget ${b}s + ${MARGIN}s margin exceeds its hook timeout ${to}s"
done < <(J '.hooks[][].hooks[] | [.command, (.timeout|tostring)] | @tsv')

# 6. every network call goes through the deadline helper of its layer (controller ruling 7): hook_net in the
#    PreToolUse code (each wired script and _v6-hook.sh), scope_net in bin/_scope.sh, gk_net in the git hooks
#    (every file under hooks/git/**). In each file, outside its helper's own definition: (a) no `timeout` command at
#    all; (b) every line that calls gh api / gh pr, git fetch / ls-remote, or bin/lease / merge-gate / stop-check
#    carries that helper. Quoted text is ignored for (b)'s gh/git words (a block message may name a command), never
#    a whole line.
offenders() {  # offenders <file> [<helper>, default hook_net]: prints "lineno: text" for each violation
  awk -v h="${2:-hook_net}" '
    /^[[:space:]]*#/ { next }
    $0 ~ ("^" h "\\(\\)[[:space:]]*\\{") { inhn = 1 }
    inhn { if ($0 ~ /^\}/) inhn = 0; next }
    {
      line = $0; sub(/[[:space:]]#[^"]*$/, "", line)
      unq = line; gsub(/"[^"]*"/, "\"\"", unq)
      bare = (unq ~ /(^|[^A-Za-z0-9_-])timeout[[:space:]]/)
      net  = (unq ~ /(^|[^A-Za-z0-9_-])gh[[:space:]]+(api|pr)([[:space:]]|$)/ ||
              unq ~ /(^|[[:space:]])(fetch|ls-remote)([[:space:]]|$)/ ||
              line ~ /\/(lease|merge-gate|stop-check)"?([[:space:])]|$)/)
      pure = (line ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="[^"]*"[[:space:]]*$/)
      if (bare) print NR ": bare timeout: " $0
      else if (net && !pure && line !~ ("(^|[^A-Za-z0-9_])" h "[[:space:]]")) print NR ": network call outside " h ": " $0
    }' "$1" | tr -d '\r'
}
# NETSCAN rows: "<helper>\t<path relative to the plugin>"
NETSCAN=("hook_net"$'\t'"hooks/scripts/_v6-hook.sh" "scope_net"$'\t'"bin/_scope.sh")
while IFS= read -r cmd; do [ -n "$cmd" ] && NETSCAN+=("hook_net"$'\t'"hooks/scripts/${cmd#"$PREFIX"}"); done < <(J '.hooks[][].hooks[].command' | sort -u)
while IFS= read -r f; do [ -n "$f" ] && NETSCAN+=("gk_net"$'\t'"$f"); done < <(cd "$PLUGIN" && find hooks/git -type f | sort)
for row in "${NETSCAN[@]}"; do
  helper=${row%%$'\t'*}; rel=${row#*$'\t'}
  [ -f "$PLUGIN/$rel" ] || continue
  while IFS= read -r o; do [ -z "$o" ] || fail "$rel:$o"; done < <(offenders "$PLUGIN/$rel" "$helper")
done
# net_scope_files_scanned: the scan list really holds bin/_scope.sh and every file under hooks/git/ (a list that
# lost them would make the scan vacuous for the claim fetch and every git-hook network call)
scanned() { local r; for r in "${NETSCAN[@]}"; do [ "${r#*$'\t'}" = "$1" ] && [ "${r%%$'\t'*}" = "$2" ] && return 0; done; return 1; }
scanned bin/_scope.sh scope_net || fail "net_scope_files_scanned: bin/_scope.sh is not in the network scan"
n=0
while IFS= read -r f; do
  [ -n "$f" ] || continue; n=$((n + 1))
  scanned "$f" gk_net || fail "net_scope_files_scanned: $f is not in the network scan"
done < <(git -C "$PLUGIN" ls-files -- hooks/git | tr -d '\r')
[ "$n" -gt 0 ] || fail "net_scope_files_scanned: no tracked file under hooks/git/"

# 6b. eol fence (controller ruling 5): every tracked file under the LF-only paths new in Plan 3b carries
#    `attr/text eol=lf` and `i/lf` in the index, and a scratch `git clone -c core.autocrlf=true` of this repo checks
#    them out without a CR (what a Windows machine with the system default gets). Tasks 8 and 9 add lib/ and
#    hooks/tripwire/.
EOL_PATHS=(hooks/git)
EOLFILES=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  path=${line#*$'\t'}; EOLFILES+=("$path")
  [[ "$line" == *"attr/text eol=lf"* ]] || fail "eol_new_paths_lf: $path is not attr/text eol=lf ($line)"
  [[ "$line" == "i/lf "* ]] || fail "eol_new_paths_lf: $path is not i/lf in the index ($line)"
done < <(git -C "$PLUGIN" ls-files --eol -- "${EOL_PATHS[@]}" | tr -d '\r')
[ "${#EOLFILES[@]}" -gt 0 ] || fail "eol_new_paths_lf: no tracked file under ${EOL_PATHS[*]}"
EC=$(mktemp -d)
TOP=$(git -C "$PLUGIN" rev-parse --show-toplevel | tr -d '\r'); PFX=$(git -C "$PLUGIN" rev-parse --show-prefix | tr -d '\r')
HEADSHA=$(git -C "$PLUGIN" rev-parse HEAD | tr -d '\r')
if git -c core.autocrlf=true clone -q --no-checkout -c core.autocrlf=true "$(p "$TOP")" "$(p "$EC/c")" 2>/dev/null \
   && git -C "$(p "$EC/c")" checkout -q "$HEADSHA" -- .gitattributes 2>/dev/null; then
  committed=()
  for f in "${EOLFILES[@]}"; do git -C "$(p "$EC/c")" cat-file -e "$HEADSHA:$PFX$f" 2>/dev/null && committed+=("$PFX$f"); done
  if [ "${#committed[@]}" -gt 0 ]; then
    git -C "$(p "$EC/c")" checkout -q "$HEADSHA" -- "${committed[@]}" 2>/dev/null || fail "eol_new_paths_lf: scratch checkout failed"
    for f in "${committed[@]}"; do
      [ -f "$EC/c/$f" ] || { fail "eol_new_paths_lf: $f missing in the scratch clone"; continue; }
      ! grep -q $'\r' "$EC/c/$f" || fail "eol_new_paths_lf: $f has a CR in a core.autocrlf=true clone"
    done
  else
    echo "note: eol_new_paths_lf clone half skipped: no file under ${EOL_PATHS[*]} committed at HEAD yet"
  fi
else
  fail "eol_new_paths_lf: cannot make the scratch core.autocrlf=true clone"
fi
rm -rf "$EC"

# 7. self-checks: each reader on samples, so a reader regression cannot make sections 5-6 vacuous.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
x() { printf '%s\n' "$2" > "$T/s.sh"; local got; got=$(offenders "$T/s.sh"); if [ "$1" = flag ]; then [ -n "$got" ] || fail "offenders reader missed: $2"; else [ -z "$got" ] || fail "offenders reader flagged: $2 ($got)"; fi; }
x flag 'x=$(timeout 7 gh api a)'
x flag 'out=$(timeout "${DEVFW_HOOK_NET_TIMEOUT:-21}" "$BIN/lease" check)'
x flag '  timeout "$t" git -C "$dir" fetch -q origin \'
x flag 'out=$(gh api "repos/$R/issues/$n" 2>/dev/null)'
x flag 'git -C "$d" ls-remote origin HEAD'
x flag 'out=$("$BIN/merge-gate" --pr 1)'
x flag '[ "$x" ] || hook_block "gh pr merge failed"; gh pr merge 1 --repo a/b'
x flag 'OUT=$(bash "$(devfw_path "$DEVFW_BIN_DIR/stop-check")" --ledger l)'
x ok   'hook_net out null 20 gh api "repos/$R/issues/$n" || rc=$?'
x ok   'hook_net body null "$t" git -C "$dir" fetch -q --no-tags \'
x ok   'hook_block "cannot read this merge command exactly; write it as: gh pr merge <n> --repo <owner/name> --squash"'
x ok   'SC="${DEVFW_BIN_DIR:-$HOOK_LIB_DIR/../../bin}/stop-check"'
x ok   '# timeout 20 gh api in a comment'
printf 'hook_net() {\n  __o=$(timeout "$s" "$@")\n}\n' > "$T/s.sh"; [ -z "$(offenders "$T/s.sh")" ] || fail "offenders reader flagged the hook_net body"
# per-layer helpers: each file is held to ITS helper, and only that helper's own body is exempt
xh() { printf '%s\n' "$3" > "$T/s.sh"; local got; got=$(offenders "$T/s.sh" "$1"); if [ "$2" = flag ]; then [ -n "$got" ] || fail "offenders reader ($1) missed: $3"; else [ -z "$got" ] || fail "offenders reader ($1) flagged: $3 ($got)"; fi; }
xh scope_net flag 'git -C "$d" fetch -q origin main'
xh scope_net flag 'hook_net o null 5 git -C "$d" ls-remote origin HEAD'
xh scope_net ok   'scope_net _sc_ls "$_sc_t" git -C "$_sc_dir" ls-remote --symref "$_sc_remote" HEAD'
xh gk_net    flag 'out=$(gh api "repos/$R/issues/$n")'
xh gk_net    flag 'scope_net o 20 git fetch origin'
xh gk_net    ok   'gk_net out 20 gh api "repos/$GK_PLAN_REPO/issues/$n" || rc=$?'
xh gk_net    ok   'scope_net() { gk_net "$1" 20 "${@:3}"; }'
printf 'gk_net() {\n  timeout "$t" "$@" >"$o"\n}\nx=$(timeout 3 true)\n' > "$T/s.sh"
[ "$(offenders "$T/s.sh" gk_net | wc -l)" -eq 1 ] || fail "offenders reader: gk_net body exempt, the bare timeout after it flagged: $(offenders "$T/s.sh" gk_net)"
[ "$(offenders "$T/s.sh" hook_net | wc -l)" -eq 2 ] || fail "offenders reader: a gk_net body is not exempt under hook_net"
printf '#!/bin/bash\n. "$D/_v6-hook.sh"\nhook_init a 31\n' > "$T/b.sh";  [ "$(budget "$T/b.sh")" = 31 ] || fail "budget reader: hook_init <name> <N>"
printf '#!/bin/bash\n. "$D/_v6-hook.sh"\nhook_init a\n' > "$T/c.sh";     [ "$(budget "$T/c.sh")" = "$LIBDEF" ] || fail "budget reader: library default"
printf '#!/bin/bash\necho v5\n' > "$T/d.sh";                            [ -z "$(budget "$T/d.sh")" ] || fail "budget reader: a v5 script has no budget"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "ok hooks.json wiring"
