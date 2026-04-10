#!/bin/bash
# phase-progress-validator.sh — PostToolUse hook: validate progress map after phase gate calls
# Safety: ERR trap ensures unexpected errors never block the pipeline
#
# This hook fires after any Bash call to phase-gate.sh.
# It independently validates the progress-log.json for consistency,
# serving as a safety net alongside the active gate script.
#
# Emits warnings to session context but does NOT block (exit 0 always).

trap 'exit 0' ERR
set -uo pipefail

command -v jq &>/dev/null || exit 0

# --- Parse the tool input to extract phase-gate action and phase ---
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

# Extract action and phase from the command (portable — no Perl regex)
# Matches: bash .../phase-gate.sh begin|end N
ACTION=$(echo "$COMMAND" | sed -n 's/.*phase-gate\.sh[[:space:]]\{1,\}\(begin\|end\).*/\1/p' 2>/dev/null || true)
PHASE=$(echo "$COMMAND" | sed -n 's/.*phase-gate\.sh[[:space:]]\{1,\}\(begin\|end\)[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\2/p' 2>/dev/null || true)

[ -n "$ACTION" ] && [ -n "$PHASE" ] || exit 0

# --- Config loading with fallback defaults ---
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

# --- Resolve session directory ---
SESSIONS_DIR=$(cfg '.paths.sessionsDir' "$HOME/.claude/autodev/sessions")
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

[ -f "$PROGRESS_LOG" ] || {
    echo "PROGRESS VALIDATOR: progress-log.json not found — session may not be initialized."
    exit 0
}

# --- Validation checks ---
WARNINGS=0

# Check: schemaVersion exists
SCHEMA=$(jq -r '.schemaVersion // "missing"' "$PROGRESS_LOG" 2>/dev/null)
if [ "$SCHEMA" = "missing" ]; then
    echo "PROGRESS VALIDATOR WARNING: schemaVersion missing from progress-log.json"
    WARNINGS=$((WARNINGS + 1))
fi

# Check: phases array exists and is not empty (after Phase 1 begin)
PHASE_COUNT=$(jq -r '.phases | length' "$PROGRESS_LOG" 2>/dev/null || echo "0")
if [ "$ACTION" = "end" ] && [ "$PHASE_COUNT" -eq 0 ]; then
    echo "PROGRESS VALIDATOR WARNING: phases array is empty after Phase $PHASE end gate"
    WARNINGS=$((WARNINGS + 1))
fi

# Check: sequential phase integrity — no gaps in completed phases
if [ "$PHASE" -gt 1 ]; then
    for ((i = 1; i < PHASE; i++)); do
        STATUS=$(jq -r ".phases[] | select(.phase == $i) | .status // \"missing\"" "$PROGRESS_LOG" 2>/dev/null)
        if [ -z "$STATUS" ] || [ "$STATUS" = "missing" ]; then
            # On begin: previous phases should exist
            if [ "$ACTION" = "begin" ]; then
                echo "PROGRESS VALIDATOR WARNING: Phase $i has no entry — gap in phase sequence"
                WARNINGS=$((WARNINGS + 1))
            fi
        elif [ "$STATUS" != "completed" ] && [ "$STATUS" != "skipped" ] && [ "$STATUS" != "failed" ]; then
            echo "PROGRESS VALIDATOR WARNING: Phase $i status is '$STATUS' (expected completed/skipped/failed)"
            WARNINGS=$((WARNINGS + 1))
        fi
    done
fi

# Check: on end gate, verify timing consistency
if [ "$ACTION" = "end" ]; then
    STARTED=$(jq -r ".phases[] | select(.phase == $PHASE) | .startedAt // \"null\"" "$PROGRESS_LOG" 2>/dev/null)
    COMPLETED=$(jq -r ".phases[] | select(.phase == $PHASE) | .completedAt // \"null\"" "$PROGRESS_LOG" 2>/dev/null)

    if [ "$STARTED" = "null" ]; then
        echo "PROGRESS VALIDATOR WARNING: Phase $PHASE has no startedAt timestamp"
        WARNINGS=$((WARNINGS + 1))
    fi
    if [ "$COMPLETED" = "null" ]; then
        echo "PROGRESS VALIDATOR WARNING: Phase $PHASE has no completedAt timestamp"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# Check: currentPhase consistency
CURRENT=$(jq -r '.currentPhase // 0' "$PROGRESS_LOG" 2>/dev/null)
if [ "$ACTION" = "begin" ] && [ "$CURRENT" -gt "$PHASE" ]; then
    echo "PROGRESS VALIDATOR WARNING: currentPhase ($CURRENT) > gate phase ($PHASE) — possible out-of-order execution"
    WARNINGS=$((WARNINGS + 1))
fi

# Summary
if [ "$WARNINGS" -gt 0 ]; then
    echo "PROGRESS VALIDATOR: $WARNINGS warning(s) after Phase $PHASE $ACTION gate"
else
    echo "PROGRESS VALIDATOR: Phase $PHASE $ACTION — progress map consistent"
fi

exit 0
