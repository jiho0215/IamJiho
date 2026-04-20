#!/bin/bash
# sessionend.sh — SessionEnd hook: cleanup temp files + mark interrupted runs +
# preserve bypass audit trail to freeze doc before bypass.json becomes stale.
#
# Runs for every session regardless of mode (full-cycle/review/test/docs/init).
# Safety: ERR trap ensures unexpected errors never cause issues.

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
BYPASS_FILE="$SESSION_DIR/bypass.json"

[ -d "$SESSION_DIR" ] || exit 0
[ -f "$PROGRESS_LOG" ] || exit 0

# If GATE 2 has already written pipeline-complete.md, bypass lifecycle is closed.
# Skip archival to avoid a race with any concurrent GATE 2 write path.
[ -f "$SESSION_DIR/pipeline-complete.md" ] && exit 0

# --- Preserve bypass audit trail durably on session end.
# This handles the crash/interrupt path where Phase 7 GATE 2 never ran to
# archive bypass.json into freeze doc `bypassHistory`. The audit trail is a
# standalone JSONL file (bypass-audit.jsonl) in the session folder — it does
# NOT depend on the freeze doc existing. An early-phase bypass (before Phase 3
# creates the freeze doc) is still recorded. Phase 7 GATE 2 merges
# bypass-audit.jsonl entries into the freeze doc bypassHistory at completion,
# filtering by runId so cross-run entries stay scoped.
if [ -f "$BYPASS_FILE" ] && jq empty "$PROGRESS_LOG" 2>/dev/null; then
    BYPASS_AT=$(jq -r '.createdAt // empty' "$BYPASS_FILE" 2>/dev/null)
    AUDIT_FILE="$SESSION_DIR/bypass-audit.jsonl"
    if [ -z "$BYPASS_AT" ]; then
        echo "sessionend: WARNING — bypass.json exists but has no createdAt field; bypass event is not archivable. Inspect $BYPASS_FILE manually or re-create via 'bypass freeze' in /dev." >&2
    fi
    if [ -n "$BYPASS_AT" ]; then
        # Idempotency: use jq value-only match (format-robust; not a raw string grep).
        ALREADY_RECORDED=0
        if [ -f "$AUDIT_FILE" ]; then
            if jq -e --arg at "$BYPASS_AT" \
                    'select(.at == $at)' "$AUDIT_FILE" 2>/dev/null | grep -q .; then
                ALREADY_RECORDED=1
            fi
        fi
        if [ "$ALREADY_RECORDED" -eq 0 ]; then
            RUN_ID=$(jq -r '.runId // empty' "$PROGRESS_LOG" 2>/dev/null)
            PRESERVED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            jq -c \
                --arg runid "$RUN_ID" \
                --arg pa "$PRESERVED_AT" \
                '{at: .createdAt, reason, feature, userMessage,
                  runId: $runid, preservedBy: "sessionend", preservedAt: $pa}' \
                "$BYPASS_FILE" >> "$AUDIT_FILE" 2>/dev/null \
                && echo "sessionend: preserved bypass audit entry to $AUDIT_FILE (runId=$RUN_ID)" >&2
        fi

        # If freezeDocPath is not yet recorded in progress-log (early-phase bypass,
        # before Phase 3 populated it), bypass-audit.jsonl is the only durable
        # record until Phase 7 runs and archives to the freeze doc.
        FREEZE_DOC_PATH=$(jq -r '.freezeDocPath // empty' "$PROGRESS_LOG" 2>/dev/null)
        if [ -z "$FREEZE_DOC_PATH" ]; then
            echo "sessionend: WARNING — bypass.json exists but freezeDocPath not set; bypass-audit.jsonl is the only durable record until Phase 7 runs." >&2
        fi
    fi
fi

# --- Clean up stale JSONL temp files from interrupted review phases. ---
for jsonl in "$SESSION_DIR"/phase-*-decisions.jsonl; do
    [ -f "$jsonl" ] && rm -f "$jsonl"
done

# --- Mark in-progress pipelines as interrupted (any mode). ---
CURRENT_STATUS=$(jq -r '.status // "unknown"' "$PROGRESS_LOG" 2>/dev/null)
if [ "$CURRENT_STATUS" = "in-progress" ]; then
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq --arg ts "$TIMESTAMP" '.status = "interrupted" | .interruptedAt = $ts' \
        "$PROGRESS_LOG" > "$PROGRESS_LOG.tmp" && \
        mv "$PROGRESS_LOG.tmp" "$PROGRESS_LOG"
fi

# --- Clear bypass on completed sessions (normal or final). ---
# A completed full-cycle session has passed GATE 2; the bypass lifecycle is over.
# Delete bypass.json so next session starts clean (bypass-audit.jsonl remains for history).
if [ "$CURRENT_STATUS" = "completed" ] && [ -f "$BYPASS_FILE" ]; then
    rm -f "$BYPASS_FILE"
fi

exit 0
