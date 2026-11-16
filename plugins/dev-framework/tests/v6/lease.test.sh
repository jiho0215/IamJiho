#!/bin/bash
# lease: show/mine/check/take compare the local token with line 1 of origin's START-HERE.md.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEASE="$DIR/../../bin/lease"
[ -x "$LEASE" ] || { echo "FAIL: bin/lease missing or not executable"; exit 1; }
unset MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL   # Review Focus 4: the script must set these itself
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

g init -q --bare "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/core" 2>/dev/null
mkdir -p "$TMP/core/docs/plan"
printf 'orchestrator: 00000000000000aa · box1 · since 2026-11-16T00:00:00Z\n\n# Start here\n' > "$TMP/core/docs/plan/START-HERE.md"
g -C "$TMP/core" add -A; g -C "$TMP/core" commit -qm init; g -C "$TMP/core" push -q origin main

OUT=$("$LEASE" show --core-dir "$TMP/core")
[ "$(jq -r .token <<<"$OUT")" = "00000000000000aa" ] || { echo "FAIL: show token: $OUT"; exit 1; }
[ "$(jq -r .machine <<<"$OUT")" = "box1" ] || { echo "FAIL: show machine: $OUT"; exit 1; }
[ "$(jq -r .sha <<<"$OUT")" = "$(git -C "$TMP/core" rev-parse origin/main)" ] || { echo "FAIL: show sha: $OUT"; exit 1; }

mkdir -p "$TMP/core/.orchestrator"
echo 00000000000000aa > "$TMP/core/.orchestrator/lease"
[ "$("$LEASE" mine --core-dir "$TMP/core")" = "00000000000000aa" ] || { echo "FAIL: mine"; exit 1; }
"$LEASE" check --core-dir "$TMP/core" || { echo "FAIL: check should match"; exit 1; }

echo 00000000000000bb > "$TMP/core/.orchestrator/lease"
set +e; "$LEASE" check --core-dir "$TMP/core" 2>/dev/null; rc=$?; set -e
[ "$rc" -eq 4 ] || { echo "FAIL: mismatched check exit $rc, want 4"; exit 1; }

TOK=$("$LEASE" take --core-dir "$TMP/core")
L1=$(head -1 "$TMP/core/docs/plan/START-HERE.md")
echo "$L1" | grep -Eq '^orchestrator: [0-9a-f]{16} · .+ · since [0-9TZ:-]{20}$' || { echo "FAIL: take line: $L1"; exit 1; }
[ "$TOK" = "$(echo "$L1" | awk '{print $2}')" ] || { echo "FAIL: take token mismatch"; exit 1; }
[ "$TOK" = "$(cat "$TMP/core/.orchestrator/lease")" ] || { echo "FAIL: take did not write local lease"; exit 1; }
[ "$(sed -n 3p "$TMP/core/docs/plan/START-HERE.md")" = "# Start here" ] || { echo "FAIL: take clobbered body"; exit 1; }
set +e; "$LEASE" check --core-dir "$TMP/core" 2>/dev/null; rc=$?; set -e
[ "$rc" -eq 4 ] || { echo "FAIL: check after take exit $rc, want 4 (must read origin, not working tree)"; exit 1; }

# Review Focus 4: MSYS mangles "origin/main:.dir/file" into "origin\main;.dir\file" (measured);
# "docs/plan" does not trigger it, so use a dot-directory plan path to make this case discriminating.
mkdir -p "$TMP/core/.plan"
printf 'orchestrator: 00000000000000cc · box2 · since 2026-11-16T00:00:00Z\n' > "$TMP/core/.plan/START-HERE.md"
g -C "$TMP/core" add -A; g -C "$TMP/core" commit -qm dotplan; g -C "$TMP/core" push -q origin main
echo '{"plan":{"path":".plan"}}' > "$TMP/cfg.json"
OUT=$(DEVFW_CONFIG="$TMP/cfg.json" "$LEASE" show --core-dir "$TMP/core") || { echo "FAIL: show with dot plan path failed (MSYS mangling?)"; exit 1; }
[ "$(jq -r .token <<<"$OUT")" = "00000000000000cc" ] || { echo "FAIL: dot-path show: $OUT"; exit 1; }

g -C "$TMP/core" rm -qf docs/plan/START-HERE.md; g -C "$TMP/core" commit -qm rm; g -C "$TMP/core" push -q origin main
set +e; "$LEASE" show --core-dir "$TMP/core" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 3 ] || { echo "FAIL: show without file exit $rc, want 3"; exit 1; }

# Important 6: lease reads <core-dir>/orchestrator.json without DEVFW_CONFIG
g -C "$TMP/core" checkout -q -- . 2>/dev/null || true
echo '{"plan":{"path":".plan"}}' > "$TMP/core/orchestrator.json"
OUT=$(env -u DEVFW_CONFIG "$LEASE" show --core-dir "$TMP/core") || { echo "FAIL: lease ignored core-dir config"; exit 1; }
[ "$(jq -r .token <<<"$OUT")" = "00000000000000cc" ] || { echo "FAIL: core-dir config show: $OUT"; exit 1; }
# Important 8: an option-shaped plan.branch is refused before it reaches git
echo '{"plan":{"branch":"--upload-pack=touch PWNED;git-upload-pack"}}' > "$TMP/core/orchestrator.json"
set +e; env -u DEVFW_CONFIG "$LEASE" show --core-dir "$TMP/core" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] || { echo "FAIL: injected plan.branch exit $rc, want 2"; exit 1; }
[ ! -e "$TMP/core/PWNED" ] && [ ! -e PWNED ] || { echo "FAIL: plan.branch executed a command"; exit 1; }
echo ok
