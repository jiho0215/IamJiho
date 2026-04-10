#!/bin/bash
# test-failure-capture.sh — PostToolUse hook: log test failures for audit trail
# Safety: ERR trap ensures unexpected errors never cause issues

trap 'exit 0' ERR
set -uo pipefail

# --- Dependency check ---
command -v jq &>/dev/null || exit 0

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

TEST_CMD=$(cfg '.hooks.testCapture.testCommand' 'dotnet test')
SESSIONS_DIR=$(cfg '.paths.sessionsDir' "$HOME/.claude/autodev/sessions")

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_result.exit_code // "0"' 2>/dev/null)

# Defense in depth (redundant with `if` filter) — literal match
echo "$COMMAND" | grep -qF "$TEST_CMD" || exit 0

if [ "$EXIT_CODE" != "0" ]; then
    # Resolve session folder (robust: worktree-safe, detached-HEAD-safe)
    BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    REPO=$(basename "$(git remote get-url origin 2>/dev/null \
        || git rev-parse --show-toplevel 2>/dev/null \
        || pwd)" .git)
    SANITIZED_BRANCH=$(sanitize_branch "$BRANCH")
    SESSION_FORMAT=$(cfg '.sessionFolderFormat' '{repo}--{branch}')
    SESSION_NAME="${SESSION_FORMAT/\{repo\}/$REPO}"
    SESSION_NAME="${SESSION_NAME/\{branch\}/$SANITIZED_BRANCH}"
    LOG="$SESSIONS_DIR/$SESSION_NAME/test-failures.log"

    mkdir -p "$(dirname "$LOG")"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    FIRST_LINE=$(printf '%s' "$COMMAND" | head -1)
    printf '[%s] FAIL: %s\n' "$TIMESTAMP" "$FIRST_LINE" >> "$LOG"
fi

exit 0
