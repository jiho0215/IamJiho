#!/bin/bash
# The cost of a git-hook run, and the fences of the fast no-op path that keeps it low.
#
# The dispatcher exits early ("fast") only when BOTH hold:
#   - no repo hook to chain: the resolved hooks dir comes from a VALID chain cache entry
#     (<state>/git-hooks/.chain/<name>), and <dir>/<hook> is not an executable file (tested live on every run);
#   - nothing for the rule to check: there is no rules file for the hook, or its <fn>_idle says so.
# Everything else takes the full path (rule, then chain). DEVFW_GK_TRACE=1 logs `fast\t<hook>\t<args>` or
# `full\t<hook>\t<why>` per run to <state>/dispatch.log, which the structural rows read.
#
# Timing rows (pf_time_*) are bounded with generous slack (2-3x the targets) so they do not flake under load; the
# raw numbers are printed as `measured ...` lines. PF_UNTIL=<row> stops after that row (test-only knob).
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS DEVFW_SESSION_ID DEVFW_CONFIG DEVFW_CORE_DIR CDPATH
for v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_'); do unset "$v"; done
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_fixture.sh"

LOG="$TMP/state/dispatch.log"
CACHE="$TMP/state/git-hooks/.chain"
until_row() { [ "${PF_UNTIL:-}" != "$1" ] || fx_done; }
now_us() { printf '%s' "${EPOCHREALTIME/./}"; }
hookfile() {  # hookfile <path> <body...>: an executable sh hook
  local p="$1"; shift
  mkdir -p "$(dirname "$p")"
  { echo '#!/bin/sh'; printf '%s\n' "$@"; } > "$p"; chmod +x "$p"
}
reset_w() {  # no local hooksPath, no repo hooks, no include, no global config
  git -C "$W" config --unset-all core.hooksPath 2>/dev/null
  git -C "$W" config --unset-all include.path 2>/dev/null
  rm -f "$W/.git/hooks/pre-commit" "$W/.git/hooks/reference-transaction" "$HOME/.gitconfig"
  rm -rf "$W/.husky"
}
tr_on() { rm -f "$LOG"; }
tr_lines() { tr -d '\r' < "$LOG" 2>/dev/null | grep -E "^$1	" ; }
# commit <tag>: one traced empty commit in W under hk; fails the row on a non-zero exit
tcommit() { tr_on; DEVFW_GK_TRACE=1 expect "$1" 0 - hk git -C "$W" commit -q --allow-empty -m "$1"; }
# w_cache: the chain cache file of W's key (the hook runs with PWD = W)
w_cache() { grep -lF -- $'\037'"PWD=$W"$'\037' "$CACHE"/* 2>/dev/null | head -1; }

# warm the cache for W (the first run in a repo is a cache miss and takes the full path)
hk git -C "$W" commit -q --allow-empty -m warm >/dev/null 2>&1 || fx_die "warm commit"

# --- structural: the fast path is taken, and not taken
# pf_fast_path_commit: an empty commit in a repo with no hooks of its own runs every hook on the fast path
if tcommit pf_fast_path_commit; then
  F=$(tr_lines full); N=$(tr_lines fast | wc -l)
  if [ -n "$F" ]; then fail "pf_fast_path_commit: full runs: $F"
  elif ! tr_lines fast | grep -q "	pre-commit	"; then fail "pf_fast_path_commit: no fast pre-commit: $(cat "$LOG")"
  elif ! tr_lines fast | grep -q "	reference-transaction	prepared"; then fail "pf_fast_path_commit: no fast prepared: $(cat "$LOG")"
  elif [ "$N" -lt 4 ]; then fail "pf_fast_path_commit: only $N fast runs: $(cat "$LOG")"
  else ok pf_fast_path_commit; fi
fi
until_row pf_fast_path_commit

# pf_fast_path_t_branch: a commit on an existing t/ branch (an update: old oid non-zero) and the checkout of it
# (HEAD's symref line names ref:refs/heads/t/...) keep every reference-transaction run fast; the ref-tx rule has
# nothing to check. Since Task 6 the pre-commit run on a t/ branch is the one full run (rules/pre-commit.sh checks the
# current t/ branch's claim), so the branch carries local claim evidence (its tracking ref) and the commit lands.
g -C "$W" branch t/41-x >/dev/null 2>&1 && g -C "$W" update-ref refs/remotes/origin/t/41-x t/41-x || fx_die "branch t/41-x"
tr_on
DEVFW_GK_TRACE=1 expect pf_fast_path_t_branch 0 - hk git -C "$W" checkout -q t/41-x \
  && DEVFW_GK_TRACE=1 expect pf_fast_path_t_branch 0 - hk git -C "$W" commit -q --allow-empty -m on-t \
  && { F=$(tr_lines full)
       [ "$F" = "full	pre-commit	rule" ] && tr_lines fast | grep -q "	prepared" && ok pf_fast_path_t_branch \
         || fail "pf_fast_path_t_branch: $(cat "$LOG")"; }
g -C "$W" checkout -q main || fx_die "back to main"

# pf_creation_takes_full_path: creating a t/ branch selects a line, so the rule runs (and blocks: no claim)
tr_on
DEVFW_GK_TRACE=1 expect pf_creation_takes_full_path block "no claim for issue 77" hk git -C "$W" checkout -q -b t/77-x \
  && { tr_lines full | grep -q "^full	reference-transaction	rule" && ok pf_creation_takes_full_path \
         || fail "pf_creation_takes_full_path: no full/rule trace: $(cat "$LOG")"; }

# pf_state_not_prepared_fast: rule 1 (only `prepared` is checked) decides without reading stdin
printf '%s %s refs/heads/t/77-x\n' 0000000000000000000000000000000000000000 "$(git -C "$W" rev-parse HEAD | tr -d '\r')" \
  > "$TMP/create.in"
tr_on
( cd "$W" && hk_env && env DEVFW_GK_TRACE=1 "${HKENV[@]}" "$HK/reference-transaction" committed < "$TMP/create.in" ) \
  >/dev/null 2>"$TMP/.e"; RC=$?
[ "$RC" -eq 0 ] && tr_lines fast | grep -q "	reference-transaction	committed" && ok pf_state_not_prepared_fast \
  || fail "pf_state_not_prepared_fast: rc=$RC $(cat "$TMP/.e") trace: $(cat "$LOG" 2>&1)"
tr_on
( cd "$W" && hk_env && env DEVFW_GK_TRACE=1 "${HKENV[@]}" "$HK/reference-transaction" prepared < "$TMP/create.in" ) \
  >/dev/null 2>"$TMP/.e"; RC=$?
[ "$RC" -eq 1 ] && grep -q "no claim for issue 77" "$TMP/.e" && tr_lines full | grep -q "	rule" \
  && ok pf_state_prepared_full || fail "pf_state_prepared_full: rc=$RC $(cat "$TMP/.e") trace: $(cat "$LOG" 2>&1)"
until_row pf_state_prepared_full

# pf_repo_hook_takes_full_path: a repo reference-transaction hook is chained for every state; pre-commit, which has
# no repo hook, stays fast
hookfile "$W/.git/hooks/reference-transaction" "echo \"\$1\" >> '$(mp "$TMP/rt.log")'"
rm -f "$TMP/rt.log"
if tcommit pf_repo_hook_takes_full_path; then
  S=$(tr -d '\r' < "$TMP/rt.log" 2>/dev/null | sort -u | tr '\n' ' ')
  if [ "$S" != "aborted committed prepared " ]; then fail "pf_repo_hook_takes_full_path: chained states '$S'"
  elif tr_lines fast | grep -q "	reference-transaction	"; then fail "pf_repo_hook_takes_full_path: a fast ref-tx run: $(cat "$LOG")"
  elif ! tr_lines full | grep -q "^full	reference-transaction	chain"; then fail "pf_repo_hook_takes_full_path: no full/chain: $(cat "$LOG")"
  elif ! tr_lines fast | grep -q "	pre-commit	"; then fail "pf_repo_hook_takes_full_path: pre-commit not fast: $(cat "$LOG")"
  else ok pf_repo_hook_takes_full_path; fi
fi
reset_w
until_row pf_repo_hook_takes_full_path

# --- pf_new_repo_hook_chained_next_run: a hook or hook config added right after a fast run is chained at once
# warm_fast <row>: an untraced commit (it may refresh the cache), then a traced one that must be all fast
warm_fast() {
  hk git -C "$W" commit -q --allow-empty -m "$1-pre" >/dev/null 2>&1
  tcommit "$1" && [ -z "$(tr_lines full)" ] && tr_lines fast | grep -q "	pre-commit	" || fail "$1: the warm run was not fast: $(cat "$LOG" 2>&1)"
}
# (a) .git/hooks/reference-transaction
warm_fast pf_new_repo_hook_a_warm
hookfile "$W/.git/hooks/reference-transaction" "echo \"\$1\" >> '$(mp "$TMP/a.log")'"
rm -f "$TMP/a.log"
expect pf_new_repo_hook_chained_next_run_a 0 - hk git -C "$W" commit -q --allow-empty -m na \
  && { grep -q committed "$TMP/a.log" 2>/dev/null && ok pf_new_repo_hook_chained_next_run_a \
         || fail "pf_new_repo_hook_chained_next_run_a: the new hook did not run"; }
reset_w
# (b) husky style: local relative core.hooksPath set after a fast run (the local config changes)
warm_fast pf_new_repo_hook_b_warm
hookfile "$W/.husky/_/reference-transaction" "echo \"\$1\" >> '$(mp "$TMP/b.log")'"
hookfile "$W/.husky/_/pre-commit" "echo husky-pc >> '$(mp "$TMP/b.log")'"
git -C "$W" config core.hooksPath .husky/_
rm -f "$TMP/b.log"
expect pf_new_repo_hook_chained_next_run_b 0 - hk git -C "$W" commit -q --allow-empty -m nb \
  && { grep -q husky-pc "$TMP/b.log" 2>/dev/null && grep -q committed "$TMP/b.log" && ok pf_new_repo_hook_chained_next_run_b \
         || fail "pf_new_repo_hook_chained_next_run_b: husky hooks did not run: $(cat "$TMP/b.log" 2>&1)"; }
# (c) husky dir missing at first (fresh worktree), created after a fast run: the hook file is tested live
rm -rf "$W/.husky"
warm_fast pf_new_repo_hook_c_warm
hookfile "$W/.husky/_/pre-commit" "echo husky-late >> '$(mp "$TMP/c.log")'"
rm -f "$TMP/c.log"
expect pf_new_repo_hook_chained_next_run_c 0 - hk git -C "$W" commit -q --allow-empty -m nc \
  && { grep -q husky-late "$TMP/c.log" 2>/dev/null && ok pf_new_repo_hook_chained_next_run_c \
         || fail "pf_new_repo_hook_chained_next_run_c: the late husky hook did not run"; }
reset_w
# (d) a global core.hooksPath created after a fast run (~/.gitconfig did not exist)
[ ! -e "$HOME/.gitconfig" ] || fx_die "setup: ~/.gitconfig exists"
warm_fast pf_new_repo_hook_d_warm
hookfile "$TMP/ghooks/pre-commit" "echo global-pc >> '$(mp "$TMP/d.log")'"
git config --global core.hooksPath "$(mp "$TMP/ghooks")"
rm -f "$TMP/d.log"
expect pf_new_repo_hook_chained_next_run_d 0 - hk git -C "$W" commit -q --allow-empty -m nd \
  && { grep -q global-pc "$TMP/d.log" 2>/dev/null && ok pf_new_repo_hook_chained_next_run_d \
         || fail "pf_new_repo_hook_chained_next_run_d: the global hook did not run"; }
# (e) that global config removed again after a fast run: the repo's default hooks dir applies once more (the
# cached dir is the global one, which holds no pre-commit now, so .git/hooks/pre-commit is not consulted until then)
rm -f "$TMP/ghooks/pre-commit"
hookfile "$W/.git/hooks/pre-commit" "echo local-pc >> '$(mp "$TMP/e.log")'"
warm_fast pf_new_repo_hook_e_warm
rm -f "$HOME/.gitconfig" "$TMP/e.log"
expect pf_new_repo_hook_chained_next_run_e 0 - hk git -C "$W" commit -q --allow-empty -m ne \
  && { grep -q local-pc "$TMP/e.log" 2>/dev/null && ok pf_new_repo_hook_chained_next_run_e \
         || fail "pf_new_repo_hook_chained_next_run_e: .git/hooks/pre-commit did not run after the global config went"; }
reset_w
# (f) a worktree-scope core.hooksPath (.git/config.worktree, absent until now) set after a fast run
git -C "$W" config extensions.worktreeConfig true
[ ! -e "$W/.git/config.worktree" ] || fx_die "setup: config.worktree exists"
warm_fast pf_new_repo_hook_f_warm
hookfile "$TMP/whooks/pre-commit" "echo wt-pc >> '$(mp "$TMP/f.log")'"
git -C "$W" config --worktree core.hooksPath "$(mp "$TMP/whooks")"
[ -f "$W/.git/config.worktree" ] || fx_die "setup: git config --worktree wrote no .git/config.worktree"
rm -f "$TMP/f.log"
expect pf_new_repo_hook_chained_next_run_f 0 - hk git -C "$W" commit -q --allow-empty -m nf \
  && { grep -q wt-pc "$TMP/f.log" 2>/dev/null && ok pf_new_repo_hook_chained_next_run_f \
         || fail "pf_new_repo_hook_chained_next_run_f: the worktree-scope hook did not run"; }
rm -f "$W/.git/config.worktree"; git -C "$W" config --unset extensions.worktreeConfig
until_row pf_new_repo_hook_chained_next_run_f

# pf_key_change: the same work tree under another HOME (whose ~/.gitconfig sets core.hooksPath) is another key;
# the cache file name depends only on the work tree, so the key line inside is what tells them apart
warm_fast pf_key_change_warm
mkdir -p "$TMP/home2"
hookfile "$TMP/ghooks2/pre-commit" "echo home2-pc >> '$(mp "$TMP/k.log")'"
HOME="$TMP/home2" git config --global core.hooksPath "$(mp "$TMP/ghooks2")"
rm -f "$TMP/k.log"
HOME="$TMP/home2" expect pf_key_change 0 - hk git -C "$W" commit -q --allow-empty -m kc \
  && { grep -q home2-pc "$TMP/k.log" 2>/dev/null && ok pf_key_change || fail "pf_key_change: HOME2's hook did not run"; }

# pf_include_not_cached: a config with an include is never cached (its target may appear later); a target created
# afterwards is honoured on the very next run
git -C "$W" config include.path inc.cfg
tcommit pf_include_not_cached_1
tcommit pf_include_not_cached_2 && { tr_lines full | grep -q "cache miss" || fail "pf_include_not_cached: a cached run: $(cat "$LOG")"; }
hookfile "$TMP/ihooks/pre-commit" "echo inc-pc >> '$(mp "$TMP/i.log")'"
printf '[core]\n\thooksPath = %s\n' "$(mp "$TMP/ihooks")" > "$W/.git/inc.cfg"
rm -f "$TMP/i.log"
expect pf_include_not_cached 0 - hk git -C "$W" commit -q --allow-empty -m ic \
  && { grep -q inc-pc "$TMP/i.log" 2>/dev/null && ok pf_include_not_cached || fail "pf_include_not_cached: the included hooksPath was ignored"; }
rm -f "$W/.git/inc.cfg"
reset_w
until_row pf_include_not_cached

# pf_future_mtime_not_cached: a config file not older than the refresh's start stamp is not cached (the proxy for a
# config edited while the refresh ran; it does NOT reproduce that race itself)
rm -rf "$CACHE"
touch -d '+1 hour' "$W/.git/config"
tcommit pf_future_mtime_not_cached && { [ -z "$(w_cache)" ] && ok pf_future_mtime_not_cached \
  || fail "pf_future_mtime_not_cached: cached: $(cat "$(w_cache)")"; }
touch "$W/.git/config"
hk git -C "$W" commit -q --allow-empty -m rewarm >/dev/null 2>&1
[ -n "$(w_cache)" ] || fail "pf_future_mtime_not_cached: no cache after the mtime was restored"
until_row pf_future_mtime_not_cached

# pf_deleted_during_refresh_not_cached (Task 5b fix round 1, review I1): a config file that set core.hooksPath is
# deleted in the middle of a refresh, right after the resolver's read. The resolver has returned the old dir; the
# entry must not be stored, so the next run resolves again and chains the repo's own hook. A PATH `git` wrapper
# deletes ~/.gitconfig once, right after the first `--get-all core.hooksPath` call (a deterministic race). git puts its
# own dirs first on a hook's PATH, so the refreshing run is the installed pre-commit shim run directly in W (as git
# runs it) with the wrapper first on PATH; the run after it is a real commit.
mkdir -p "$TMP/rhooks" "$TMP/racebin"
REALGIT=$(command -v git)
printf '%s\n' '#!/bin/bash' "\"$REALGIT\" \"\$@\"; rc=\$?" \
  'case " $* " in *" --get-all core.hooksPath "*) [ -e "$RACE_ONCE" ] || { : > "$RACE_ONCE"; rm -f "$HOME/.gitconfig"; } ;; esac' \
  'exit $rc' > "$TMP/racebin/git"
chmod +x "$TMP/racebin/git"
export RACE_ONCE="$TMP/race.once"; rm -f "$RACE_ONCE"
git config --global core.hooksPath "$(mp "$TMP/rhooks")"
rm -rf "$CACHE"
( cd "$W" && hk_env && export "${HKENV[@]}" && PATH="$TMP/racebin:$PATH" "$HK/pre-commit" ) </dev/null >/dev/null 2>"$TMP/.e" \
  || fail "pf_deleted_during_refresh_not_cached: the racing pre-commit run failed: $(cat "$TMP/.e")"
[ -e "$RACE_ONCE" ] || fail "pf_deleted_during_refresh_not_cached: setup: the git wrapper never ran in a hook"
[ ! -e "$HOME/.gitconfig" ] || fail "pf_deleted_during_refresh_not_cached: setup: ~/.gitconfig still exists"
# the claim itself: the racing refresh stored no entry (the load-time -f would also reject one whose `f` file is
# gone, so this is what fences the store-side check on its own)
[ -z "$(w_cache)" ] || fail "pf_deleted_during_refresh_not_cached: the racing refresh stored: $(tr '\n' '|' < "$(w_cache)")"
hookfile "$W/.git/hooks/pre-commit" "echo race-pc >> '$(mp "$TMP/race.log")'"
rm -f "$TMP/race.log"
tr_on
DEVFW_GK_TRACE=1 expect pf_deleted_during_refresh_not_cached 0 - hk git -C "$W" commit -q --allow-empty -m race2 \
  && { grep -q race-pc "$TMP/race.log" 2>/dev/null && ok pf_deleted_during_refresh_not_cached \
         || fail "pf_deleted_during_refresh_not_cached: the repo hook did not run: $(cat "$LOG" 2>&1)"; }
reset_w
until_row pf_deleted_during_refresh_not_cached

# --- pf_cache_corrupt_falls_back: a forged entry is obeyed only when it is well formed. The forged dir is an empty
# dir, so obeying it skips W's .git/hooks/pre-commit. v0 (well formed) proves the forgery would be obeyed; every
# corrupt variant must fall back to the full path, which runs the hook.
hookfile "$W/.git/hooks/pre-commit" "echo forged-test >> '$(mp "$TMP/v.log")'"
hk git -C "$W" commit -q --allow-empty -m refill >/dev/null 2>&1
CF=$(w_cache); [ -n "$CF" ] || fx_die "no cache file for W"
KEYLINE=$(sed -n 2p "$CF" | tr -d '\r'); WATCH=$(grep -E '^(f|a) ' "$CF" | tr -d '\r')
mkdir -p "$TMP/emptyhooks"
EH=$(mp "$TMP/emptyhooks")
forge() {  # forge <variant> <want: ran|skipped> <content>
  printf '%s' "$3" > "$CF"
  rm -f "$TMP/v.log"
  expect "pf_cache_corrupt_falls_back_$1" 0 - hk git -C "$W" commit -q --allow-empty -m "v$1" || return
  local got=skipped; grep -q forged-test "$TMP/v.log" 2>/dev/null && got=ran
  [ "$got" = "$2" ] && ok "pf_cache_corrupt_falls_back_$1" || fail "pf_cache_corrupt_falls_back_$1: hook $got, want $2"
}
forge v0_well_formed skipped "devfw-chain 1
$KEYLINE
dir $EH
$WATCH
end
"
forge v1_no_end ran "devfw-chain 1
$KEYLINE
dir $EH
$WATCH
"
forge v2_version ran "devfw-chain 0
$KEYLINE
dir $EH
$WATCH
end
"
forge v3_unknown_line ran "devfw-chain 1
$KEYLINE
dir $EH
x junk
$WATCH
end
"
forge v4_garbage ran $'\001\002garbage\n'
forge v5_no_dir ran "devfw-chain 1
$KEYLINE
$WATCH
end
"
forge v6_empty ran ""
reset_w
until_row pf_cache_corrupt_falls_back_v6_empty

# --- stdin: the fast path reads a prepared input itself (builtins, at most 64 lines); the full path gets ALL of it
shim_rt() {  # shim_rt <row> <want rc> <stdin-file>: the installed shim, run in W the way git runs it
  ( cd "$W" && hk_env && env DEVFW_GK_TRACE=1 "${HKENV[@]}" "$HK/reference-transaction" prepared < "$3" ) \
    >/dev/null 2>"$TMP/.e"; RC=$?
  [ "$RC" -eq "$2" ] && ok "$1" || fail "$1: rc=$RC, want $2: $(cat "$TMP/.e")"
}
SHA=$(git -C "$W" rev-parse HEAD | tr -d '\r')
mkl() { local i; for ((i = 0; i < $1; i++)); do printf '%s %s refs/remotes/origin/n%s\n' "$SHA" "$SHA" "$i"; done; }
{ mkl 70; printf '0000000000000000000000000000000000000000 %s refs/heads/t/77-x\n' "$SHA"; } > "$TMP/long-sel.in"
mkl 70 > "$TMP/long.in"
{ mkl 63; printf '0000000000000000000000000000000000000000 %s refs/heads/t/77-x\n' "$SHA"; } > "$TMP/edge-sel.in"
{ mkl 5; printf '0000000000000000000000000000000000000000 %s refs/heads/t/77-x' "$SHA"; } > "$TMP/short-sel-nonl.in"
mkl 5 > "$TMP/short.in"
shim_rt pf_stdin_long_selected_blocks 1 "$TMP/long-sel.in"
tr_on; shim_rt pf_stdin_long_unselected_allowed 0 "$TMP/long.in"
# over the 64-line limit the fast path does not scan on (bash reads a pipe byte by byte): the full path decides
tr_lines full | grep -q "	reference-transaction	rule" || fail "pf_stdin_long_unselected_allowed: not full/rule: $(cat "$LOG" 2>&1)"
shim_rt pf_stdin_edge_selected_blocks 1 "$TMP/edge-sel.in"
shim_rt pf_stdin_short_selected_no_newline_blocks 1 "$TMP/short-sel-nonl.in"
tr_on; shim_rt pf_stdin_short_unselected_fast 0 "$TMP/short.in"
tr_lines fast | grep -q "	prepared" || fail "pf_stdin_short_unselected_fast: not fast: $(cat "$LOG" 2>&1)"
until_row pf_stdin_short_unselected_fast

# pf_shim_path_forms: the same install run from a dir whose path has spaces, and through a relative $0
SP="$TMP/hook dir x"; mkdir -p "$SP"; cp -r "$HK" "$SP/"
SPHK="$(mp "$SP")/${HK##*/}"
HK="$SPHK" expect pf_shim_path_with_spaces 0 - hk git -C "$W" commit -q --allow-empty -m sp && ok pf_shim_path_with_spaces
HK="$SPHK" expect pf_shim_path_with_spaces_blocks block "no claim for issue 77" hk git -C "$W" checkout -q -b t/77-x \
  && ok pf_shim_path_with_spaces_blocks
