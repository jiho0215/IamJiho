#!/bin/bash
# merge-gate-hook.sh (scenario A7): gh pr merge is blocked unless bin/merge-gate passes the PR.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/../../../hooks/scripts/merge-gate-hook.sh"
[ -x "$HOOK" ] || { echo "FAIL: hooks/scripts/merge-gate-hook.sh missing or not executable"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
unset DEVFW_CONFIG DEVFW_CORE_DIR

CORE="$TMP/core"; mkdir -p "$CORE" "$TMP/bin"
echo '{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api"}}}' > "$CORE/orchestrator.json"
LOG="$TMP/gate.log"; LLOG="$TMP/lease.log"; : > "$LOG"; : > "$LLOG"
# Stub merge-gate: logs argv, canned JSON by --pr.
cat > "$TMP/bin/merge-gate" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
pr=""; while [ $# -gt 0 ]; do [ "$1" = --pr ] && pr="$2"; shift; done
case "$pr" in
  1) echo '{"pass":false,"reasons":["cites: stale P-1@abc","size: 400s > 300s"]}' ;;
  2) echo '{"pass":true,"reasons":[]}' ;;
  3) echo '{"error":"x"}'; exit 1 ;;
  4) echo 'boom on stderr' >&2; exit 1 ;;
  5) sleep 5 ;;
esac
STUB
# Stub lease: exit code from $STUB_LEASE_RC.
cat > "$TMP/bin/lease" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LLOG"
[ "${STUB_LEASE_RC:-0}" = 0 ] || echo "lease mismatch: stub"
exit "${STUB_LEASE_RC:-0}"
STUB
chmod +x "$TMP/bin/merge-gate" "$TMP/bin/lease"
export DEVFW_CORE_DIR="$CORE" DEVFW_BIN_DIR="$TMP/bin" STUB_LOG="$LOG" STUB_LLOG="$LLOG"

run() { ERR=$(jq -cn --arg c "$1" --arg cwd "$TMP" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}' | bash "$HOOK" 2>&1 >/dev/null); RC=$?; ERR="${ERR//$'\r'/}"; }
expect() { [ "$RC" = "$1" ] || fail "$2: rc=$RC want $1 (stderr: $ERR)"; }

run 'gh pr merge 1 --repo acme/api --squash'; expect 2 "refused PR"
[ "$(head -1 <<<"$ERR")" = "devfw merge-gate-hook: cites: stale P-1@abc" ] || fail "line 1 is reasons[0]: $ERR"
tail -n +2 <<<"$ERR" | grep -q '^size: 400s > 300s' || fail "later reasons follow: $ERR"
grep -q -- '--pr 1' "$LOG" && grep -q -- '--repo acme/api' "$LOG" && grep -q -- '--core-dir' "$LOG" || fail "gate argv: $(cat "$LOG")"
run 'gh pr merge 2 --repo acme/api --squash'; expect 0 "passing PR"
run 'gh pr merge 3 --repo acme/api'; expect 2 "gate error"
grep -q 'merge-gate could not run: x' <<<"$ERR" || fail "error text: $ERR"
run 'gh pr merge 4 --repo acme/api'; expect 2 "no JSON"
grep -q 'merge-gate could not run: .*boom on stderr' <<<"$ERR" || fail "stderr text: $ERR"
DEVFW_HOOK_GATE_TIMEOUT=1 run 'gh pr merge 5 --repo acme/api'; expect 2 "gate timeout"
grep -q 'merge-gate could not run: timed out' <<<"$ERR" || fail "timeout text: $ERR"

: > "$LOG"
run 'gh pr merge 2 --repo acme/api --auto'; expect 2 "--auto"
grep -q 'never use gh pr merge --auto' <<<"$ERR" || fail "auto text: $ERR"
[ ! -s "$LOG" ] || fail "gate called for --auto: $(cat "$LOG")"
run 'gh pr merge 2 --repo acme/api -d --auto --squash'; expect 2 "--auto among flags"
run 'gh pr merge 2 --squash'; expect 2 "no --repo"
grep -q 'pass --repo <owner/name>' <<<"$ERR" || fail "no-repo text: $ERR"
: > "$LOG"
run 'gh pr merge 1 --repo other/x'; expect 0 "unmanaged repo"
[ ! -s "$LOG" ] || fail "gate called for an unmanaged repo"
run 'gh pr view 1 --repo acme/api'; expect 0 "non-merge gh command"
run 'git status'; expect 0 "no gh at all"
run 'gh api -X PUT repos/acme/api/pulls/1/merge'; expect 2 "gh api merge of a refused PR"
run 'gh api -X PUT repos/acme/api/pulls/2/merge'; expect 0 "gh api merge of a passing PR"
run 'eval "gh pr merge 2 --repo acme/api"'; expect 2 "opaque merge"
grep -q 'cannot read this merge command exactly' <<<"$ERR" || fail "opaque text: $ERR"
run 'eval "gh pr view 2"'; expect 0 "opaque non-merge"
run 'gh pr merge 2 --repo acme/api && gh pr merge 1 --repo acme/api'; expect 2 "second merge refused"
run 'gh pr merge 1 --repo ACME/API'; expect 2 "repo case-insensitive match"

# Plan repo: lease first, then the gate.
: > "$LOG"; : > "$LLOG"
run 'gh pr merge 2 --repo acme/core'; expect 0 "plan repo, lease ok"
grep -q 'check' "$LLOG" || fail "lease not consulted: $(cat "$LLOG")"
STUB_LEASE_RC=4 run 'gh pr merge 2 --repo acme/core'; expect 2 "plan repo, lease mismatch"
grep -q 'only the lease holder merges plan PRs' <<<"$ERR" || fail "lease text: $ERR"
: > "$LOG"; STUB_LEASE_RC=4 run 'gh pr merge 2 --repo acme/api'; expect 0 "lease not consulted for code repos"
: > "$LLOG"; run 'gh pr merge 2 --repo acme/api'; [ ! -s "$LLOG" ] || fail "lease called for code repo"

unset DEVFW_CORE_DIR; run 'gh pr merge 1 --repo acme/api'; expect 0 "DEVFW_CORE_DIR unset"
echo "PASS: merge-gate-hook"
