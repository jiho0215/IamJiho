#!/bin/bash
# reference-transaction rules of the dev-framework git hooks. Sourced by hooks/git/dispatch.sh (after bin/_lib.sh,
# bin/_scope.sh and _git-lib.sh); defines functions only. They read git's own ref lines from stdin
# (<old> <new> <ref>), never the command text, so every command that creates a branch THROUGH A REF TRANSACTION
# (checkout -b, switch -c, branch, branch -f, worktree add -b, update-ref, fetch into a branch, an alias, a commit
# on an orphan branch) meets the same rule.
# NOT SEEN (git 2.53, measured): `git branch -m/-M <old> t/<n>-x` sends only the deletion of <old> (no line names
# the new ref; renaming the CURRENT branch adds only `HEAD -> ref:refs/heads/t/<n>-x`), and `git branch -c/-C` runs
# no reference-transaction hook at all. Such a branch exists locally unchecked; pre-push still blocks pushing it
# (no claim). Refusing the HEAD line instead is not safe: git has already switched the work tree (checkout) or
# renamed the ref (branch -m) when HEAD's transaction is prepared, so a refusal leaves the repo half-done.
#
# gk_ref_tx <state> <stdin-file>: returns 0 or blocks (gk_block <reason> <slug> <ref>). In order:
#   1 only the `prepared` state is checked (the chain still runs for every state);
#   2 select the lines that CREATE a local t/ branch: ref refs/heads/t/* matched case-insensitively (on Windows
#     `refs/heads/T/x` lands in the existing loose refs/heads/t/ directory), old all zeros, new not all zeros.
#     A deletion (git 2.53 sends old and new zeros for `branch -D` and `update-ref -d`) and an update of an existing
#     branch (old non-zero: a commit) are never selected. Pure shell over the saved stdin: when nothing is selected,
#     the rule makes no git or jq call;
#   3 scope: some remote whose raw URL (remote.<r>.url) is managed; none -> allow;
#   4 session: a session id is required, and a latched session creates nothing;
#   5 a t/ branch name must be all lowercase (bin/claim's slugs always are; a loose tracking ref matches a case
#     variant on a case-insensitive file system, so an upper-case name could borrow another slug's evidence);
#     evidence, local only (no network): for refs/heads/t/<n>-<slug>, some managed remote <r> has
#     refs/remotes/<r>/t/<n>-<slug> already, or this same transaction creates or updates it (a fetch into the branch
#     on git 2.53 batches the tracking ref into the same transaction).
#     Known false block: a --single-branch clone (no tracking ref is written) or an older git that does not batch the
#     tracking ref; the block message names the explicit tracking fetch that unblocks it.

# _gk_zero <oid>: 0 when <oid> is all zeros (SHA-1 or SHA-256 length). No fork.
_gk_zero() {
  case "$1" in
    0000000000000000000000000000000000000000|0000000000000000000000000000000000000000000000000000000000000000) return 0 ;;
  esac
  return 1
}

# gk_ref_tx_idle <state>: the dispatcher's fast-path pre-filter (gk_fast). 0 when gk_ref_tx provably has nothing
# to check, without a fork: a state other than `prepared` (rule 1; stdin is not read), or a prepared input of at
# most 64 lines none of which could be selected by rule 2. The test per raw line is a SUPERSET of rule 2: it names
# " refs/heads/t/" in any case (rule 2's ref is the third space-separated field, so a space precedes it) AND holds
# 40 zeros in a row (an all-zero old oid, SHA-1 or SHA-256). A commit on a t/ branch (old non-zero) and HEAD's
# `ref:refs/heads/t/...` symref line are idle; a creation or deletion of a t/ branch is not (gk_ref_tx decides).
# More than 64 lines -> 1 (the full path reads the rest and runs the rule).
gk_ref_tx_idle() {
  [ "$1" = prepared ] || return 0
  gk_stdin_take 64
  [ "$GK_STDIN_EOF" = 1 ] || return 1
  local rest="$GK_STDIN_DATA" line
  while [ -n "$rest" ]; do
    line="${rest%%$'\n'*}"
    if [ "$line" = "$rest" ]; then rest=""; else rest="${rest#*$'\n'}"; fi
    [[ "${line,,}" == *" refs/heads/t/"* && "$line" == *0000000000000000000000000000000000000000* ]] && return 1
  done
  return 0
}

gk_ref_tx() {
  local state="$1" in="$2" old new ref key url r b n t u ok other slug="" line
  local -a sel=() upd=() managed=()
  [ "$state" = prepared ] || return 0

  # 2: selection (builtins only)
  while IFS=' ' read -r old new ref || [ -n "$old" ]; do
    ref="${ref%$'\r'}"
    case "${ref,,}" in
      refs/heads/t/*) _gk_zero "$old" && ! _gk_zero "$new" && sel+=("$ref") ;;
      refs/remotes/*) _gk_zero "$new" || upd+=("$ref") ;;
    esac
  done < "$in"
  [ "${#sel[@]}" -gt 0 ] || return 0

  # 3: scope
  while IFS= read -r line; do
    line="${line%$'\r'}"
    key="${line%% *}"; url="${line#* }"
    r="${key#remote.}"; r="${r%.url}"
    u=$(gk_managed "$url")
    [ -n "$u" ] || continue
    managed+=("$r")
    [ -n "$slug" ] || slug="$u"
  done < <(git config --get-regexp '^remote\..*\.url$' 2>/dev/null)
  [ "${#managed[@]}" -gt 0 ] || return 0

  # 4: session
  [ -n "$GK_SESSION" ] || gk_block "no session id; start a new session" "$slug" "${sel[0]}"
  ! gk_latched || gk_block "session is latched; the owner must clear it" "$slug" "${sel[0]}"

  # 5: evidence
  for ref in "${sel[@]}"; do
    b="${ref#refs/heads/}"
    [ "$b" = "${b,,}" ] || gk_block "branch names under t/ must be lowercase ($b); use ${b,,}" "$slug" "$ref"
    [[ "$b" =~ ^t/([1-9][0-9]*)- ]] || continue
    n="${BASH_REMATCH[1]}"
    ok=""
    for r in "${managed[@]}"; do
      t="refs/remotes/$r/$b"
      if git show-ref --verify -q "$t" 2>/dev/null; then ok=1; break; fi
      for u in "${upd[@]}"; do
        [ "$u" != "$t" ] || { ok=1; break 2; }
      done
    done
    [ -z "$ok" ] || continue
    other=""
    for r in "${managed[@]}"; do
      other=$(git for-each-ref --count=1 --format='%(refname)' "refs/remotes/$r/t/$n-*" 2>/dev/null | tr -d '\r')
      [ -z "$other" ] || { other="${other#refs/remotes/$r/}"; break; }
    done
    [ -z "$other" ] || gk_block "issue $n is claimed as $other" "$slug" "$ref"
    r="${managed[0]}"
    gk_block "no claim for issue $n (no $r/$b); run bin/claim, then git fetch $r +refs/heads/$b:refs/remotes/$r/$b" "$slug" "$ref"
  done
  return 0
}
