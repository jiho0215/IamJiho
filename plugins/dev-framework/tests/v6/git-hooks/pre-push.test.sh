#!/bin/bash
# hooks/git/rules/pre-push.sh (gk_pre_push): the push rules, read from git's resolved ref lines
# (<local ref> <local sha> <remote ref> <remote sha>), not from command text: scope, session, delete/force,
# destination, default branch, claim (with bin/claim's own create-only push exempt by its shape), needs-ack.
# Every exit has a row; the claim-push exemption has one red row per clause (the seed satisfies every OTHER clause).
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS DEVFW_SESSION_ID DEVFW_CONFIG DEVFW_CORE_DIR CDPATH
for v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_'); do unset "$v"; done
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_fixture.sh"
export GH_MODE=ok
# PP_UNTIL=<row> (mutation runs only): stop with the verdict right after that row reports. Unset = every row.
ok() { echo "ok $1"; [ "${1%% *}" != "${PP_UNTIL:-}" ] || fx_done; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); [ "${1%%:*}" != "${PP_UNTIL:-}" ] || fx_done; }

ORIGIN="$TMP/origin.git"
rsha() { git -C "$ORIGIN" rev-parse -q --verify "refs/$1" 2>/dev/null | tr -d '\r'; }   # rsha heads/<b> | tags/<t>
wsha() { git -C "$W" rev-parse -q --verify "$1" 2>/dev/null | tr -d '\r'; }
# ctree <parent> <message> [<tree-ish>] [-p <second parent>]: a commit in W, nothing checked out or moved
ctree() {
  local p="$1" m="$2" t="${3:-$1}"; shift 3 2>/dev/null || shift $#
  g -C "$W" commit-tree "$t^{tree}" -p "$p" "$@" -m "$m" | tr -d '\r'
}
ffc() { g -C "$W" commit -q --allow-empty -m "$1"; }   # an ff commit on W's checked-out t/41-x
pushed() {  # pushed <name> <heads/b|tags/t> <want sha>: the row's push landed exactly there
  local got; got=$(rsha "$2")
  [ -n "$3" ] && [ "$got" = "$3" ] && ok "$1" || fail "$1: origin $2 is '$got', want '$3'"
}
gh_quiet() { [ ! -s "$GH_LOG" ] || fail "$1: gh was called: $(cat "$GH_LOG")"; }

# --- setup (no hk): main has two commits; issues 41 and 12 are claimed; W has t/41-x checked out; tag v1
echo y > "$W/g"; g -C "$W" add g && g -C "$W" commit -qm second && g -C "$W" push -q origin main || fx_die "main 2nd commit"
"$PLUGIN/bin/claim" 41 x --repo-dir "$W" --base main >/dev/null || fx_die "claim 41"
"$PLUGIN/bin/claim" 12 x --repo-dir "$W" --base main >/dev/null || fx_die "claim 12"
g -C "$W" fetch -q origin || fx_die "fetch"
g -C "$W" checkout -q -b t/41-x origin/t/41-x || fx_die "checkout t/41-x"
g -C "$W" tag v1 main || fx_die "tag"
MAIN=$(wsha origin/main); MAIN1=$(wsha origin/main~1); C41=$(wsha origin/t/41-x)
[ -n "$MAIN" ] && [ -n "$MAIN1" ] && [ -n "$C41" ] || fx_die "setup shas"

# --- rule 5: the default branch
rm -f "$TMP/state/shadow/new.jsonl"
expect pp_default_branch_blocks block "goes through bin/merge" hk git -C "$W" push origin HEAD:main \
  && ok pp_default_branch_blocks
# pp_block_logged: the block row carries the slug, the remote ref and the session
ROW=$(tail -1 "$TMP/state/shadow/new.jsonl" 2>/dev/null | tr -d '\r')
jq -e '.hook == "pre-push" and .repo == "acme/api" and .ref == "refs/heads/main" and .session == "s1"
       and (.reason | startswith("merge to main goes through bin/merge"))' >/dev/null 2>&1 <<<"$ROW" \
  && ok pp_block_logged || fail "pp_block_logged: $ROW"
expect pp_default_branch_case_blocks block "goes through bin/merge" hk git -C "$W" push origin HEAD:refs/heads/MAIN \
  && ok pp_default_branch_case_blocks
