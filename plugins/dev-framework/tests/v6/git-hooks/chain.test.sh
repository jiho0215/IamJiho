#!/bin/bash
# dispatch.sh + gk_chain: the repo's own hooks keep running (default .git/hooks, husky-style relative hooksPath,
# absolute hooksPath), with git's args and stdin, in worktrees and fresh clones, without recursing into ourselves.
# No rules exist in this task, so every push here is otherwise allowed; the rule seam is driven by a scratch plugin.
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS DEVFW_SESSION_ID DEVFW_CONFIG DEVFW_CORE_DIR CDPATH
for v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_'); do unset "$v"; done
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_fixture.sh"

hookfile() {  # hookfile <path> <body...>: an executable sh hook
  local p="$1"; shift
  mkdir -p "$(dirname "$p")"
  { echo '#!/bin/sh'; printf '%s\n' "$@"; } > "$p"; chmod +x "$p"
}
reset_w() {  # no local hooksPath, no repo hooks
  git -C "$W" config --unset-all core.hooksPath 2>/dev/null
  rm -f "$W/.git/hooks/pre-commit" "$W/.git/hooks/pre-push" "$W/.git/hooks/reference-transaction"
  rm -rf "$W/.husky"
}
on_origin() { git -C "$TMP/origin.git" show-ref --verify -q "refs/heads/$1"; }

# ch_default_git_hooks: no core.hooksPath anywhere but ours -> .git/hooks runs
hookfile "$W/.git/hooks/pre-commit" 'echo local-ran >&2' 'exit 1'
expect ch_default_git_hooks block local-ran hk git -C "$W" commit -q --allow-empty -m c1 && ok ch_default_git_hooks
hookfile "$W/.git/hooks/pre-commit" 'echo local-ran >&2' 'exit 0'
expect ch_default_git_hooks_allow 0 local-ran hk git -C "$W" commit -q --allow-empty -m c1 && ok ch_default_git_hooks_allow
reset_w

# ch_local_relative_husky: core.hooksPath=.husky/_ (local, relative)
git -C "$W" config core.hooksPath .husky/_
hookfile "$W/.husky/_/pre-push" 'echo husky-ran >&2' 'exit 1'
expect ch_local_relative_husky block husky-ran hk git -C "$W" push -q origin HEAD:refs/heads/h-1 \
  && ! on_origin h-1 && ok ch_local_relative_husky
hookfile "$W/.husky/_/pre-push" 'echo husky-ran >&2' 'exit 0'
expect ch_local_relative_husky_allow 0 husky-ran hk git -C "$W" push -q origin HEAD:refs/heads/h-1 \
  && on_origin h-1 && ok ch_local_relative_husky_allow

# ch_husky_dir_missing_in_worktree: the worktree shares the relative hooksPath but has no .husky/_ (untracked)
hookfile "$W/.husky/_/pre-push" 'echo husky-ran >&2' 'exit 1'
g -C "$W" worktree add -q "$TMP/W2" -b wt-1 2>/dev/null || fail "setup: worktree add W2"
[ ! -e "$TMP/W2/.husky" ] || fail "setup: W2 has .husky"
if expect ch_husky_dir_missing_in_worktree 0 - hk git -C "$TMP/W2" push -q origin HEAD:refs/heads/wt-1; then
  if grep -qi husky <<<"$ERR"; then fail "ch_husky_dir_missing_in_worktree: stderr mentions husky: $ERR"
  elif on_origin wt-1; then ok ch_husky_dir_missing_in_worktree
  else fail "ch_husky_dir_missing_in_worktree: wt-1 not on origin"; fi
fi
git -C "$W" worktree remove --force "$TMP/W2" 2>/dev/null
reset_w

# ch_absolute_hookspath: core.hooksPath=<abs>/.git/hooks (buckitApi style)
git -C "$W" config core.hooksPath "$(mp "$W/.git/hooks")"
hookfile "$W/.git/hooks/pre-commit" 'echo abs-ran >&2' 'exit 1'
expect ch_absolute_hookspath block abs-ran hk git -C "$W" commit -q --allow-empty -m c2 && ok ch_absolute_hookspath
reset_w

# ch_env_beats_local_rewrite: a later local rewrite (npm install re-running husky) does not displace ours
git -C "$W" config core.hooksPath .elsewhere
expect ch_env_beats_local_rewrite 0 - hk git -C "$W" config --get core.hooksPath \
  && { [ "$OUT" = "$HK" ] && ok ch_env_beats_local_rewrite || fail "ch_env_beats_local_rewrite: got '$OUT' want '$HK'"; }
