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
# belong to issue <n>, its first line must be `owner-said <n> <path>@<hash12+> …` (ruling R16) with <path> the
# doc's repo-relative path and <hash> a prefix of freeze-content-hash.sh over the committed doc (so a doc edited,
# re-hashed and recommitted under the same approvedBy is a new blob, is re-read, and fails), and its author must
# pass lib/acks.js isTrustedAuthor. Then the cache line is appended. Any failure blocks and writes no cache.
# What (8) proves: an owner-said record for this exact plan content exists for this ticket and the approval cites
# it. It does not prove the owner typed it (the worker posts it with the owner's token; v6-design C1): convention.
# Paths compare case-insensitively on Windows (msys/cygwin), like hook_under. codePaths entries are normalised
# lexically; one that is empty, ".", absolute or climbs out with ".." blocks in-scope edits as a config error.
# jq missing (ruling R24): an Edit-family call whose target's repo is on t/<n>-... blocks; anything else is allowed.
# Bash file writes (cat >, sed -i, cp, ...) are NOT seen: this hook is wired to the Edit tools only (ruling R26).
# Removed from v5: the SESSION_DIR pointer, bypass.json, the §11 prerequisites check (order is now `depends:`
# plus the claim). gh is bounded by DEVFW_HOOK_NET_TIMEOUT (default 20s); a timeout blocks.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_v6-hook.sh"
hook_init freeze-gate 25
[ -n "$HOOK_CORE" ] || exit 0

# _parent_dir <path>: the nearest existing directory holding <path> (the file may be new); exits 0 when none.
_parent_dir() {
  local d up
  d=$(dirname "$1")
  while [ ! -d "$d" ]; do
    up=$(dirname "$d"); [ "$up" != "$d" ] || exit 0; d="$up"
  done
  P_D="$d"
}

if [ "$HOOK_HAVE_JQ" -eq 0 ]; then
  # R24: without jq, read the raw input; an edit whose repo is on a claim branch t/<n>-... blocks, anything else
  # is allowed (the code-path and managed-repo tests need the config, which needs jq).
  grep -Eq '"tool_name"[[:space:]]*:[[:space:]]*"(Edit|Write|MultiEdit|NotebookEdit)"' <<<"${HOOK_JSON:-}" || exit 0
  RT=$(hook_raw_str file_path); [ -n "$RT" ] || RT=$(hook_raw_str notebook_path)
  [ -n "$RT" ] || exit 0
  RC_=$(hook_raw_str cwd)
  _parent_dir "$(_hook_norm "$(hook_abs "$RT" "${RC_:-$PWD}")")"
  RB=$(git -C "$(devfw_path "$P_D")" symbolic-ref -q --short HEAD 2>/dev/null) || exit 0
  [[ "${RB//$'\r'/}" =~ ^t/[1-9][0-9]*- ]] || exit 0
  hook_block "jq not found: cannot check the freeze doc for a code edit on ${RB//$'\r'/}; install jq"
fi

case "$HOOK_TOOL" in Edit|Write|MultiEdit|NotebookEdit) ;; *) exit 0 ;; esac
TARGET=$(hook_field '.tool_input.file_path // .tool_input.notebook_path')
[ -n "$TARGET" ] || exit 0

