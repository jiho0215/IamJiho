#!/bin/bash
# Shared fixture of the git-hook tests (tests/v6/git-hooks/*.test.sh). Source it AFTER the test file's own
# `unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS ...` line. Only scratch local repos: every GitHub URL below is
# mapped by insteadOf to a local bare repo, and `gh` is a fake first on PATH.
#
#   CORE   a clone of bare core.git; origin https://github.com/acme/core.git (insteadOf -> core.git). main carries
#          orchestrator.json {"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api",...}}} and
#          docs/plan/START-HERE.md with a lease line whose token is in $CORE/.orchestrator/lease, so
#          `bin/lease check --core-dir $CORE` really fetches and passes (checked here).
#   W      a work clone of bare origin.git; origin https://github.com/acme/api.git (insteadOf -> origin.git).
#   U      unmanaged; origin https://github.com/other/x.git (insteadOf -> other.git). Nothing reaches github.com.
#   gh     fake: GH_MODE ok|ack|fail|junk (junk: exit 0 with a body that is not JSON), every call logged to $GH_LOG.
#   HK     the hook dir `bin/git-hooks install --core-dir $CORE --state-dir $TMP/state` returned.
#
#   hk <cmd...>            run <cmd...> with the hooks: GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath
#                          GIT_CONFIG_VALUE_0=$HK DEVFW_SESSION_ID=${HK_SESSION-s1} DEVFW_STATE_DIR=$TMP/state
#                          (HK_SESSION= set but empty gives an empty session id). Setup runs WITHOUT hk.
#   expect <name> <0|block> <stderr-substring|-> <cmd...>
#                          run <cmd...> (an external command, or `hk <cmd...>`) bounded by ${EXPECT_T:-120} s;
#                          0: exit 0; block: exit != 0 AND every bare repo's refs byte-identical before and after.
#                          The substring (unless -) must be in stderr. Sets RC, ERR (stderr), OUT (stdout).
#   fail / ok / fx_done    count failures, print `ok <name>`, and exit with the verdict at the end.
set -uo pipefail
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$FX_DIR/../../.." && pwd)"
GITHOOKS="$PLUGIN/bin/git-hooks"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

# a scratch HOME (no global git config of the developer's leaks in) and a scratch state dir
export HOME="$TMP/home"; mkdir -p "$HOME"
unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE DEVFW_GK_TRACE DEVFW_GK_DEPTH DEVFW_HOOK_BUDGET
export DEVFW_STATE_DIR="$TMP/state"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c core.safecrlf=false "$@"; }

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok() { echo "ok $1"; }
fx_done() { [ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }; echo "ok $(basename "$0")"; exit 0; }
fx_die() { echo "FAIL: fixture: $*"; exit 1; }

# insteadOf <repo> <bare> <url>: the repo's raw <url> reaches the local bare repo
fx_insteadof() { git -C "$1" config "url.$(mp "$2").insteadOf" "$3"; }

# --- core.git / CORE
FX_TOKEN=0123456789abcdef
g init -q --bare "$TMP/core.git" || fx_die "init core.git"
g clone -q "$TMP/core.git" "$TMP/seed" 2>/dev/null || fx_die "clone core.git"
mkdir -p "$TMP/seed/docs/plan"
printf '%s\n' '{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api","default":"main","ci":"none","tests":["true"]}}}' \
  > "$TMP/seed/orchestrator.json"
printf 'orchestrator: %s \302\267 fixture \302\267 since 2026-11-19T00:00:00Z\n\n# Start here\n' "$FX_TOKEN" \
  > "$TMP/seed/docs/plan/START-HERE.md"
printf '.orchestrator/\n' > "$TMP/seed/.gitignore"
g -C "$TMP/seed" add -A && g -C "$TMP/seed" commit -qm "core init" && g -C "$TMP/seed" push -q origin main \
  || fx_die "seed core.git"
rm -rf "$TMP/seed"
CORE="$TMP/CORE"
g clone -q "$TMP/core.git" "$CORE" 2>/dev/null || fx_die "clone CORE"
git -C "$CORE" remote set-url origin https://github.com/acme/core.git
fx_insteadof "$CORE" "$TMP/core.git" https://github.com/acme/core.git
mkdir -p "$CORE/.orchestrator"; printf '%s\n' "$FX_TOKEN" > "$CORE/.orchestrator/lease"
"$PLUGIN/bin/lease" check --core-dir "$CORE" >/dev/null 2>&1 || fx_die "bin/lease check --core-dir \$CORE does not pass"