reset_w

# ch_second_clone: a fresh clone under hk runs our shim (trace on); the trace is off by default
rm -f "$TMP/state/dispatch.log"
expect ch_trace_off_by_default 0 - hk git clone -q "$(mp "$TMP/origin.git")" "$TMP/c0"
[ ! -e "$TMP/state/dispatch.log" ] && ok ch_trace_off_by_default || fail "ch_trace_off_by_default: dispatch.log written"
DEVFW_GK_TRACE=1 expect ch_second_clone 0 - hk git clone -q "$(mp "$TMP/origin.git")" "$TMP/c2"
grep -q "^reference-transaction	" "$TMP/state/dispatch.log" 2>/dev/null && ok ch_second_clone \
  || fail "ch_second_clone: no dispatch trace: $(cat "$TMP/state/dispatch.log" 2>&1)"

# ch_no_recursion: the repo's own hooksPath IS our dir, in C:/ form and then in MSYS /c/ form
git -C "$W" config core.hooksPath "$HK"
EXPECT_T=10 expect ch_no_recursion_m 0 - hk git -C "$W" commit -q --allow-empty -m r1 && ok ch_no_recursion_m
# MSYS forms: /c/... (drive form) and whatever `cygpath -u` prints (/tmp/... when the dir is under the user temp).
# MSYS_NO_PATHCONV keeps Git Bash from turning the value back into C:/ on its way to git.exe.
if command -v cygpath >/dev/null 2>&1; then
  n=0
  for form in "/$(tr 'A-Z' 'a-z' <<<"${HK:0:1}")${HK:2}" "$(cygpath -u "$HK")"; do
    n=$((n + 1))
    MSYS_NO_PATHCONV=1 git -C "$(mp "$W")" config core.hooksPath "$form"
    got=$(git -C "$W" config --get core.hooksPath | tr -d '\r')
    case "$got" in
      [A-Za-z]:*|'') fail "ch_no_recursion_u$n: setup: stored value is not an MSYS form: '$got'"; continue ;;
    esac
    EXPECT_T=10 expect "ch_no_recursion_u$n ($got)" 0 - hk git -C "$W" commit -q --allow-empty -m "r$n" \
      && ok "ch_no_recursion_u$n ($got)"
  done
else
  echo "skip ch_no_recursion_u: no cygpath"
fi
reset_w

# ch_stdin_forwarded: the chained pre-push gets git's args and ref lines unchanged
hookfile "$W/.git/hooks/pre-push" "cat > '$(mp "$TMP/pp.stdin")'" "printf '%s\n' \"\$1\" \"\$2\" > '$(mp "$TMP/pp.args")'"
SHA=$(git -C "$W" rev-parse HEAD | tr -d '\r')
expect ch_stdin_forwarded 0 - hk git -C "$W" push -q origin HEAD:refs/heads/fwd-1
WANT_IN="HEAD $SHA refs/heads/fwd-1 0000000000000000000000000000000000000000"
GOT_IN=$(tr -d '\r' < "$TMP/pp.stdin" 2>/dev/null)
[ "$GOT_IN" = "$WANT_IN" ] && [ "$(head -1 "$TMP/pp.args" 2>/dev/null | tr -d '\r')" = origin ] \
  && ok ch_stdin_forwarded || fail "ch_stdin_forwarded: stdin '$GOT_IN' want '$WANT_IN'; args $(cat "$TMP/pp.args" 2>&1)"
reset_w

# ch_worktree_add_runs_chain: git runs reference-transaction with GIT_DIR set; the chain still resolves
hookfile "$W/.git/hooks/reference-transaction" "echo \"\$1\" >> '$(mp "$TMP/rt.marker")'"
expect ch_worktree_add_runs_chain 0 - hk git -C "$W" worktree add -q -b feature-x "$TMP/wt"
[ -d "$TMP/wt" ] && grep -q committed "$TMP/rt.marker" 2>/dev/null && ok ch_worktree_add_runs_chain \
  || fail "ch_worktree_add_runs_chain: wt=$([ -d "$TMP/wt" ] && echo yes) marker=$(cat "$TMP/rt.marker" 2>&1)"
git -C "$W" worktree remove --force "$TMP/wt" 2>/dev/null
reset_w

# --- the dispatcher's own exits
# ch_depth_bound_blocks: a dir that chains to itself would nest; the bound blocks it
DEVFW_GK_DEPTH=8 expect ch_depth_bound_blocks block "devfw pre-commit: git hooks nested 8 deep" \
  hk git -C "$W" commit -q --allow-empty -m d1 && ok ch_depth_bound_blocks