# ---- scope: local reads only ----
TARGET=$(_hook_norm "$(hook_abs "$TARGET" "${HOOK_CWD:-$PWD}")")
_parent_dir "$TARGET"; D="$P_D"
TOP=$(git -C "$(devfw_path "$D")" rev-parse --show-toplevel 2>/dev/null) || exit 0
TOP=$(_hook_norm "${TOP//$'\r'/}")
[ -n "$TOP" ] && hook_under "$TARGET" "$TOP" || exit 0
REL="${TARGET:${#TOP}}"; REL="${REL#/}"
[ -n "$REL" ] || exit 0
BRANCH=$(git -C "$(devfw_path "$TOP")" symbolic-ref -q --short HEAD 2>/dev/null) || exit 0
BRANCH="${BRANCH//$'\r'/}"
[[ "$BRANCH" =~ ^t/([1-9][0-9]*)-(.+)$ ]] || exit 0
N="${BASH_REMATCH[1]}"; SLUG="${BASH_REMATCH[2]}"
# Windows file systems ignore case: compare the path (code paths and test patterns) case-insensitively there,
# the same rule as hook_under.
REL_CMP="$REL"; NOCASE=0
case "${OSTYPE:-}" in msys*|cygwin*) REL_CMP="${REL,,}"; NOCASE=1 ;; esac
case "$REL_CMP" in
    *.test.*|*.spec.*|*_test.*|*/tests/*|*/test/*|tests/*|test/*|*/__tests__/*) exit 0 ;;
esac
CFG_BAD=0
REPO=$(hook_repo_of "$TOP") || CFG_BAD=1
REPO="${REPO//$'\r'/}"
if [ "$CFG_BAD" -eq 0 ]; then
  [ -n "$REPO" ] || exit 0
  # the slug reaches jq through the environment ($ENV), never spliced into the filter text
  CODE=$(HOOK_SLUG="${REPO,,}" hook_cfg '([(.repos // {}) | .[] | select((.github // "") | ascii_downcase == $ENV.HOOK_SLUG)][0].codePaths // ["src/","lib/","app/"]) | .[] | tostring | if . == "" then "." else . end') || CFG_BAD=1
  FREEZE_DIR=$(hook_cfg '.cycle.freezeDir' 'docs/plan') || CFG_BAD=1
  PLAN_REPO=$(hook_cfg '.plan.repo') || CFG_BAD=1
fi
BAD_CP=""
if [ "$CFG_BAD" -eq 0 ]; then
  hit=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    raw="$c"; c=$(_hook_lex "$c")
    case "$c" in
      .|..|../*|/*|[A-Za-z]:*) BAD_CP="$raw"; continue ;;
    esac
    [ "$NOCASE" -eq 0 ] || c="${c,,}"
    if [ "$REL_CMP" = "$c" ] || [[ "$REL_CMP" == "$c/"* ]]; then hit=1; fi
  done <<<"$CODE"
  [ "$hit" -eq 1 ] || [ -n "$BAD_CP" ] || exit 0
fi

# ---- in scope: every failure blocks ----
hook_fail_closed
[ "$CFG_BAD" -eq 0 ] || hook_block "cannot read the config; not allowing a code edit on $BRANCH"
[ -z "$BAD_CP" ] || hook_block "bad codePaths entry \"$BAD_CP\" for $REPO (must name a directory inside the repo)"
TOPW=$(devfw_path "$TOP")
FREEZE_REL="$(_hook_lex "$FREEZE_DIR")/$N-$SLUG/freeze.md"
TMPF=$(mktemp)
_fg_cleanup() { rm -f "$TMPF"; }
HOOK_CLEANUP=_fg_cleanup   # runs on every exit from here: hook_block and the EXIT trap

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
  || hook_block "freeze doc hash does not verify (edited after approval?): $FREEZE_REL"

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
  exit 0
fi

rc=0
hook_net OUT null "${DEVFW_HOOK_NET_TIMEOUT:-20}" gh api "repos/$PLAN_REPO/issues/comments/$ID" || rc=$?
OUT="${OUT//$'\r'/}"
[ "$rc" -ne 124 ] || hook_block "cannot read comment $ID: gh timed out"
[ "$rc" -eq 0 ] || hook_block "cannot read comment $ID (gh exit $rc)"
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$OUT" || hook_block "cannot read comment $ID: gh output is not a comment"
IURL=$(jq -r '.issue_url // ""' <<<"$OUT" | tr -d '\r')
[[ "${IURL,,}" == */repos/"${PLAN_REPO,,}"/issues/"$N" ]] \
  || hook_block "comment $ID is not on issue $N of $PLAN_REPO (issue_url: ${IURL:-none})"
FIRST=$(jq -r '(.body // "") | gsub("\r"; "") | split("\n")[0]' <<<"$OUT" | tr -d '\r')
[[ "$FIRST" =~ ^owner-said\ $N( |$) ]] || hook_block "comment $ID does not start with owner-said $N"
# R16: the owner-said line binds the approval to this content: `owner-said <n> <path>@<hash12+> …`, where <hash>
# is a prefix of freeze-content-hash.sh over the committed doc (approval fields removed) and <path> is the doc.
CHASH=$(bash "$HOOK_LIB_DIR/freeze-content-hash.sh" "$TMPF" | tr -d '\r')
[[ "$CHASH" =~ ^[0-9a-f]{64}$ ]] || hook_block "cannot compute the content hash of $FREEZE_REL"
CITED_OK=0
if [[ "$FIRST" =~ ^owner-said\ $N\ ([^[:space:]]+)@([0-9A-Fa-f]{12,64})([[:space:]]|$) ]]; then
  cited="${BASH_REMATCH[2],,}"
  if [ "${BASH_REMATCH[1]}" = "$FREEZE_REL" ] && [ "${CHASH:0:${#cited}}" = "$cited" ]; then CITED_OK=1; fi
fi
[ "$CITED_OK" -eq 1 ] || hook_block "owner-said $ID does not approve this freeze doc version (path@hash mismatch); a changed plan needs a new owner-said" \
  "expected: owner-said $N $FREEZE_REL@${CHASH:0:12} …"
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

{ mkdir -p "$GITDIR/devfw" && printf '%s %s\n' "$BLOB" "$ID" >> "$CACHE"; } 2>/dev/null || true
exit 0
