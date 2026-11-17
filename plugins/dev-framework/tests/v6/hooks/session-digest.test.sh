#!/bin/bash
# session-digest.sh (SessionStart): digest of origin/<branch>; always exits 0.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/../../../hooks/scripts/session-digest.sh"
[ -x "$HOOK" ] || { echo "FAIL: hooks/scripts/session-digest.sh missing or not executable"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
unset DEVFW_CONFIG DEVFW_CORE_DIR DEVFW_BIN_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

BARE="$TMP/origin.git"; SEED="$TMP/seed"; CORE="$TMP/core"
git init -q --bare -b main "$BARE"; git init -q -b main "$SEED"
mkdir -p "$SEED/docs/plan"
cat > "$SEED/docs/plan/PLAN.md" <<'P'
# Plan

## Stage A

### P-1 · Open one
- stage: A
- kind: code
- state: ready
- area: acme-api

### P-2 · Finished one
- stage: A
- kind: code
- state: done
- area: acme-api

### D-3 · A decision
Text.
P
cat > "$SEED/docs/plan/START-HERE.md" <<'S'
orchestrator: 0123456789abcdef · host-a · since 2026-11-17T10:00:00Z

## Focus
Ship the hooks.

## Later
nope
S
git -C "$SEED" add -A; git -C "$SEED" commit -q -m seed; git -C "$SEED" push -q "$BARE" main
git clone -q "$BARE" "$CORE"

run() { OUT=$(echo '{"hook_event_name":"SessionStart","source":"startup"}' | DEVFW_CORE_DIR="$CORE" bash "$HOOK" 2>/dev/null); RC=$?; OUT="${OUT//$'\r'/}"; }

run; [ "$RC" = 0 ] || fail "reachable: rc=$RC"
SHA=$(git -C "$CORE" rev-parse origin/main | tr -d '\r')
head -1 <<<"$OUT" | grep -q "plan origin/main@${SHA:0:12}" || fail "line 1 lacks sha: $OUT"
head -1 <<<"$OUT" | grep -q STALE && fail "fresh digest marked stale"
grep -q '^orchestrator: 0123456789abcdef' <<<"$OUT" || fail "lease line: $OUT"
grep -q '^Ship the hooks\.$' <<<"$OUT" || fail "focus: $OUT"
grep -q 'nope' <<<"$OUT" && fail "focus leaked into next section"
grep -q '^P-1 · Open one \[ready\]$' <<<"$OUT" || fail "open item: $OUT"
grep -q 'Finished one' <<<"$OUT" && fail "done item listed"
grep -q 'D-3' <<<"$OUT" && fail "decision listed as item"

# a new commit on origin shows up without any manual fetch
git -C "$SEED" commit -q --allow-empty -m two; git -C "$SEED" push -q "$BARE" main
run; SHA2=$(git -C "$CORE" rev-parse origin/main | tr -d '\r')
[ "$SHA2" != "$SHA" ] && head -1 <<<"$OUT" | grep -q "@${SHA2:0:12}" || fail "fetch is not fresh: $OUT"

# origin gone: the old tracking ref still answers, marked STALE, exit 0
rm -rf "$BARE"
run; [ "$RC" = 0 ] || fail "origin deleted: rc=$RC"
head -1 <<<"$OUT" | grep -q '^STALE (fetch failed) · ' || fail "origin deleted, no STALE: $OUT"
head -1 <<<"$OUT" | grep -q "@${SHA2:0:12}" || fail "stale sha: $OUT"

# no origin/<branch> at all: unavailable, exit 0
git -C "$CORE" update-ref -d refs/remotes/origin/main
run; [ "$RC" = 0 ] || fail "no ref: rc=$RC"
grep -q '^dev-framework v6: digest unavailable: ' <<<"$OUT" || fail "no ref: $OUT"

# DEVFW_CORE_DIR unset: inactive line
OUT=$(echo '{}' | bash "$HOOK" 2>/dev/null); RC=$?
[ "$RC" = 0 ] || fail "unset: rc=$RC"
[ "${OUT//$'\r'/}" = 'dev-framework v6: inactive (DEVFW_CORE_DIR not set)' ] || fail "unset: $OUT"
echo "ok session-digest"
