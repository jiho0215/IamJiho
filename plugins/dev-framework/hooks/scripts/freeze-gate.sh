#!/bin/bash
# freeze-gate.sh — PreToolUse hook: block src/** edits unless freeze doc is APPROVED.
#
# v5 contract (per spec §6, no-compat-layer):
#   /implement writes `$SESSION_DIR/active-freeze-doc.txt` at startup pointing at
#   the freeze doc it intends to enforce. Presence of that pointer is the v5
#   "active session" signal. If the SESSION_DIR exists (an /implement run lives
#   here) but the pointer is missing, src/** edits are BLOCKED outright — no
#   silent fallback to v4 progress-log scanning.
#
# Enforcement order:
#   1.  No tool input / no target path                → allow (nothing to gate)
#   2.  Target outside src/lib/app, or test file      → allow (out of scope)
#   3.  SESSION_DIR does not exist on disk            → allow (no session here)
#   4.  Bypass file matches active feature            → allow (escape hatch)
#   5.  No active-freeze-doc.txt pointer              → BLOCK (v5 contract)
#   6.  Pointer points to missing file                → BLOCK
#   7.  Doc status != APPROVED                        → BLOCK
#   8.  Hash mismatch (modified after approval)       → BLOCK
#   9.  Prerequisites unmet                           → BLOCK
#  10.  All gates pass                                → allow
#
# Exit codes:
#   0 — allow tool call (pass through)
#   2 — block tool call (freeze gate violation)
#
# Fail-closed on missing pointer (spec §6); fail-open on unexpected runtime
# errors via the ERR trap so legitimate workflow isn't broken by hook bugs.

trap 'exit 0' ERR
set -uo pipefail

# --- Dependency check ---
command -v jq &>/dev/null || exit 0

# --- Read tool input once (stdin can only be read once). ---
INPUT=$(cat 2>/dev/null || echo "{}")
TARGET_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

# --- Shared helpers ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CLAUDE_PLUGIN_ROOT is set by the harness when the hook fires; fall back to
# SCRIPT_DIR/.. for direct invocation (tests).
: "${CLAUDE_PLUGIN_ROOT:=$(cd "$SCRIPT_DIR/../.." && pwd)}"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

ts() { iso_utc; }

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

# --- 1. No target path → nothing to enforce on (e.g., non-file tool call). ---
[ -n "$TARGET_PATH" ] || exit 0