# --- origin.git / W (managed code repo acme/api)
g init -q --bare "$TMP/origin.git" || fx_die "init origin.git"
W="$TMP/W"
g clone -q "$TMP/origin.git" "$W" 2>/dev/null || fx_die "clone W"
echo x > "$W/f"; g -C "$W" add f && g -C "$W" commit -qm init && g -C "$W" push -q origin main || fx_die "seed W"
git -C "$W" remote set-url origin https://github.com/acme/api.git
fx_insteadof "$W" "$TMP/origin.git" https://github.com/acme/api.git

# --- other.git / U (unmanaged other/x)
g init -q --bare "$TMP/other.git" || fx_die "init other.git"
U="$TMP/U"
g init -q "$U" || fx_die "init U"
git -C "$U" remote add origin https://github.com/other/x.git
fx_insteadof "$U" "$TMP/other.git" https://github.com/other/x.git
echo u > "$U/f"; g -C "$U" add f && g -C "$U" commit -qm init && g -C "$U" push -q origin main || fx_die "seed U"

# --- fake gh: GH_MODE = ok | ack | fail
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "${GH_LOG:-/dev/null}"
case "${GH_MODE:-ok}" in
  fail) exit 1 ;;
  junk) echo 'not json'; exit 0 ;;
  ack) case "$*" in "api repos/acme/core/issues/41") echo '{"labels":[{"name":"needs-ack"}]}'; exit 0 ;; esac; exit 1 ;;
  *) case "$*" in "api repos/acme/core/issues/"[0-9]*) echo '{"labels":[{"name":"p1"}]}'; exit 0 ;; esac; exit 1 ;;
esac
STUB
chmod +x "$TMP/fakebin/gh"
export PATH="$TMP/fakebin:$PATH" GH_LOG="$TMP/gh.log"

# --- the hooks
HK=$("$GITHOOKS" install --core-dir "$CORE" --state-dir "$TMP/state" | jq -r .dir | tr -d '\r') || fx_die "install"
[ -n "$HK" ] && [ -d "$HK" ] || fx_die "install returned no dir"
export HK

hk_env() {
  HKENV=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath "GIT_CONFIG_VALUE_0=$HK"
         "DEVFW_SESSION_ID=${HK_SESSION-s1}" "DEVFW_STATE_DIR=$TMP/state")
}
hk() { hk_env; env "${HKENV[@]}" "$@"; }

fx_refs() {  # every bare repo's refs, byte for byte
  local r
  for r in "$TMP/core.git" "$TMP/origin.git" "$TMP/other.git"; do
    printf '== %s\n' "$r"
    git -C "$r" for-each-ref --format='%(refname) %(objectname)' 2>&1
  done
}

expect() {  # expect <name> <0|block> <stderr-substring|-> <cmd...>
  local name="$1" want="$2" sub="$3" before after
  shift 3
  if [ "${1:-}" = hk ]; then shift; hk_env; set -- env "${HKENV[@]}" "$@"; fi
  before=$(fx_refs)
  RC=0
  timeout "${EXPECT_T:-120}" "$@" >"$TMP/.out" 2>"$TMP/.err" || RC=$?
  OUT=$(tr -d '\r' < "$TMP/.out"); ERR=$(tr -d '\r' < "$TMP/.err")
  case "$want" in
    0) [ "$RC" -eq 0 ] || { fail "$name: rc=$RC, want 0 (stderr: $ERR)"; return 1; } ;;
    block)
      [ "$RC" -ne 0 ] || { fail "$name: rc=0, want a block (stderr: $ERR)"; return 1; }
      [ "$RC" -ne 124 ] || { fail "$name: timed out after ${EXPECT_T:-120}s (stderr: $ERR)"; return 1; }
      after=$(fx_refs)
      [ "$before" = "$after" ] || { fail "$name: a bare repo's refs changed on a block"; return 1; } ;;
    *) fail "$name: bad expect mode $want"; return 1 ;;
  esac
  if [ "$sub" != - ] && ! grep -qF -- "$sub" <<<"$ERR"; then fail "$name: stderr lacks '$sub': $ERR"; return 1; fi
  return 0
}