NODE_PUSH='const r=require("child_process").execFileSync("git",["-C",process.env.PP_W,"push","origin",process.env.PP_SPEC],{stdio:"inherit"})'
PP_W="$(mp "$W")" PP_SPEC=HEAD:refs/heads/main expect pp_default_via_node block "goes through bin/merge" hk node -e "$NODE_PUSH" \
  && ok pp_default_via_node
expect pp_default_via_url block "goes through bin/merge" hk git -C "$W" push https://github.com/acme/api.git HEAD:main \
  && ok pp_default_via_url

# --- rule 3: delete / force
expect pp_delete_blocks block "remote branch deletion is off" hk git -C "$W" push origin :t/41-x && ok pp_delete_blocks
NONFF=$(ctree "$MAIN" nonff)
expect pp_force_blocks block "force-push is off" hk git -C "$W" push -f origin "$NONFF:refs/heads/t/41-x" \
  && ok pp_force_blocks
# the remote tip is an object this repo does not have (someone else pushed it): cannot prove ff -> force
g clone -q "$ORIGIN" "$TMP/W3" 2>/dev/null && g -C "$TMP/W3" checkout -q t/12-x \
  && g -C "$TMP/W3" commit -q --allow-empty -m elsewhere && g -C "$TMP/W3" push -q origin t/12-x || fx_die "W3 push"
C12=$(wsha origin/t/12-x)
FF12=$(ctree "$C12" ff12)
git -C "$W" cat-file -e "$(rsha heads/t/12-x)" 2>/dev/null && fx_die "W already has the new t/12-x tip"
expect pp_force_missing_remote_object_blocks block "force-push is off" \
  hk git -C "$W" push -f origin "$FF12:refs/heads/t/12-x" && ok pp_force_missing_remote_object_blocks

# --- rule 4: destination
expect pp_tag_skips 0 - hk git -C "$W" push -q origin v1 && pushed pp_tag_skips tags/v1 "$MAIN"
expect pp_devfw_ref_skips 0 - hk git -C "$W" push -q origin "$MAIN:refs/devfw/x" \
  && { [ "$(git -C "$ORIGIN" rev-parse -q --verify refs/devfw/x | tr -d '\r')" = "$MAIN" ] && ok pp_devfw_ref_skips \
       || fail "pp_devfw_ref_skips: refs/devfw/x not on origin"; }
expect pp_other_ref_blocks block "unsupported destination refs/notes/x" hk git -C "$W" push origin HEAD:refs/notes/x \
  && ok pp_other_ref_blocks
: > "$GH_LOG"
expect pp_plain_branch_allowed 0 - hk git -C "$W" push -q origin "$MAIN:refs/heads/feature/merge-x" \
  && pushed pp_plain_branch_allowed heads/feature/merge-x "$MAIN" && gh_quiet pp_plain_branch_allowed

# --- rules 6-7: claim and needs-ack on an ordinary ff push of t/41-x
ffc ff1
expect pp_ff_claimed_allowed 0 - hk git -C "$W" push -q origin t/41-x && pushed pp_ff_claimed_allowed heads/t/41-x "$(wsha HEAD)"
expect pp_unclaimed_blocks block "no claim for issue 77; run bin/claim first" hk git -C "$W" push origin "$MAIN:refs/heads/t/77-x" \
  && ok pp_unclaimed_blocks
ffc ff2
GH_MODE=ack expect pp_needs_ack_blocks block "issue 41 needs-ack: acknowledge the plan change before pushing" \
  hk git -C "$W" push origin t/41-x && ok pp_needs_ack_blocks
GH_MODE=fail expect pp_gh_fail_blocks block "cannot read issue 41" hk git -C "$W" push origin t/41-x && ok pp_gh_fail_blocks
GH_MODE=junk expect pp_gh_junk_blocks block "cannot read issue 41" hk git -C "$W" push origin t/41-x && ok pp_gh_junk_blocks
git -C "$W" config remote.origin.uploadpack /nonexistent
expect pp_claim_fetch_fail_blocks block "cannot verify the claim (fetch failed)" hk git -C "$W" push origin t/41-x \
  && ok pp_claim_fetch_fail_blocks