# --- 2. Normalize target to repo-relative path for consistent matching. ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
case "$TARGET_PATH" in
    /*) REL_PATH="${TARGET_PATH#$REPO_ROOT/}" ;;
    *)  REL_PATH="$TARGET_PATH" ;;
esac

# --- 3. Scope filter — enforce only on production code directories. ---
case "$REL_PATH" in
    src/*|lib/*|app/*) ;;
    *) exit 0 ;;
esac

# Test file patterns — pass through.
case "$REL_PATH" in
    *.test.*|*.spec.*|*_test.*|*/tests/*|*/test/*|tests/*|test/*|*/__tests__/*) exit 0 ;;
esac

# --- 4. Resolve session. If the SESSION_DIR doesn't exist on disk, no
#        /implement run is associated with this branch — allow the edit
#        (v5 is opt-in per active session). ---
SESSION_DIR=$(resolve_session_dir)
if [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

# --- 5. Bypass check (ticket-scoped; escape hatch).
#        The bypass file's `feature` field is matched against the active doc's
#        feature/ticket field below; here we only short-circuit when bypass
#        clearly applies. Missing audit fields → warn (not block). ---
BYPASS_FILE="$SESSION_DIR/bypass.json"

# --- 6. Resolve active freeze doc pointer (v5 contract). ---
ACTIVE_DOC=$(resolve_active_freeze_doc "$SESSION_DIR")

if [ -z "$ACTIVE_DOC" ]; then
    # Spec §6: no active doc pointer means no /implement run wrote it. Block.
    # (An existing SESSION_DIR with no pointer indicates either an old/v4
    # session or an interrupted /implement startup — fail closed either way.)
    echo "[$(ts)] 🛑 FREEZE GATE BLOCKED: no active-freeze-doc.txt in SESSION_DIR ($SESSION_DIR)." >&2
    echo "       v5 /implement writes this pointer at startup. If missing," >&2
    echo "       /implement is not running here. src/** edits are blocked" >&2
    echo "       until /implement starts with: /implement <freeze-doc-path>." >&2
    echo "   Target: $REL_PATH" >&2
    emit_freeze_blocked "no active-freeze-doc.txt pointer" "$REL_PATH"
    exit 2
fi

# Resolve to absolute path (pointer may contain repo-relative or absolute).
case "$ACTIVE_DOC" in
    /*) ACTIVE_DOC_ABS="$ACTIVE_DOC" ;;
    *)  ACTIVE_DOC_ABS="$REPO_ROOT/$ACTIVE_DOC" ;;
esac

if [ ! -f "$ACTIVE_DOC_ABS" ]; then
    echo "[$(ts)] 🛑 FREEZE GATE BLOCKED: active freeze doc pointer points to missing file: $ACTIVE_DOC" >&2
    echo "   Pointer: $SESSION_DIR/active-freeze-doc.txt" >&2
    echo "   Target: $REL_PATH" >&2
    emit_freeze_blocked "active freeze doc missing" "$REL_PATH"
    exit 2
fi

# --- 7. Bypass: extract active feature/ticket from the doc and compare. ---
ACTIVE_FEATURE=$(awk '
    BEGIN { in_fm = 0; dashes_seen = 0 }
    /^---[[:space:]]*$/ {
        dashes_seen++
        if (dashes_seen == 1) { in_fm = 1; next }
        if (dashes_seen == 2) { exit }
    }
    in_fm && /^(featureSlug|ticket):[[:space:]]*/ {
        sub(/^(featureSlug|ticket):[[:space:]]*/, "")
        sub(/[[:space:]]*$/, "")
        gsub(/"/, "")
        print
        exit
    }
' "$ACTIVE_DOC_ABS")

if [ -f "$BYPASS_FILE" ]; then
    BYPASS_FEATURE=$(jq -r '.feature // empty' "$BYPASS_FILE" 2>/dev/null)
    BYPASS_REASON=$(jq -r '.reason // empty' "$BYPASS_FILE" 2>/dev/null)
    BYPASS_CREATED=$(jq -r '.createdAt // empty' "$BYPASS_FILE" 2>/dev/null)
    if [ -n "$BYPASS_FEATURE" ] && [ "$BYPASS_FEATURE" = "$ACTIVE_FEATURE" ]; then
        if [ -z "$BYPASS_REASON" ] || [ -z "$BYPASS_CREATED" ]; then
            echo "[$(ts)] freeze-gate: ⚠️  WARNING — bypass.json missing audit fields (reason/createdAt). Edit allowed, but push-guard will block this bypass at push time until it is re-created via 'bypass freeze' in /implement." >&2
        fi
        echo "[$(ts)] freeze-gate: ⚠️  bypass active for '$ACTIVE_FEATURE' — ${BYPASS_REASON:-no reason given}" >&2
        emit_freeze_passed "$REL_PATH"
        exit 0
    fi
fi

# --- 8. Status check (must be APPROVED). ---
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
        gsub(/"/, "")
        print
        exit
    }
' "$ACTIVE_DOC_ABS")

if [ "$DOC_STATUS" != "APPROVED" ]; then
    echo "[$(ts)] 🛑 FREEZE GATE BLOCKED: freeze doc status is '${DOC_STATUS:-<missing>}' (need APPROVED)." >&2
    echo "   Target: $REL_PATH" >&2
    echo "   Feature: ${ACTIVE_FEATURE:-<unknown>}" >&2
    echo "   Freeze doc: $ACTIVE_DOC" >&2
    echo "   Session: $SESSION_DIR" >&2
    echo "   Complete /implement Phase 1-3 and approve at GATE 1, or request 'bypass freeze' to override for this ticket (audit-trailed)." >&2
    emit_freeze_blocked "freeze doc not APPROVED" "$REL_PATH"
    exit 2
fi

# --- 9. Hash check — doc must not have been modified after approval. ---
if ! bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/freeze-doc-hash.sh" verify "$ACTIVE_DOC_ABS" >/dev/null 2>&1; then
    echo "[$(ts)] 🛑 FREEZE GATE BLOCKED: freeze doc hash mismatch (modified after approval)." >&2
    echo "   Target: $REL_PATH" >&2
    echo "   Freeze doc: $ACTIVE_DOC" >&2
    echo "   Re-run /implement (or /spike re-approval) to re-approve the current contents." >&2
    emit_freeze_blocked "freeze doc hash mismatch" "$REL_PATH"
    exit 2
fi

# --- 10. Prerequisite check — every §11 ticket must be merged. ---
if ! SESSION_DIR="$SESSION_DIR" bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/freeze-doc-prereqs.sh" "$ACTIVE_DOC_ABS" >&2; then
    echo "[$(ts)] 🛑 FREEZE GATE BLOCKED: prerequisites not satisfied (see above)." >&2
    echo "   Target: $REL_PATH" >&2
    echo "   Freeze doc: $ACTIVE_DOC" >&2
    emit_freeze_blocked "prerequisites unmet" "$REL_PATH"
    exit 2
fi

# All checks passed — allow the edit.
emit_freeze_passed "$REL_PATH"
exit 0