DEVFW_GK_DEPTH=7 expect ch_depth_below_bound 0 - hk git -C "$W" commit -q --allow-empty -m d2 && ok ch_depth_below_bound

# ch_unknown_hook_blocks: a shim name dispatch.sh does not serve
expect ch_unknown_hook_blocks block "unknown hook 'post-commit'" bash "$PLUGIN/hooks/git/dispatch.sh" post-commit "$HK" \
  && ok ch_unknown_hook_blocks

# ch_broken_install_blocks: a hook dir without scope.env blocks git work
cp -r "$HK" "$TMP/hk-broken"; rm -f "$TMP/hk-broken/scope.env"
HK="$(mp "$TMP/hk-broken")" expect ch_broken_install_blocks block "devfw pre-commit: the git-hook install" \
  hk git -C "$W" commit -q --allow-empty -m b1 && ok ch_broken_install_blocks

# ch_outside_repo_blocks: run outside any repo, the chain cannot find a hooks dir -> block, never a silent pass
mkdir -p "$TMP/norepo"
( cd "$TMP/norepo" && GIT_CEILING_DIRECTORIES="$(mp "$TMP")" bash "$PLUGIN/hooks/git/dispatch.sh" pre-commit "$HK" \
    </dev/null >/dev/null 2>"$TMP/.nr" ); NR=$?
[ "$NR" -eq 1 ] && grep -q "devfw pre-commit: cannot find this repo's git dir" "$TMP/.nr" && ok ch_outside_repo_blocks \
  || fail "ch_outside_repo_blocks: rc=$NR $(cat "$TMP/.nr")"

# --- the rules seam (Tasks 4-6 fill rules/<hook>.sh); driven by a scratch plugin copy
PC="$TMP/plugc"; mkdir -p "$PC/hooks" && cp -r "$PLUGIN/bin" "$PC/bin" && cp -r "$PLUGIN/hooks/git" "$PC/hooks/git"
mkdir -p "$PC/hooks/git/rules"
rules_hk() {  # rules_hk <pre-commit body>: install from the copy with that rules file; sets RHK
  printf '%s\n' "$1" > "$PC/hooks/git/rules/pre-commit.sh"
  RHK=$("$PC/bin/git-hooks" install --core-dir "$CORE" --state-dir "$TMP/state" | jq -r .dir | tr -d '\r')
}
hookfile "$W/.git/hooks/pre-commit" "echo chained >> '$(mp "$TMP/chained.marker")'"
rm -f "$TMP/state/shadow/new.jsonl" "$TMP/chained.marker"
rules_hk 'gk_pre_commit() { gk_block "test rule says no" acme/api refs/heads/x; }'
HK="$RHK" expect ch_rule_block_skips_chain block "devfw pre-commit: test rule says no" \
  hk git -C "$W" commit -q --allow-empty -m rb1
if [ -e "$TMP/chained.marker" ]; then fail "ch_rule_block_skips_chain: the chain ran after a rule block"
else
  ROW=$(tail -1 "$TMP/state/shadow/new.jsonl" 2>/dev/null | tr -d '\r')
  if jq -e '.hook == "pre-commit" and .reason == "test rule says no" and .repo == "acme/api"
            and .ref == "refs/heads/x" and .session == "s1" and (.at | test("^[0-9-]{10}T[0-9:]{8}Z$"))' \
       >/dev/null 2>&1 <<<"$ROW"; then ok ch_rule_block_skips_chain
  else fail "ch_rule_block_skips_chain: shadow row: $ROW"; fi
fi
rules_hk 'gk_pre_commit() { return 0; }'
HK="$RHK" expect ch_rule_allow_runs_chain 0 - hk git -C "$W" commit -q --allow-empty -m rb2 \
  && { [ -e "$TMP/chained.marker" ] && ok ch_rule_allow_runs_chain || fail "ch_rule_allow_runs_chain: chain did not run"; }
rules_hk 'gk_pre_commit() { return 3; }'
HK="$RHK" expect ch_rule_bad_return_blocks block "internal error: gk_pre_commit returned 3" \
  hk git -C "$W" commit -q --allow-empty -m rb3 && ok ch_rule_bad_return_blocks
rules_hk 'gk_something_else() { return 0; }'
HK="$RHK" expect ch_rule_missing_fn_blocks block "rules/pre-commit.sh defines no gk_pre_commit" \
  hk git -C "$W" commit -q --allow-empty -m rb4 && ok ch_rule_missing_fn_blocks
reset_w

fx_done