git -C "$W" config --unset remote.origin.uploadpack
# no plan repo in the install's scope.env: the needs-ack read cannot be made (a hand-edited copy of the hook dir)
cp -r "$HK" "$TMP/hk-noplan" && sed -i 's/^DEVFW_HK_PLAN_REPO=.*/DEVFW_HK_PLAN_REPO=/' "$TMP/hk-noplan/scope.env" \
  && grep -qx 'DEVFW_HK_PLAN_REPO=' "$TMP/hk-noplan/scope.env" || fx_die "hk-noplan"
HK="$(mp "$TMP/hk-noplan")" expect pp_no_plan_repo_blocks block "cannot read issue 41 (no plan repo" \
  hk git -C "$W" push origin t/41-x && ok pp_no_plan_repo_blocks

# --- rule 2: session
mkdir -p "$TMP/state/latch"; : > "$TMP/state/latch/s1"
expect pp_latched_blocks block "session is latched; the owner must clear it" hk git -C "$W" push origin t/41-x \
  && ok pp_latched_blocks
rm -f "$TMP/state/latch/s1"
HK_SESSION= expect pp_no_session_blocks block "no session id; start a new session" hk git -C "$W" push origin t/41-x \
  && ok pp_no_session_blocks

# pp_node_finds_timeout: git spawned by node (no Git Bash in between) still runs the hook, which finds bash + timeout
PP_W="$(mp "$W")" PP_SPEC=t/41-x expect pp_node_finds_timeout 0 - hk node -e "$NODE_PUSH" \
  && pushed pp_node_finds_timeout heads/t/41-x "$(wsha HEAD)"

# pp_c30_no_pathconv: the caller has NO MSYS path-conversion settings; the claim fetch passes src:dst refspecs
ffc ff3
expect pp_c30_no_pathconv 0 - hk env -u MSYS_NO_PATHCONV -u MSYS2_ARG_CONV_EXCL git -C "$(mp "$W")" push -q origin t/41-x \
  && pushed pp_c30_no_pathconv heads/t/41-x "$(wsha HEAD)"

# pp_unmanaged_no_network: other/x is not managed; its fetch side is broken, gh logs every call -> neither is touched
git -C "$U" config remote.origin.uploadpack /nonexistent
echo u2 > "$U/f"; g -C "$U" commit -qam u2
: > "$GH_LOG"
expect pp_unmanaged_no_network 0 - hk git -C "$U" push -q origin main \
  && { [ "$(git -C "$TMP/other.git" rev-parse main | tr -d '\r')" = "$(git -C "$U" rev-parse main | tr -d '\r')" ] \
         && ok pp_unmanaged_no_network || fail "pp_unmanaged_no_network: other.git main not updated"; } \
  && gh_quiet pp_unmanaged_no_network

# --- the claim-push exemption (bin/claim's own create-only push)
: > "$GH_LOG"
# (the claim push skips needs-ack, as bin/claim's push always has: controller ruling Q4)
if expect pp_claim_push_exempt 0 - hk "$PLUGIN/bin/claim" 88 x --repo-dir "$W" --base main; then
  if [ -z "$(rsha heads/t/88-x)" ]; then fail "pp_claim_push_exempt: origin has no t/88-x"
  elif grep -q 'issues/88' "$GH_LOG"; then fail "pp_claim_push_exempt: needs-ack was read for the claim push"
  else ok pp_claim_push_exempt; fi
fi
# each row below fails exactly ONE clause; every other clause holds (parent = origin main tip unless stated)
# tree-equal: the commit's tree (one file) is not main's tree
echo changed > "$TMP/chg"; BLOB=$(git -C "$W" hash-object -w "$TMP/chg" | tr -d '\r')
TREE=$(printf '100644 blob %s\tchanged\n' "$BLOB" | git -C "$W" mktree | tr -d '\r')
S=$(g -C "$W" commit-tree "$TREE" -p "$MAIN" -m $'claim t/89-x\n\nClaim-Issue: 89' | tr -d '\r')
expect pp_claim_shape_with_changes_blocks block "no claim for issue 89" hk git -C "$W" push origin "$S:refs/heads/t/89-x" \
  && ok pp_claim_shape_with_changes_blocks
