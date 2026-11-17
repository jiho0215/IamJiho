#!/bin/bash
# freeze-gate.sh (v6): on a claim branch t/<n>-<slug> of a managed repo, code edits need the freeze doc COMMITTED
# on that branch to be APPROVED, hash-verified, and approved by a trusted `owner-said <n>` comment (cached by blob).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${FG_HOOK:-$DIR/../../../hooks/scripts/freeze-gate.sh}"
HASH="$DIR/../../../hooks/scripts/freeze-doc-hash.sh"
CHASH="${FG_CHASH:-$DIR/../../../hooks/scripts/freeze-content-hash.sh}"
[ -f "$HOOK" ] || { echo "FAIL: hooks/scripts/freeze-gate.sh missing"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
g() { git -c init.defaultBranch=main -c core.autocrlf=false "$@"; }
fail() { echo "FAIL: $*"; exit 1; }
unset DEVFW_CONFIG DEVFW_CORE_DIR DEVFW_HOOK_NET_TIMEOUT
P() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

CORE="$TMP/core"; mkdir -p "$CORE" "$TMP/fakebin" "$TMP/hooktmp"
echo '{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api"}}}' > "$CORE/orchestrator.json"

W="$(P "$TMP")/W"
g init -q "$W"
git -C "$W" remote add origin https://github.com/acme/api.git
mkdir -p "$W/src" "$W/lib"; echo a > "$W/src/a.js"; echo r > "$W/README.md"
g -C "$W" add -A; g -C "$W" commit -qm init
g -C "$W" checkout -q -b t/41-x
U="$(P "$TMP")/U"
g init -q "$U"; git -C "$U" remote add origin https://github.com/other/x.git
mkdir -p "$U/src"; echo a > "$U/src/a.js"; g -C "$U" add -A; g -C "$U" commit -qm init; g -C "$U" checkout -q -b t/41-x

DOC="$W/docs/plan/41-x/freeze.md"
CACHE="$(git -C "$W" rev-parse --absolute-git-dir | tr -d '\r')/devfw/freeze-ok"
AB_OK='https://github.com/acme/core/issues/41#issuecomment-555'
# mkdoc <status> <approvedBy> <body>: writes the doc with a REAL approvedHash (approvedBy is hashed content).
mkdoc() {
  mkdir -p "$(dirname "$DOC")"
  printf -- '---\nstatus: %s\napprovedBy: %s\napprovedHash: PENDING\n---\n# Freeze 41\n%s\n' "$1" "$2" "$3" > "$DOC"
  local h; h=$(bash "$HASH" compute "$DOC") || fail "setup: hash compute"
  sed -i "s/^approvedHash: PENDING\$/approvedHash: $h/" "$DOC"
  bash "$HASH" verify "$DOC" || fail "setup: hash verify"
}
commit_doc() { g -C "$W" add -A docs; g -C "$W" commit -qm "${1:-doc}"; }

# fake gh: GH_MODE = ok | fail | slow | ack | none | n410 | otherissue | login | nocite; GH_CITE = <path>@<hash> cited
cat > "$TMP/fakebin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "${GH_LOG:-/dev/null}"
[ "$*" = "api repos/acme/core/issues/comments/555" ] || exit 1
body="owner-said 41 ${GH_CITE:-none} [2026-11-17T10:00Z] 「승인」\\nsecond line"; assoc=OWNER; iurl='https://api.github.com/repos/acme/core/issues/41'
case "${GH_MODE:-ok}" in
  fail) exit 1 ;;
  slow) sleep 10 ;;
  ack) body='ack 41 abcdef1: ok' ;;
  none) assoc=NONE ;;
  login) assoc=NONE ;;
  n410) body="owner-said 410 ${GH_CITE:-none} ok" ;;
  nocite) body='owner-said 41 [2026-11-17T10:00Z] ok' ;;
  otherissue) iurl='https://api.github.com/repos/acme/core/issues/42' ;;
esac
printf '{"id":555,"body":"%s","author_association":"%s","user":{"login":"trusty"},"issue_url":"%s"}\n' "$body" "$assoc" "$iurl"
STUB
chmod +x "$TMP/fakebin/gh"
export PATH="$TMP/fakebin:$PATH" DEVFW_CORE_DIR="$CORE" GH_LOG="$TMP/gh.log"

