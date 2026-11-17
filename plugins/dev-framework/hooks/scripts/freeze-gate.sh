#!/bin/bash
# freeze-gate: PreToolUse hook (v6). On a claim branch t/<n>-<slug> of a managed repo, a code edit is allowed
# only when the freeze doc COMMITTED on that branch is approved.
# Rules: (1) no DEVFW_CORE_DIR, or a tool other than Edit|Write|MultiEdit|NotebookEdit -> allow. (2) Scope, with
# no network: the target's repo (nearest existing parent dir; the file may be new) is managed, HEAD is on
# t/<n>-<slug>, the repo-relative path starts with one of repos.<entry>.codePaths (default src/ lib/ app/), and
# it matches none of v5's test patterns. Out of scope -> allow. An unreadable config on a claim branch is in
# scope. (3) fail closed. (4) `git show HEAD:<cycle.freezeDir>/<n>-<slug>/freeze.md` (default docs/plan): the
# approval is read from the committed version, so an uncommitted working-tree edit of the doc changes nothing.
# Missing -> block. (5) front matter status APPROVED, and `freeze-doc-hash.sh verify` matches. (6) approvedBy is
# https://github.com/<plan.repo>/issues/<n>#issuecomment-<id>, same <n> as the branch. (7) cache: if
# "<blob sha> <id>" is a line of <git-dir>/devfw/freeze-ok -> allow. (8) `gh api` reads comment <id>: it must
# belong to issue <n>, its first line must start with `owner-said <n>`, and its author must pass
# lib/acks.js isTrustedAuthor. Then the cache line is appended. Any failure blocks and writes no cache.
# What (8) proves: an owner-said record exists for this ticket and the approval cites it. It does not prove the
# owner typed it (the worker posts it with the owner's token; v6-design C1): that part is convention.
# Removed from v5: the SESSION_DIR pointer, bypass.json, the §11 prerequisites check (order is now `depends:`
# plus the claim). gh is bounded by DEVFW_HOOK_NET_TIMEOUT (default 20s); a timeout blocks.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_v6-hook.sh"
hook_init freeze-gate
[ -n "$HOOK_CORE" ] || exit 0
case "$HOOK_TOOL" in Edit|Write|MultiEdit|NotebookEdit) ;; *) exit 0 ;; esac
TARGET=$(hook_field '.tool_input.file_path // .tool_input.notebook_path')
[ -n "$TARGET" ] || exit 0

