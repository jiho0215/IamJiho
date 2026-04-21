#!/bin/bash
# push-guard.sh — PreToolUse hook: block git push until the /implement full-cycle
# workflow is marked complete (or user has explicitly bypassed for this ticket).
#
# A branch that never used /implement is not guarded (no session folder). A branch
# that has an active session must either show a pipeline-complete.md marker
# (GATE 2 approval) or a ticket-scoped bypass.json to proceed.
#
# No ERR trap — this hook intentionally blocks (exit 2) on violation.

set -euo pipefail

# --- Shared helpers (sourced before jq check so emit-event can no-op safely) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

emit_push_blocked() {
  local reason="$1"
  bash "$SCRIPT_DIR/emit-event.sh" gate.blocked --actor "hook:push-guard" \
    --data "$(jq -cn --arg reason "$reason" '{gate:"push",reason:$reason}' 2>/dev/null || echo '{}')" \
    2>/dev/null || true
}

emit_push_passed() {
  local reason="${1:-}"
  bash "$SCRIPT_DIR/emit-event.sh" gate.passed --actor "hook:push-guard" \
    --data "$(jq -cn --arg reason "$reason" '{gate:"push",reason:$reason}' 2>/dev/null || echo '{}')" \
    2>/dev/null || true
}

# --- Dependency check (fail safe — block if jq missing) ---
if ! command -v jq &>/dev/null; then
    echo "BLOCKED: jq required for push-guard. Install jq or use --force to bypass." >&2
    emit_push_blocked "jq not available"
    exit 2
fi

CONFIG="$DEVFW_CONFIG"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

# Broader match for git push variants (git -c key=val push, etc.)
echo "$COMMAND" | grep -qE '\bgit\b.*\bpush\b' || exit 0

# Allow force pushes (escape hatch — read flags from config, default --force/-f)
if [ -f "$CONFIG" ] && jq -e '.hooks.pushGuard.escapeFlags' "$CONFIG" &>/dev/null; then
    ESCAPE_FLAGS=$(jq -r '.hooks.pushGuard.escapeFlags[]' "$CONFIG" 2>/dev/null | tr -d '\r')
else
    ESCAPE_FLAGS=$(printf '%s\n' '--force' '-f')
fi
while IFS= read -r flag; do
    [ -z "$flag" ] && continue
    # Word-boundary match so --force does NOT match --force-if-includes (a safer
    # git flag that should NOT bypass push-guard). Flags are whitespace-separated
    # tokens in the command string.
    if echo " $COMMAND " | grep -qE "([[:space:]])$(printf '%s' "$flag" | sed 's/[.[\*^$()+?{|]/\\&/g')([[:space:]=])"; then
        emit_push_passed "escape flag present"
        exit 0
    fi
done <<< "$ESCAPE_FLAGS"

# Get branch (handle detached HEAD)
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null) || {
    echo "WARNING: Detached HEAD. Push guard bypassed." >&2
    exit 0
}
[ -n "$BRANCH" ] || {
    echo "WARNING: Not inside a git repository. Push guard skipped." >&2
    exit 0
}

SESSION_DIR=$(resolve_session_dir)
MARKER="$SESSION_DIR/pipeline-complete.md"
BYPASS_FILE="$SESSION_DIR/bypass.json"

# Only guard branches that have a session folder (i.e., /implement was started for this branch or epic).
# Branches that never used /implement are not blocked — regular development proceeds normally.
if [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

# Full-cycle completion marker present and branch matches exactly → allow.
if [ -f "$MARKER" ] && grep -qxF "Pipeline completed for branch: $BRANCH" "$MARKER" 2>/dev/null; then
    emit_push_passed "pipeline-complete marker"
    exit 0
fi

PROGRESS_LOG="$SESSION_DIR/progress-log.json"
ACTIVE_FEATURE=""
MODE="full-cycle"
STATUS="unknown"
if [ -f "$PROGRESS_LOG" ]; then
    ACTIVE_FEATURE=$(jq -r '.featureSlug // .ticket // empty' "$PROGRESS_LOG" 2>/dev/null)
    MODE=$(jq -r '.mode // "full-cycle"' "$PROGRESS_LOG" 2>/dev/null)
    STATUS=$(jq -r '.status // "unknown"' "$PROGRESS_LOG" 2>/dev/null)
fi

# Ticket-scoped bypass: only valid when bypass feature matches current session feature
# AND the bypass has all required audit fields (feature, reason, createdAt).
if [ -f "$BYPASS_FILE" ]; then
    BYPASS_FEATURE=$(jq -r '.feature // empty' "$BYPASS_FILE" 2>/dev/null)
    BYPASS_REASON=$(jq -r '.reason // empty' "$BYPASS_FILE" 2>/dev/null)
    BYPASS_CREATED=$(jq -r '.createdAt // empty' "$BYPASS_FILE" 2>/dev/null)
    if [ -n "$BYPASS_FEATURE" ] && [ -n "$BYPASS_REASON" ] && [ -n "$BYPASS_CREATED" ]; then
        if [ -z "$ACTIVE_FEATURE" ]; then
            echo "🛑 BLOCKED: bypass.json has feature '$BYPASS_FEATURE' but session has no featureSlug/ticket recorded." >&2
            echo "   The session may not be fully initialized. Run /implement to initialize, then retry." >&2
            emit_push_blocked "bypass feature without active session feature"
            exit 2
        fi
        if [ "$BYPASS_FEATURE" = "$ACTIVE_FEATURE" ]; then
            TS=$(iso_utc)
            echo "[$TS] push-guard: ⚠️  ticket-scoped bypass active for '$BYPASS_FEATURE' (reason: $BYPASS_REASON, created: $BYPASS_CREATED) — push allowed under audit trail." >&2
            emit_push_passed "ticket-scoped bypass active"
            exit 0
        fi
        # Feature mismatch: spec §5.4 — cross-ticket bypass impossible.
        echo "🛑 BLOCKED: bypass.json feature '$BYPASS_FEATURE' does not match active session feature '$ACTIVE_FEATURE'." >&2
        echo "   Cross-ticket bypass is not permitted. Create a new bypass for this feature, or complete GATE 2." >&2
        emit_push_blocked "cross-ticket bypass not permitted"
        exit 2
    elif [ -n "$BYPASS_FEATURE" ]; then
        echo "🛑 BLOCKED: bypass.json exists but is missing required audit fields (feature, reason, createdAt)." >&2
        echo "   Bypass must be created via 'bypass freeze' in /implement, not manually." >&2
        emit_push_blocked "bypass missing audit fields"
        exit 2
    fi
fi

# Non-full-cycle modes (review/test/docs/init) are short-lived quality passes; do not
# gate push on their completion status. A crashed/interrupted review must not
# permanently block push on this branch.
if [ "$MODE" != "full-cycle" ]; then
    emit_push_passed "non-full-cycle mode ($MODE)"
    exit 0
fi

echo "🛑 BLOCKED: /implement full-cycle workflow not completed for branch '$BRANCH'." >&2
echo "   Normal path: complete Phase 7 (GATE 2 approval) of /implement to authorize push." >&2
echo "   Emergency path: request 'bypass freeze' in /implement to create an audit-trailed bypass." >&2
echo "   Escape hatch: use --force in your git push command (no audit trail)." >&2
echo "   Session: $SESSION_DIR" >&2
emit_push_blocked "full-cycle workflow not completed"
exit 2