REL="../state/git-hooks/${HK##*/}/reference-transaction"
( cd "$W" && [ -x "$REL" ] && hk_env && env "${HKENV[@]}" "$REL" prepared < "$TMP/create.in" ) >/dev/null 2>"$TMP/.e"; RC=$?
[ "$RC" -eq 1 ] && grep -q "devfw reference-transaction: no claim for issue 77" "$TMP/.e" && ok pf_shim_relative_dollar0 \
  || fail "pf_shim_relative_dollar0: rc=$RC $(cat "$TMP/.e")"
until_row pf_shim_relative_dollar0

# --- the rules seam: a rule without <fn>_idle always runs; <fn>_idle decides when it exists (Task 6's seam)
PC="$TMP/plugc"; mkdir -p "$PC/hooks" && cp -r "$PLUGIN/bin" "$PC/bin" && cp -r "$PLUGIN/hooks/git" "$PC/hooks/git"
rules_hk() {
  printf '%s\n' "$1" > "$PC/hooks/git/rules/pre-commit.sh"
  RHK=$("$PC/bin/git-hooks" install --core-dir "$CORE" --state-dir "$TMP/state" | jq -r .dir | tr -d '\r')
}
rules_hk 'gk_pre_commit() { gk_block "rule ran"; }'
HK="$RHK" expect pf_rule_without_idle_runs block "devfw pre-commit: rule ran" hk git -C "$W" commit -q --allow-empty -m ri1 \
  && ok pf_rule_without_idle_runs