# run <path> [tool] [cwd]: feed the hook one tool call.
run() {
  local key=file_path; [ "${2:-Edit}" = NotebookEdit ] && key=notebook_path
  ERR=$(jq -cn --arg t "${2:-Edit}" --arg k "$key" --arg p "$1" --arg cwd "${3-$W}" \
    '{tool_name:$t,cwd:$cwd,tool_input:{($k):$p}}' | TMPDIR="$TMP/hooktmp" bash "$HOOK" 2>&1 >/dev/null); RC=$?
  ERR="${ERR//$'\r'/}"
}
expect() { [ "$RC" = "$1" ] || fail "$2: rc=$RC want $1 (stderr: $ERR)"; }
says() { grep -qF -- "$1" <<<"$ERR" || fail "$2: stderr lacks '$1': $ERR"; }
lines() { if [ -f "$CACHE" ]; then grep -c . "$CACHE"; else echo 0; fi; }

# --- freeze-content-hash.sh: one fence per clause (the hash is a cross-plan contract: owner-said cites it) ---
# H <printf-format>: content hash of a doc written with that printf format.
H() { printf -- "$1" > "$TMP/ch.md"; bash "$CHASH" "$TMP/ch.md" | tr -d '\r'; }
same() { [ "$(H "$1")" = "$(H "$2")" ] || fail "content hash: $3 (should hash the same)"; }
differ() { [ "$(H "$1")" != "$(H "$2")" ] || fail "content hash: $3 (should hash differently)"; }
BASE='---\ntitle: t\n---\n# body\n'
same "---\ntitle: t\nstatus: APPROVED\n---\n# body\n" "$BASE" "status: is stripped in a closed front matter"
same "---\ntitle: t\napprovedBy: x\n---\n# body\n" "$BASE" "approvedBy: is stripped"
same "---\ntitle: t\napprovedAt: 2026-11-17\n---\n# body\n" "$BASE" "approvedAt: is stripped"
same "---\ntitle: t\napprovedHash: abc\n---\n# body\n" "$BASE" "approvedHash: is stripped"
same "---\ntitle: t\nbypassHistory:\n  - at: x\n\t- at: y\n---\n# body\n" "$BASE" "bypassHistory: and its indented list are stripped"
differ "---\ntitle: t\napprovedAt: 2026-11-17\n  sneaky: line\n---\n# body\n" "$BASE" "an indented line after approvedAt: is content (only bypassHistory: owns continuations)"
differ "---\ntitle: t\nbypassHistory:\n  - at: x\nother: y\n---\n# body\n" "$BASE" "a non-indented key after bypassHistory: ends its list"
differ "---\nstatus: DRAFT\n# body\n" "---\nstatus: APPROVED\n# body\n" "an unterminated front matter is hashed whole (status: kept)"
differ "---\ntitle: t\n---\n# body\napprovedAt: x\n" "$BASE" "an approval key in the BODY is content"
differ "title: t\nstatus: A\n" "title: t\nstatus: B\n" "no --- on line 1: no front matter, nothing stripped"
same "---\r\ntitle: t\r\nstatus: X\r\n---\r\n# body\r\n" "$BASE" "CRs are stripped"

# --- no committed doc ---
run "$W/src/a.js"; expect 2 "no committed doc"
says 'devfw freeze-gate: no committed freeze doc at docs/plan/41-x/freeze.md; plan approval comes first' "no doc text"
mkdoc APPROVED "$AB_OK" body; run "$W/src/a.js"; expect 2 "doc only in the working tree, never committed"
says 'no committed freeze doc' "uncommitted doc text"

# --- approved, committed ---
commit_doc approved; APPROVED_SHA=$(git -C "$W" rev-parse HEAD | tr -d '\r')
# the content hash (R16) ignores the approval fields, so the DRAFT and the APPROVED doc hash the same; a body
# change does not
CH=$(bash "$CHASH" "$DOC" | tr -d '\r'); [[ "$CH" =~ ^[0-9a-f]{64}$ ]] || fail "content hash not 64 hex: $CH"
cp "$DOC" "$TMP/approved.md"
mkdoc DRAFT '' body; [ "$(bash "$CHASH" "$DOC" | tr -d '\r')" = "$CH" ] || fail "content hash changed with status/approvedBy/approvedHash"
mkdoc APPROVED "$AB_OK" "other body"; [ "$(bash "$CHASH" "$DOC" | tr -d '\r')" != "$CH" ] || fail "content hash blind to the body"
cp "$TMP/approved.md" "$DOC"; g -C "$W" diff --quiet -- docs || fail "setup: approved doc not restored"
export GH_CITE="docs/plan/41-x/freeze.md@${CH:0:12}"
rm -f "$CACHE"
run "$W/src/a.js"; expect 0 "approved"
[ "$(lines)" = 1 ] || fail "cache should hold one line, has $(lines)"
BLOB=$(git -C "$W" rev-parse "HEAD:docs/plan/41-x/freeze.md" | tr -d '\r')
grep -qxF "$BLOB 555" "$CACHE" || fail "cache line is not '<blob> 555': $(cat "$CACHE")"
GH_MODE=fail run "$W/src/a.js"; expect 0 "served from the cache while gh fails"
[ "$(lines)" = 1 ] || fail "cache hit must not append"
run "$W/src/new/deep/b.js" Write; expect 0 "Write of a new file under a missing dir"
run "$W/src/a.ipynb" NotebookEdit; expect 0 "NotebookEdit approved"
run 'src/a.js' Edit "$W"; expect 0 "relative path against cwd"
if command -v cygpath >/dev/null 2>&1; then run "$(cygpath -w "$W/src/a.js")"; expect 0 "backslash path"; fi