S=$(ctree "$MAIN1" $'claim t/90-x\n\nClaim-Issue: 90')
expect pp_claim_parent_not_tip_blocks block "no claim for issue 90" hk git -C "$W" push origin "$S:refs/heads/t/90-x" \
  && ok pp_claim_parent_not_tip_blocks
S=$(ctree "$MAIN" $'claim t/41-y\n\nClaim-Issue: 41')
expect pp_claim_second_slug_blocks block "no claim for issue 41" hk git -C "$W" push origin "$S:refs/heads/t/41-y" \
  && ok pp_claim_second_slug_blocks
# remote-sha-zero: t/92-x already exists on origin (unclaimed, at main); the claim-shaped commit is an ff on it
g -C "$W" push -q origin "$MAIN:refs/heads/t/92-x" || fx_die "seed t/92-x"
S=$(ctree "$MAIN" $'claim t/92-x\n\nClaim-Issue: 92')
expect pp_claim_exempt_needs_remote_zero block "no claim for issue 92" hk git -C "$W" push origin "$S:refs/heads/t/92-x" \
  && ok pp_claim_exempt_needs_remote_zero
# one-parent: a merge commit whose FIRST parent is main and whose tree is main's
SIDE=$(ctree "$MAIN1" side)
S=$(ctree "$MAIN" $'claim t/93-x\n\nClaim-Issue: 93' "$MAIN" -p "$SIDE")
expect pp_claim_exempt_needs_one_parent block "no claim for issue 93" hk git -C "$W" push origin "$S:refs/heads/t/93-x" \
  && ok pp_claim_exempt_needs_one_parent
# trailer: Claim-Issue names 940, not 94 (a prefix match or a missing check would take it)
S=$(ctree "$MAIN" $'claim t/94-x\n\nClaim-Issue: 940')
expect pp_claim_exempt_needs_trailer block "no claim for issue 94" hk git -C "$W" push origin "$S:refs/heads/t/94-x" \
  && ok pp_claim_exempt_needs_trailer
# the exemption's ls-remote fails (fetch side broken; the push itself still works): block, saying what failed
git -C "$W" config remote.origin.uploadpack /nonexistent
S=$(ctree "$MAIN" $'claim t/95-x\n\nClaim-Issue: 95')
expect pp_claim_exempt_lsremote_fail_blocks block "cannot verify the claim push (ls-remote failed" \
  hk git -C "$W" push origin "$S:refs/heads/t/95-x" && ok pp_claim_exempt_lsremote_fail_blocks
git -C "$W" config --unset remote.origin.uploadpack

# --- hooks.pushGuard.allowForce: true (a re-install from a config that sets it)
jq '. + {hooks:{pushGuard:{allowForce:true}}}' "$CORE/orchestrator.json" | tr -d '\r' > "$TMP/cfg-force.json"
HK2=$("$GITHOOKS" install --core-dir "$CORE" --config "$(mp "$TMP/cfg-force.json")" --state-dir "$TMP/state" | jq -r .dir | tr -d '\r')
grep -qx 'DEVFW_HK_ALLOW_FORCE=true' "$HK2/scope.env" 2>/dev/null || fx_die "allowForce install: $(cat "$HK2/scope.env" 2>&1)"
BEFORE41=$(rsha heads/t/41-x)
HK="$HK2" expect pp_force_allowed_when_configured 0 - hk git -C "$W" push -q -f origin "$NONFF:refs/heads/t/41-x" \
  && pushed pp_force_allowed_when_configured heads/t/41-x "$NONFF"
g -C "$W" push -q -f origin "$BEFORE41:refs/heads/t/41-x" || fx_die "restore t/41-x"
HK="$HK2" expect pp_delete_allowed_when_configured 0 - hk git -C "$W" push -q origin :t/12-x \
  && { [ -z "$(rsha heads/t/12-x)" ] && ok pp_delete_allowed_when_configured || fail "pp_delete_allowed_when_configured: t/12-x still there"; }
# allowForce does not open the default branch
HK="$HK2" expect pp_force_allowed_default_still_blocks block "goes through bin/merge" \
  hk git -C "$W" push -f origin "$NONFF:refs/heads/main" && ok pp_force_allowed_default_still_blocks

fx_done
