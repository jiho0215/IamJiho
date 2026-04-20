#!/bin/bash
# precompact.sh — PreCompact hook: serialize /dev workflow state before context truncation
# so the LLM can resume coherently after compaction.
#
# Safety: ERR trap ensures unexpected errors never block compaction.

trap 'exit 0' ERR
set -uo pipefail

command -v jq &>/dev/null || exit 0

CONFIG="$HOME/.claude/autodev/config.json"
cfg() {
  if [ -f "$CONFIG" ]; then
    local val
    val=$(jq -r "($1) // empty" "$CONFIG" 2>/dev/null)
    if [ -n "$val" ]; then echo "$val"; else echo "$2"; fi
  else
    echo "$2"
  fi
}

sanitize_branch() {
  echo "$1" | sed 's|[/\\:*?"<>|@]|-|g' | sed 's|\.\.*$||' | cut -c1-64
}

SESSIONS_DIR=$(cfg '.paths.sessionsDir' "$HOME/.claude/autodev/sessions")
SESSIONS_DIR="${SESSIONS_DIR/#\~/$HOME}"
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
REPO=$(basename "$(git remote get-url origin 2>/dev/null \
    || git rev-parse --show-toplevel 2>/dev/null \
    || pwd)" .git)
SANITIZED_BRANCH=$(sanitize_branch "$BRANCH")
SESSION_FORMAT=$(cfg '.sessionFolderFormat' '{repo}--{branch}')
SESSION_NAME="${SESSION_FORMAT/\{repo\}/$REPO}"
SESSION_NAME="${SESSION_NAME/\{branch\}/$SANITIZED_BRANCH}"
SESSION_DIR="$SESSIONS_DIR/$SESSION_NAME"
PROGRESS_LOG="$SESSION_DIR/progress-log.json"

# Only inject state if an active /dev session exists.
[ -f "$PROGRESS_LOG" ] || exit 0
jq empty "$PROGRESS_LOG" 2>/dev/null || exit 0

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
    RESUME_CMD="/dev --from $CURRENT_PHASE --autonomous $TICKET"
else
    RESUME_CMD="/dev --from $CURRENT_PHASE"
fi

cat <<EOF
--- /dev SESSION STATE (preserved before context compaction) ---
Feature: $FEATURE | Mode: $MODE | Phase: $CURRENT_PHASE | Status: $STATUS
RunId: $RUN_ID
Issues found: $ISSUES | Decisions logged: $DECISIONS
EOF
[ -n "$BYPASS_LINE" ] && echo "$BYPASS_LINE"
[ "$STATUS" = "interrupted" ] && [ -n "$INTERRUPTED_AT" ] && echo "Interrupted at: $INTERRUPTED_AT"
cat <<EOF
Session: $SESSION_DIR
Resume: $RESUME_CMD
Full status: /dev --status
--- END SESSION STATE ---
EOF

exit 0