# documented: approval is read from HEAD, so an uncommitted working-tree edit of the doc does not matter
echo "uncommitted scribble" >> "$DOC"
GH_MODE=fail run "$W/src/a.js"; expect 0 "working-tree-only doc edit (approval is read from HEAD)"
g -C "$W" checkout -q -- docs

# gh failures with no cache entry block and write nothing
rm -f "$CACHE"
GH_MODE=fail run "$W/src/a.js"; expect 2 "gh failure, no cache"
says 'devfw freeze-gate: cannot read comment 555' "gh failure text"
[ "$(lines)" = 0 ] || fail "gh failure wrote the cache"
DEVFW_HOOK_NET_TIMEOUT=1 GH_MODE=slow run "$W/src/a.js"; expect 2 "gh timeout"
says 'timed out' "gh timeout text"
[ "$(lines)" = 0 ] || fail "gh timeout wrote the cache"

# --- doc edited and recommitted without re-approval ---
run "$W/src/a.js"; expect 0 "re-prime cache"
echo "sneaky scope change" >> "$DOC"; commit_doc sneaky
run "$W/src/a.js"; expect 2 "recommitted without re-approval"
says 'devfw freeze-gate: freeze doc hash does not verify (edited after approval?): docs/plan/41-x/freeze.md' "changed text"
g -C "$W" reset -q --hard "$APPROVED_SHA"

# --- cache key is the blob: a re-hashed recommit with the same approvedBy is a NEW blob, read fresh ---
[ "$(lines)" = 1 ] || fail "precondition: cache primed for the approved blob"
mkdoc APPROVED "$AB_OK" "body re-hashed by the worker"; commit_doc rehash
GH_MODE=fail run "$W/src/a.js"; expect 2 "re-hashed doc must not ride the cache of another blob"
says 'cannot read comment 555' "cache-key text"
# R16: the old owner-said cites the old content, so the re-hashed doc is not approved
run "$W/src/a.js"; expect 2 "re-hashed doc under the old owner-said"
says 'devfw freeze-gate: owner-said 555 does not approve this freeze doc version (path@hash mismatch); a changed plan needs a new owner-said' "R16 text"
[ "$(lines)" = 1 ] || fail "a path@hash mismatch wrote the cache"
# a new owner-said citing the new content approves it
CH2=$(bash "$CHASH" "$DOC" | tr -d '\r')
GH_CITE="docs/plan/41-x/freeze.md@${CH2:0:12}" run "$W/src/a.js"; expect 0 "new owner-said cites the new content"
[ "$(lines)" = 2 ] || fail "second blob should add a second line, has $(lines)"
g -C "$W" reset -q --hard "$APPROVED_SHA"
# cite forms: full 64-hex upper case ok; 11 hex, a wrong path, no citation at all -> block
rm -f "$CACHE"
GH_CITE="docs/plan/41-x/freeze.md@${CH^^}" run "$W/src/a.js"; expect 0 "full upper-case hash"
rm -f "$CACHE"
GH_CITE="docs/plan/41-x/freeze.md@${CH:0:11}" run "$W/src/a.js"; expect 2 "11-hex hash is too short"
GH_CITE="docs/plan/41-y/freeze.md@${CH:0:12}" run "$W/src/a.js"; expect 2 "wrong path"
GH_CITE="docs/plan/41-x/freeze.md@${CH2:0:12}" run "$W/src/a.js"; expect 2 "hash of another version"
GH_MODE=nocite run "$W/src/a.js"; expect 2 "owner-said without path@hash"
says 'path@hash mismatch' "nocite text"
[ "$(lines)" = 0 ] || fail "a citation mismatch wrote the cache"

