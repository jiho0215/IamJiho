#!/bin/bash
# session-digest.sh (SessionStart): prints the plan digest to stdout. ALWAYS exits 0; every error prints one line.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$DIR/../.."
. "$DIR/_v6-hook.sh"
unavailable() { echo "dev-framework v6: digest unavailable: $1"; exit 0; }
# hook_init would hook_block (exit 2) without jq; this hook must always exit 0.
if [ -n "${DEVFW_CORE_DIR:-}" ] && ! command -v jq >/dev/null 2>&1; then unavailable "jq not found"; fi
hook_init session-digest
if [ -z "$HOOK_CORE" ]; then echo "dev-framework v6: inactive (DEVFW_CORE_DIR not set)"; exit 0; fi
command -v node >/dev/null 2>&1 || unavailable "node not found"
CORE=$(devfw_path "$HOOK_CORE")
BRANCH=$(hook_cfg .plan.branch main) || unavailable "unreadable config"
PPATH=$(hook_cfg .plan.path docs/plan) || unavailable "unreadable config"
STALE=0
timeout "${DEVFW_HOOK_NET_TIMEOUT:-8}" git -C "$CORE" fetch -q --no-write-fetch-head origin "$BRANCH:refs/remotes/origin/$BRANCH" >/dev/null 2>&1 || STALE=1
SHA=$(git -C "$CORE" rev-parse --verify -q "refs/remotes/origin/$BRANCH" 2>/dev/null | tr -d '\r')
[ -n "$SHA" ] || unavailable "origin/$BRANCH not found"
TMP=$(mktemp -d 2>/dev/null) || unavailable "no temp dir"
trap 'rm -rf "$TMP"' EXIT
git -C "$CORE" show "origin/$BRANCH:$PPATH/PLAN.md" > "$TMP/plan" 2>/dev/null || unavailable "$PPATH/PLAN.md not found at origin/$BRANCH"
git -C "$CORE" show "origin/$BRANCH:$PPATH/START-HERE.md" > "$TMP/start" 2>/dev/null || : > "$TMP/start"
VERSION=$(jq -r '.version // empty' "$(devfw_path "$PLUGIN/.claude-plugin/plugin.json")" 2>/dev/null | tr -d '\r')
OUT=$(node "$(devfw_path "$PLUGIN/lib/digest.js")" "$(devfw_path "$TMP/plan")" "$(devfw_path "$TMP/start")" "$SHA" "$BRANCH" "${VERSION:-unknown}" "$STALE" 2>&1) \
  || unavailable "$(head -1 <<<"${OUT//$'\r'/}")"
printf '%s\n' "${OUT//$'\r'/}"
exit 0