rules_hk 'gk_pre_commit() { gk_block "rule ran"; }
gk_pre_commit_idle() { return 1; }'
HK="$RHK" expect pf_rule_idle_busy_runs block "devfw pre-commit: rule ran" hk git -C "$W" commit -q --allow-empty -m ri2 \
  && ok pf_rule_idle_busy_runs
rules_hk 'gk_pre_commit() { gk_block "rule ran"; }
gk_pre_commit_idle() { return 0; }'
hk git -C "$W" commit -q --allow-empty -m ri3-warm >/dev/null 2>&1   # the idle seam runs on the fast path only
HK="$RHK" expect pf_rule_idle_skips 0 - hk git -C "$W" commit -q --allow-empty -m ri3 && ok pf_rule_idle_skips
until_row pf_rule_idle_skips

# --- timing (no trace). Raw numbers first, then the bounded check.
hk git -C "$W" commit -q --allow-empty -m warm2 >/dev/null 2>&1
NC=20
t0=$(now_us); for ((i = 0; i < NC; i++)); do env git -C "$W" commit -q --allow-empty -m "n$i"; done; t1=$(now_us)
for ((i = 0; i < NC; i++)); do hk git -C "$W" commit -q --allow-empty -m "h$i"; done; t2=$(now_us)
NOHK=$(( (t1 - t0) / 1000 / NC )); WHK=$(( (t2 - t1) / 1000 / NC )); ADD=$((WHK - NOHK))
echo "measured commit: without=${NOHK}ms with=${WHK}ms added=${ADD}ms (target <= 600, stretch <= 400)"
[ "$ADD" -le 1500 ] && ok pf_time_commit || fail "pf_time_commit: added ${ADD}ms per commit (bound 1500)"

