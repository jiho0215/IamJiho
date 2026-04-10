#!/bin/bash
# sessionend.sh — SessionEnd hook: cleanup temp files + mark interrupted runs
# Safety: ERR trap ensures unexpected errors never cause issues

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
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
REPO=$(basename "$(git remote get-url origin 2>/dev/null \
    || git rev-parse --show-toplevel 2>/dev/null \
    || pwd)" .git)
SANITIZED_BRANCH=$(sanitize_branch "$BRANCH")
SESSION_FORMAT=$(cfg '.sessionFolderFormat' '{repo}--{branch}')
SESSION_NAME="${SESSION_FORMAT/\{repo\}/$REPO}"
SESSION_NAME="${SESSION_NAME/\{branch\}/$SANITIZED_BRANCH}"
SESSION_DIR="$SESSIONS_DIR/$SESSION_NAME"

[ -d "$SESSION_DIR" ] || exit 0
[ -f "$SESSION_DIR/progress-log.json" ] || exit 0

# Clean up stale JSONL temp files from interrupted review phases
for jsonl in "$SESSION_DIR"/phase-*-decisions.jsonl; do
    [ -f "$jsonl" ] && rm -f "$jsonl"
done

# Mark in-progress pipelines as interrupted
CURRENT_STATUS=$(jq -r '.status // "unknown"' "$SESSION_DIR/progress-log.json" 2>/dev/null)
if [ "$CURRENT_STATUS" = "in-progress" ]; then
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq --arg ts "$TIMESTAMP" '.status = "interrupted" | .interruptedAt = $ts' \
        "$SESSION_DIR/progress-log.json" > "$SESSION_DIR/progress-log.json.tmp" && \
        mv "$SESSION_DIR/progress-log.json.tmp" "$SESSION_DIR/progress-log.json"
fi

exit 0
