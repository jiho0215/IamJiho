#!/bin/bash
# freeze-gate.sh — PreToolUse hook: block src/** edits unless freeze doc is APPROVED.
#
# Active only when a /dev full-cycle session is in progress (progress-log.json exists,
# mode="full-cycle", branch matches). For other workflows (review/test/docs/init,
# no session, different branch), passes through without blocking.
#
# Exit codes:
#   0 — allow tool call (pass through)
#   2 — block tool call (freeze gate violation)
#
# Fail-closed on corrupt session state (malformed progress-log.json): we must not
# silently disable the gate when the session file can't be read. Unexpected runtime
# errors still fail open via the ERR trap, preserving legitimate workflow.

trap 'exit 0' ERR
set -uo pipefail

# --- Dependency check ---
command -v jq &>/dev/null || exit 0

# --- Read tool input once (stdin can only be read once). ---
INPUT=$(cat 2>/dev/null || echo "{}")
TARGET_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

# --- Shared helpers ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

ts() { iso_utc; }

SESSION_DIR=$(resolve_session_dir)
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
PROGRESS_LOG="$SESSION_DIR/progress-log.json"
BYPASS_FILE="$SESSION_DIR/bypass.json"

# --- Event emit helpers ---
emit_freeze_blocked() {
  local reason="$1" path="${2:-}"
  local data
  data=$(jq -cn --arg reason "$reason" --arg path "$path" \
    '{gate:"freeze",reason:$reason,path:$path}')
  bash "$SCRIPT_DIR/emit-event.sh" gate.blocked --actor "hook:freeze-gate" --data "$data" 2>/dev/null || true
}

emit_freeze_passed() {
  local path="${1:-}"
  local data
  data=$(jq -cn --arg path "$path" '{gate:"freeze",path:$path}')
  bash "$SCRIPT_DIR/emit-event.sh" gate.passed --actor "hook:freeze-gate" --data "$data" 2>/dev/null || true
}

# --- 1. No active session → pass through (normal development is unaffected). ---
[ -f "$PROGRESS_LOG" ] || exit 0

# --- 2. Malformed progress-log.json → fail CLOSED.
#        A corrupt session file must never silently disable the gate. ---
if ! jq empty "$PROGRESS_LOG" 2>/dev/null; then
    echo "[$(ts)] 🛑 FREEZE GATE BLOCKED: progress-log.json is malformed at $PROGRESS_LOG" >&2
    echo "   Target: ${TARGET_PATH:-<unknown>}" >&2
    echo "   Session: $SESSION_DIR" >&2
    echo "   Repair the session file, or delete the session folder and restart /dev." >&2
    emit_freeze_blocked "progress-log malformed" "${TARGET_PATH:-}"
    exit 2
fi

# --- 3. Read session state once. ---
MODE=$(jq -r '.mode // "full-cycle"' "$PROGRESS_LOG" 2>/dev/null)
STATUS=$(jq -r '.status // "unknown"' "$PROGRESS_LOG" 2>/dev/null)
LOGGED_BRANCH=$(jq -r '.branch // empty' "$PROGRESS_LOG" 2>/dev/null)
ACTIVE_FEATURE=$(jq -r '.featureSlug // .ticket // empty' "$PROGRESS_LOG" 2>/dev/null)
FREEZE_DOC_PATH=$(jq -r '.freezeDocPath // empty' "$PROGRESS_LOG" 2>/dev/null)

# --- 4. Only enforce on full-cycle workflows. ---
[ "$MODE" = "full-cycle" ] || exit 0

# --- 5. Workflow already completed → pass through. ---
[ "$STATUS" = "completed" ] && exit 0

# --- 6. Branch mismatch → pass through (user is working elsewhere). ---
if [ -n "$LOGGED_BRANCH" ] && [ "$LOGGED_BRANCH" != "$BRANCH" ]; then
    exit 0
fi

# --- 7. Bypass check (ticket-scoped; feature must match active session). ---
# Emit a warning (not a block) when bypass is missing audit fields — this allows
# development to continue but surfaces the risk that push-guard will later block
# under the same bypass.
if [ -f "$BYPASS_FILE" ]; then
    BYPASS_FEATURE=$(jq -r '.feature // empty' "$BYPASS_FILE" 2>/dev/null)
    BYPASS_REASON=$(jq -r '.reason // empty' "$BYPASS_FILE" 2>/dev/null)
    BYPASS_CREATED=$(jq -r '.createdAt // empty' "$BYPASS_FILE" 2>/dev/null)
    if [ -n "$BYPASS_FEATURE" ] && [ "$BYPASS_FEATURE" = "$ACTIVE_FEATURE" ]; then
        if [ -z "$BYPASS_REASON" ] || [ -z "$BYPASS_CREATED" ]; then
            echo "[$(ts)] freeze-gate: ⚠️  WARNING — bypass.json missing audit fields (reason/createdAt). Edit allowed, but push-guard will block this bypass at push time until it is re-created via 'bypass freeze' in /dev." >&2
        fi
        echo "[$(ts)] freeze-gate: ⚠️  bypass active for '$ACTIVE_FEATURE' — ${BYPASS_REASON:-no reason given}" >&2
        exit 0
    fi