# --- status, approvedBy, comment rules (cache cleared so each reaches gh) ---
rm -f "$CACHE"
mkdoc DRAFT "$AB_OK" body; commit_doc draft
run "$W/src/a.js"; expect 2 "status DRAFT"
says 'devfw freeze-gate: freeze doc status is DRAFT, not APPROVED' "draft text"
# out-of-scope edits pass in this blocking world
run "$W/src/a.test.js"; expect 0 "test file"
run "$W/src/__tests__/b.js"; expect 0 "__tests__ dir"
run "$W/README.md"; expect 0 "outside codePaths"
run "$W/lib/x.js"; expect 2 "lib/ is a default code path (control)"
run "$W/src/a.js" Read; expect 0 "not an edit tool"
DEVFW_CORE_DIR= run "$W/src/a.js"; expect 0 "DEVFW_CORE_DIR unset"
run "$U/src/a.js"; expect 0 "unmanaged repo"
g -C "$W" checkout -q -b feature/x; run "$W/src/a.js"; expect 0 "branch feature/x"; g -C "$W" checkout -q t/41-x
run "$(P "$TMP")/nowhere/src/a.js"; expect 0 "not in a git repo"
(cd "$W" && run 'src/a.js' Edit '' && echo "$RC" > "$TMP/rc") ; RC=$(cat "$TMP/rc"); expect 2 "relative path, no cwd: resolved against PWD"
case "${OSTYPE:-}" in
  msys*|cygwin*)
    run "$W/SRC/a.js"; expect 2 "case variant SRC/ on Windows"
    run "$W/Src/new.js" Write; expect 2 "case variant Src/ new file on Windows"
    run "$W/SRC/a.TEST.js"; expect 0 "case variant test file on Windows"
    ;;
esac
echo '{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api","codePaths":["./src/"]}}}' > "$TMP/dot.json"
DEVFW_CONFIG="$TMP/dot.json" run "$W/src/a.js"; expect 2 "codePaths ./src/ normalised"
for bad in '"../x"' '""' '"."' '"/abs"'; do
  echo "{\"plan\":{\"repo\":\"acme/core\"},\"repos\":{\"api\":{\"github\":\"acme/api\",\"codePaths\":[\"src/\",$bad]}}}" > "$TMP/bad.json"
  DEVFW_CONFIG="$TMP/bad.json" run "$W/README.md"; expect 2 "bad codePaths entry $bad"
  says 'bad codePaths entry' "bad codePaths text $bad"
done
# config: codePaths and cycle.freezeDir
echo '{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"ACME/API","codePaths":["pkg/"]}},"cycle":{"freezeDir":"plans"}}' > "$TMP/alt.json"
DEVFW_CONFIG="$TMP/alt.json" run "$W/src/a.js"; expect 0 "codePaths override: src/ no longer code"
DEVFW_CONFIG="$TMP/alt.json" run "$W/pkg/a.js"; expect 2 "codePaths override: pkg/ is code"
says 'no committed freeze doc at plans/41-x/freeze.md' "freezeDir override"
DEVFW_CONFIG="$TMP/missing.json" run "$W/src/a.js"; expect 2 "unreadable config on a claim branch"
says 'cannot read the config' "config text"
g -C "$W" reset -q --hard "$APPROVED_SHA"

mkdoc APPROVED 'https://github.com/acme/core/issues/42#issuecomment-555' body; commit_doc i42
run "$W/src/a.js"; expect 2 "approvedBy names issue 42"
says 'devfw freeze-gate: approvedBy must be https://github.com/acme/core/issues/41#issuecomment-<id>' "i42 text"
g -C "$W" reset -q --hard "$APPROVED_SHA"
mkdoc APPROVED 'https://github.com/other/repo/issues/41#issuecomment-555' body; commit_doc otherrepo
run "$W/src/a.js"; expect 2 "approvedBy names another repo"
g -C "$W" reset -q --hard "$APPROVED_SHA"
mkdoc APPROVED '' body; commit_doc noab
run "$W/src/a.js"; expect 2 "approvedBy missing"
g -C "$W" reset -q --hard "$APPROVED_SHA"

GH_MODE=ack run "$W/src/a.js"; expect 2 "comment is an ack, not owner-said"
says 'devfw freeze-gate: comment 555 does not start with owner-said 41' "ack text"
GH_MODE=n410 run "$W/src/a.js"; expect 2 "owner-said 410 is not owner-said 41"
GH_MODE=none run "$W/src/a.js"; expect 2 "author_association NONE"
says 'devfw freeze-gate: comment 555 is not by a trusted author' "none text"
GH_MODE=otherissue run "$W/src/a.js"; expect 2 "comment belongs to issue 42"
[ "$(lines)" = 0 ] || fail "a rejected comment wrote the cache"
echo '{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api"}},"github":{"trustedAuthors":["Trusty"]}}' > "$TMP/trust.json"
DEVFW_CONFIG="$TMP/trust.json" GH_MODE=login run "$W/src/a.js"; expect 0 "NONE but listed in github.trustedAuthors"

# HOOK_CLEANUP: no run (allowed, blocked, cached, gh failure, timeout) left its temp copy of the doc behind
left=$(ls -A "$TMP/hooktmp"); [ -z "$left" ] || fail "temp files left behind: $left"
echo "PASS freeze-gate"