: > "$TMP/empty.in"
printf '%s %s refs/heads/main\n' "$SHA" "$SHA" > "$TMP/upd.in"
rt_time() {  # rt_time <state> <stdin-file>: mean ms per shim run, the env exported once (no env(1) per run)
  ( cd "$W" && hk_env && export "${HKENV[@]}" && s=$(now_us) \
      && for ((i = 0; i < NC; i++)); do "$HK/reference-transaction" "$1" < "$2" || exit 1; done \
      && e=$(now_us) && echo $(( (e - s) / 1000 / NC )) )
}
B0=$(now_us); for ((i = 0; i < NC; i++)); do bash -c :; done; B1=$(now_us); BASE=$(( (B1 - B0) / 1000 / NC ))
RT1=$(rt_time committed "$TMP/empty.in"); RT2=$(rt_time prepared "$TMP/upd.in")
echo "measured ref-tx no-op run: committed=${RT1}ms prepared-unselected=${RT2}ms (bash -c : = ${BASE}ms; target <= 80)"
[ -n "$RT1" ] && [ "$RT1" -le 250 ] && [ -n "$RT2" ] && [ "$RT2" -le 250 ] && ok pf_time_reftx_noop \
  || fail "pf_time_reftx_noop: committed=${RT1}ms prepared=${RT2}ms (bound 250)"

g -C "$W" branch -q pf-other 2>/dev/null
t0=$(now_us); for ((i = 0; i < 5; i++)); do g -C "$W" checkout -q pf-other; g -C "$W" checkout -q main; done; t1=$(now_us)
for ((i = 0; i < 5; i++)); do hk git -C "$W" checkout -q pf-other; hk git -C "$W" checkout -q main; done; t2=$(now_us)
tr_on; DEVFW_GK_TRACE=1 hk git -C "$W" checkout -q pf-other; RUNS=$(tr_lines reference-transaction | wc -l)
g -C "$W" checkout -q main
echo "measured checkout: without=$(( (t1 - t0) / 10000 ))ms with=$(( (t2 - t1) / 10000 ))ms added=$(( (t2 - t1 - t1 + t0) / 10000 ))ms, $RUNS hook runs"
[ "$RUNS" -ge 1 ] && ok pf_time_checkout_reported || fail "pf_time_checkout_reported: no runs traced"

fx_done