fi

# --- 8. No target path → nothing to enforce on (e.g., non-file tool call). ---
[ -n "$TARGET_PATH" ] || exit 0

# --- 9. Normalize target to repo-relative path for consistent matching. ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
case "$TARGET_PATH" in
    /*) REL_PATH="${TARGET_PATH#$REPO_ROOT/}" ;;
    *)  REL_PATH="$TARGET_PATH" ;;
esac

# --- 10. Scope filter — enforce only on production code directories. ---
# Allowed (blocking applies): src/, lib/, app/.
# Always pass through: tests, docs, configs, scripts, freeze doc.
case "$REL_PATH" in
    src/*|lib/*|app/*) ;;
    *) exit 0 ;;
esac

# Test file patterns — pass through.
case "$REL_PATH" in
    *.test.*|*.spec.*|*_test.*|*/tests/*|*/test/*|tests/*|test/*|*/__tests__/*) exit 0 ;;
esac

# --- 11. Freeze doc path must be recorded in progress-log. ---
if [ -z "$FREEZE_DOC_PATH" ]; then
    echo "[$(ts)] 🛑 FREEZE GATE BLOCKED: /dev session is active but no freezeDocPath recorded." >&2
    echo "   Target: $REL_PATH" >&2
    echo "   Feature: ${ACTIVE_FEATURE:-<unknown>}" >&2
    echo "   Session: $SESSION_DIR" >&2
    echo "   Complete Phase 1-3 of /dev to assemble and approve a freeze doc before editing." >&2
    emit_freeze_blocked "no freezeDocPath in progress-log" "$REL_PATH"
    exit 2
fi

# --- 12. Resolve freeze doc absolute path. ---
case "$FREEZE_DOC_PATH" in
    /*) FREEZE_DOC_ABS="$FREEZE_DOC_PATH" ;;
    *)  FREEZE_DOC_ABS="$REPO_ROOT/$FREEZE_DOC_PATH" ;;
esac

if [ ! -f "$FREEZE_DOC_ABS" ]; then
    echo "[$(ts)] 🛑 FREEZE GATE BLOCKED: freeze doc missing at $FREEZE_DOC_PATH." >&2
    echo "   Target: $REL_PATH" >&2
    echo "   Feature: ${ACTIVE_FEATURE:-<unknown>}" >&2
    echo "   Session: $SESSION_DIR" >&2
    echo "   Complete Phase 1-3 of /dev to create and approve the freeze doc." >&2
    emit_freeze_blocked "freeze doc file missing" "$REL_PATH"
    exit 2
fi

# --- 13. Extract status from YAML frontmatter and enforce APPROVED. ---
DOC_STATUS=$(awk '
    BEGIN { in_fm = 0; dashes_seen = 0 }
    /^---[[:space:]]*$/ {
        dashes_seen++
        if (dashes_seen == 1) { in_fm = 1; next }
        if (dashes_seen == 2) { exit }
    }
    in_fm && /^status:[[:space:]]*/ {
        sub(/^status:[[:space:]]*/, "")
        sub(/[[:space:]]*$/, "")
        print
        exit
    }
' "$FREEZE_DOC_ABS")

if [ "$DOC_STATUS" != "APPROVED" ]; then
    echo "[$(ts)] 🛑 FREEZE GATE BLOCKED: freeze doc status is '${DOC_STATUS:-<missing>}' (need APPROVED)." >&2
    echo "   Target: $REL_PATH" >&2
    echo "   Feature: ${ACTIVE_FEATURE:-<unknown>}" >&2
    echo "   Freeze doc: $FREEZE_DOC_PATH" >&2
    echo "   Session: $SESSION_DIR" >&2
    echo "   Complete Phase 1-3 of /dev and get user approval at GATE 1, or request 'bypass freeze'" >&2
    echo "   to override for this ticket (ticket-scoped; audit trail recorded in freeze doc)." >&2
    emit_freeze_blocked "freeze doc not APPROVED" "$REL_PATH"
    exit 2
fi

# All checks passed — allow the edit.
emit_freeze_passed "$REL_PATH"
exit 0
