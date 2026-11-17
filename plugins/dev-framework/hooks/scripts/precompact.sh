#!/bin/bash
# precompact.sh — PreCompact hook: serialize /implement (or /spike) workflow state before context truncation
# so the LLM can resume coherently after compaction.
#
# Safety: ERR trap ensures unexpected errors never block compaction.

trap 'exit 0' ERR
set -uo pipefail

command -v jq &>/dev/null || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

SESSION_DIR=$(resolve_session_dir)
PROGRESS_LOG="$SESSION_DIR/progress-log.json"

# Only inject state if an active /implement session exists.
[ -f "$PROGRESS_LOG" ] || exit 0
jq empty "$PROGRESS_LOG" 2>/dev/null || exit 0

# Emit event marking the compaction point (ordered before the state dump so
# consumers can pair the event with the preserved state text).
bash "$SCRIPT_DIR/emit-event.sh" session.precompact \
    --actor "hook:precompact" \
    --data '{"reason":"context truncation imminent"}' \
    2>/dev/null || true

CURRENT_PHASE=$(jq -r '.currentPhase // "unknown"' "$PROGRESS_LOG" 2>/dev/null)
STATUS=$(jq -r '.status // "unknown"' "$PROGRESS_LOG" 2>/dev/null)
MODE=$(jq -r '.mode // "full-cycle"' "$PROGRESS_LOG" 2>/dev/null)
FEATURE=$(jq -r '.featureSlug // .ticket // "unknown"' "$PROGRESS_LOG" 2>/dev/null)
TICKET=$(jq -r '.ticket // empty' "$PROGRESS_LOG" 2>/dev/null)
RUN_ID=$(jq -r '.runId // "unknown"' "$PROGRESS_LOG" 2>/dev/null)
ISSUES=$(jq -r '.summary.totalIssuesFound // 0' "$PROGRESS_LOG" 2>/dev/null)
INTERRUPTED_AT=$(jq -r '.interruptedAt // empty' "$PROGRESS_LOG" 2>/dev/null)
DECISIONS=$(jq -r '.decisions | length' "$SESSION_DIR/decision-log.json" 2>/dev/null || echo "0")

# Surface active bypass so the post-compaction LLM knows src/** edits may be passing
# under a bypass, not under an APPROVED freeze doc.
BYPASS_LINE=""
BYPASS_FILE="$SESSION_DIR/bypass.json"
if [ -f "$BYPASS_FILE" ]; then
    BYPASS_REASON=$(jq -r '.reason // "unknown"' "$BYPASS_FILE" 2>/dev/null)
    BYPASS_CREATED=$(jq -r '.createdAt // "?"' "$BYPASS_FILE" 2>/dev/null)
    BYPASS_LINE="Bypass active: reason='$BYPASS_REASON' since=$BYPASS_CREATED"
fi

# Build the resume command: `--autonomous TICKET` only if this was an autonomous run.
APPROVAL_MODE=$(jq -r '.approvalMode // empty' "$PROGRESS_LOG" 2>/dev/null)
if [ "$APPROVAL_MODE" = "autonomous" ] && [ -n "$TICKET" ]; then
    RESUME_CMD="/implement --from $CURRENT_PHASE --autonomous $TICKET"
else
    RESUME_CMD="/implement --from $CURRENT_PHASE"
fi

cat <<EOF
--- /implement SESSION STATE (preserved before context compaction) ---
Feature: $FEATURE | Mode: $MODE | Phase: $CURRENT_PHASE | Status: $STATUS
RunId: $RUN_ID
Issues found: $ISSUES | Decisions logged: $DECISIONS
EOF
[ -n "$BYPASS_LINE" ] && echo "$BYPASS_LINE"
[ "$STATUS" = "interrupted" ] && [ -n "$INTERRUPTED_AT" ] && echo "Interrupted at: $INTERRUPTED_AT"
cat <<EOF
Session: $SESSION_DIR
Resume: $RESUME_CMD
Full status: /implement --status
--- END SESSION STATE ---
EOF

exit 0