# _abs <path>: absolute against HOOK_CWD when relative.
_abs() {
  case "$1" in
    /*|[A-Za-z]:*|\\*) printf '%s\n' "$1" ;;
    *) if [ -n "$HOOK_CWD" ]; then printf '%s/%s\n' "$HOOK_CWD" "$1"; else printf '%s\n' "$1"; fi ;;
  esac
}

# ---- scope: local reads only ----
TARGET=$(_hook_norm "$(_abs "$TARGET")")
D=$(dirname "$TARGET")
while [ ! -d "$D" ]; do
  up=$(dirname "$D"); [ "$up" != "$D" ] || exit 0; D="$up"
done
TOP=$(git -C "$(devfw_path "$D")" rev-parse --show-toplevel 2>/dev/null) || exit 0
TOP=$(_hook_norm "${TOP//$'\r'/}")
[ -n "$TOP" ] && hook_under "$TARGET" "$TOP" || exit 0
REL="${TARGET:${#TOP}}"; REL="${REL#/}"
[ -n "$REL" ] || exit 0
BRANCH=$(git -C "$(devfw_path "$TOP")" symbolic-ref -q --short HEAD 2>/dev/null) || exit 0
BRANCH="${BRANCH//$'\r'/}"
[[ "$BRANCH" =~ ^t/([1-9][0-9]*)-(.+)$ ]] || exit 0
N="${BASH_REMATCH[1]}"; SLUG="${BASH_REMATCH[2]}"
case "$REL" in
    *.test.*|*.spec.*|*_test.*|*/tests/*|*/test/*|tests/*|test/*|*/__tests__/*) exit 0 ;;
esac
CFG_BAD=0
REPO=$(hook_repo_of "$TOP") || CFG_BAD=1
REPO="${REPO//$'\r'/}"
if [ "$CFG_BAD" -eq 0 ]; then
  [ -n "$REPO" ] || exit 0
  # the slug reaches jq through the environment ($ENV), never spliced into the filter text
  CODE=$(HOOK_SLUG="${REPO,,}" hook_cfg '([(.repos // {}) | .[] | select((.github // "") | ascii_downcase == $ENV.HOOK_SLUG)][0].codePaths // ["src/","lib/","app/"]) | .[]') || CFG_BAD=1
  FREEZE_DIR=$(hook_cfg '.cycle.freezeDir' 'docs/plan') || CFG_BAD=1
  PLAN_REPO=$(hook_cfg '.plan.repo') || CFG_BAD=1
fi
if [ "$CFG_BAD" -eq 0 ]; then
  hit=0
  while IFS= read -r c; do
    c="${c%/}"; [ -n "$c" ] || continue
    if [ "$REL" = "$c" ] || [[ "$REL" == "$c/"* ]]; then hit=1; fi
  done <<<"$CODE"
  [ "$hit" -eq 1 ] || exit 0
fi

# ---- in scope: every failure blocks ----
hook_fail_closed
[ "$CFG_BAD" -eq 0 ] || hook_block "cannot read the config; not allowing a code edit on $BRANCH"
TOPW=$(devfw_path "$TOP")
FREEZE_REL="$(_hook_lex "$FREEZE_DIR")/$N-$SLUG/freeze.md"
TMPF=$(mktemp)
eval "$(declare -f hook_block | sed '1s/hook_block/_hb_orig/')"
hook_block() { rm -f "$TMPF"; _hb_orig "$@"; }

git -C "$TOPW" cat-file -e "HEAD:$FREEZE_REL" 2>/dev/null \
  || hook_block "no committed freeze doc at $FREEZE_REL; plan approval comes first"
git -C "$TOPW" show "HEAD:$FREEZE_REL" > "$TMPF"
BLOB=$(git -C "$TOPW" rev-parse "HEAD:$FREEZE_REL" | tr -d '\r')

# _fm <key>: that key's value in the doc's front matter (first ---/--- block), quotes and blanks trimmed.
_fm() {
  awk -v k="$1" '
    NR == 1 { if ($0 ~ /^---[[:space:]]*\r?$/) { in_fm = 1; next } else exit }
    in_fm && /^---[[:space:]]*\r?$/ { exit }
    in_fm && index($0, k ":") == 1 {
      v = substr($0, length(k) + 2); gsub(/\r/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^["\047]|["\047]$/, "", v); print v; exit
    }' "$TMPF"
}

STATUS=$(_fm status)
[ "$STATUS" = APPROVED ] || hook_block "freeze doc status is ${STATUS:-missing}, not APPROVED ($FREEZE_REL)"
bash "$HOOK_LIB_DIR/freeze-doc-hash.sh" verify "$TMPF" >/dev/null 2>&1 \
  || hook_block "freeze doc changed after approval ($FREEZE_REL); it needs a new approval"

[ -n "$PLAN_REPO" ] || hook_block "plan.repo is not set in the config; cannot check the approval"
WANT="https://github.com/$PLAN_REPO/issues/$N#issuecomment-<id>"
AB=$(_fm approvedBy)
[[ "$AB" =~ ^https://github\.com/([^/]+/[^/]+)/issues/([0-9]+)#issuecomment-([1-9][0-9]*)$ ]] \
  || hook_block "approvedBy must be $WANT (found: ${AB:-nothing})"
[ "${BASH_REMATCH[1],,}" = "${PLAN_REPO,,}" ] && [ "${BASH_REMATCH[2]}" = "$N" ] \
  || hook_block "approvedBy must be $WANT (found: $AB)"
ID="${BASH_REMATCH[3]}"

GITDIR=$(git -C "$TOPW" rev-parse --absolute-git-dir | tr -d '\r')
CACHE="$GITDIR/devfw/freeze-ok"
if [ -f "$CACHE" ] && grep -qxF "$BLOB $ID" "$CACHE" 2>/dev/null; then
  rm -f "$TMPF"; exit 0
fi

rc=0
OUT=$(timeout "${DEVFW_HOOK_NET_TIMEOUT:-20}" gh api "repos/$PLAN_REPO/issues/comments/$ID" 2>/dev/null) || rc=$?
OUT="${OUT//$'\r'/}"
[ "$rc" -ne 124 ] || hook_block "cannot read comment $ID: gh timed out"
[ "$rc" -eq 0 ] || hook_block "cannot read comment $ID (gh exit $rc)"
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$OUT" || hook_block "cannot read comment $ID: gh output is not a comment"
IURL=$(jq -r '.issue_url // ""' <<<"$OUT" | tr -d '\r')
[[ "${IURL,,}" == */repos/"${PLAN_REPO,,}"/issues/"$N" ]] \
  || hook_block "comment $ID is not on issue $N of $PLAN_REPO (issue_url: ${IURL:-none})"
FIRST=$(jq -r '(.body // "") | gsub("\r"; "") | split("\n")[0]' <<<"$OUT" | tr -d '\r')
[[ "$FIRST" =~ ^owner-said\ $N( |$) ]] || hook_block "comment $ID does not start with owner-said $N"
rc=0
node -e '
  const fs = require("fs");
  const { isTrustedAuthor } = require(process.argv[1]);
  const p = process.argv[2];
  const config = p && fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, "utf8")) : {};
  const comment = JSON.parse(fs.readFileSync(0, "utf8"));
  process.exit(isTrustedAuthor(comment, config) ? 0 : 3);
' "$(devfw_path "$HOOK_LIB_DIR/../../lib/acks.js")" "$(devfw_path "${DEVFW_CONFIG:-$HOOK_CORE/orchestrator.json}")" \
  <<<"$OUT" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 3 ] || hook_block "comment $ID is not by a trusted author (OWNER/MEMBER/COLLABORATOR or github.trustedAuthors)"
[ "$rc" -eq 0 ] || hook_block "cannot check the author of comment $ID (node exit $rc)"

rm -f "$TMPF"
{ mkdir -p "$GITDIR/devfw" && printf '%s %s\n' "$BLOB" "$ID" >> "$CACHE"; } 2>/dev/null || true
exit 0
