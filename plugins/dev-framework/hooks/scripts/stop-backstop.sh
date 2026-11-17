#!/bin/bash
# stop-backstop: Stop hook. Re-runs bin/stop-check for an active cycle run and, when it names a stop code that
# has no matching hand-back, keeps the session going ONCE with an instruction to post the hand-back.
# Rules: (1) stop_hook_active true -> exit 0 (anti-loop: block at most once per stop). (2) cwd not in a git repo,
# or no <git-dir>/devfw/run.json -> exit 0 (run.json's presence is the scope; DEVFW_CORE_DIR is not needed).
# (3) stop-check exit 0 (continue) -> exit 0. (4) exit 10: a handback.json with the same code and round -> exit 0,
# else block. (5) exit 1/2, unreadable output, or a malformed run.json -> block once with the error.
# (6) jq missing (ruling R24): stop_hook_active true or no run.json -> exit 0, else block once.
# Not fail-closed: the worst it can do is make the session continue once.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_v6-hook.sh"
hook_init stop-backstop 25
if [ "$HOOK_HAVE_JQ" -eq 0 ]; then
  # R24 (I2): without jq, read the raw input. Never twice in a row: stop_hook_active true -> allow; no run.json in
  # the cwd's git dir -> allow; else block ONCE (the retry carries stop_hook_active true).
  grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<<"${HOOK_JSON:-}" && exit 0
  RAWCWD=$(hook_raw_str cwd)
  [ -n "$RAWCWD" ] || exit 0
  GD=$(git -C "$(devfw_path "$RAWCWD")" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
  [ -f "${GD//$'\r'/}/devfw/run.json" ] || exit 0
  hook_block "jq not found: cannot check this cycle run's stop state; install jq, then post the hand-back if one is due"
fi
[ "$(hook_field .stop_hook_active)" != true ] || exit 0
[ -n "$HOOK_CWD" ] || exit 0
GD=$(git -C "$(devfw_path "$HOOK_CWD")" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
GD="${GD//$'\r'/}"
RUN="$GD/devfw/run.json"
[ -f "$RUN" ] || exit 0

LEDGER=$(jq -r '.ledger // empty | strings' "$(devfw_path "$RUN")" 2>/dev/null | tr -d '\r') || LEDGER=""
STAGE=$(jq -r '.stage // empty | strings' "$(devfw_path "$RUN")" 2>/dev/null | tr -d '\r') || STAGE=""
ISSUE=$(jq -r '.issue // empty' "$(devfw_path "$RUN")" 2>/dev/null | tr -d '\r') || ISSUE=""
if [ -z "$LEDGER" ] || [ -z "$STAGE" ]; then
  hook_block "stop-check failed: devfw/run.json is unreadable or lacks ledger/stage; record it as stopped ${ISSUE:-<issue>} failed"
fi

SC="${DEVFW_BIN_DIR:-$HOOK_LIB_DIR/../../bin}/stop-check"
ERRF=$(mktemp 2>/dev/null) || ERRF=""
RC=0
hook_net OUT "${ERRF:-null}" 20 bash "$(devfw_path "$SC")" --ledger "$(devfw_path "$LEDGER")" --stage "$STAGE" || RC=$?
SERR=""
[ -z "$ERRF" ] || { SERR=$(tr -d '\r' <"$ERRF" | head -c 400 | tr '\n' ' '); rm -f "$ERRF"; }
OUT="${OUT//$'\r'/}"

[ "$RC" -ne 0 ] || exit 0
if [ "$RC" -eq 10 ]; then
  CODE=$(jq -r '.code // empty' <<<"$OUT" 2>/dev/null | tr -d '\r') || CODE=""
  ROUND=$(jq -r '.round // empty' <<<"$OUT" 2>/dev/null | tr -d '\r') || ROUND=""
  if [ -n "$CODE" ]; then
    HB="$GD/devfw/handback.json"
    if [ -f "$HB" ] && jq -e --arg c "$CODE" --argjson r "${ROUND:-0}" \
         '.code == $c and .round == $r' "$(devfw_path "$HB")" >/dev/null 2>&1; then
      exit 0
    fi
    REASON=$(jq -r '.reason // ""' <<<"$OUT" 2>/dev/null | tr -d '\r')
    hook_block "stop-check says $CODE at round ${ROUND:-?} ($REASON): post \"stopped ${ISSUE:-<issue>} $CODE\" on the ticket and write devfw/handback.json before ending"
  fi
  SERR="unreadable stop-check output: ${OUT:0:200}"
fi
hook_block "stop-check failed: ${SERR:-exit $RC}; record it as stopped ${ISSUE:-<issue>} failed"
