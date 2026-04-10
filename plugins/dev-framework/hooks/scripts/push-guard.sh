#!/bin/bash
# push-guard.sh — PreToolUse hook: block git push unless pipeline completed
# No ERR trap — this hook intentionally blocks (exit 2)

set -euo pipefail

# --- Dependency check (fail safe — block if jq missing) ---
if ! command -v jq &>/dev/null; then
    echo "BLOCKED: jq required for push-guard. Install jq or use --force to bypass."
    exit 2
fi

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

SESSIONS_DIR=$(cfg '.paths.sessionsDir' "$HOME/.claude/autodev/sessions")

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

# Broader match for git push variants (git -c key=val push, etc.)
echo "$COMMAND" | grep -qE '\bgit\b.*\bpush\b' || exit 0

# Allow force pushes (escape hatch — read flags from config, default --force/-f)
if [ -f "$CONFIG" ] && jq -e '.hooks.pushGuard.escapeFlags' "$CONFIG" &>/dev/null; then
    ESCAPE_FLAGS=$(jq -r '.hooks.pushGuard.escapeFlags[]' "$CONFIG" 2>/dev/null)
else
    ESCAPE_FLAGS=$(printf '%s\n' '--force' '-f')
fi
while IFS= read -r flag; do
    [ -z "$flag" ] && continue
    echo "$COMMAND" | grep -qF "$flag" && exit 0
done <<< "$ESCAPE_FLAGS"

# Get branch (handle detached HEAD)
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null) || {
    echo "WARNING: Detached HEAD. Push guard bypassed."
    exit 0
}
[ -n "$BRANCH" ] || {
    echo "WARNING: Not inside a git repository. Push guard skipped."
    exit 0
}

# Robust repo name resolution (worktree-safe)
REPO=$(basename "$(git remote get-url origin 2>/dev/null \
    || git rev-parse --show-toplevel 2>/dev/null \
    || pwd)" .git)

SANITIZED_BRANCH=$(sanitize_branch "$BRANCH")
SESSION_FORMAT=$(cfg '.sessionFolderFormat' '{repo}--{branch}')
SESSION_NAME="${SESSION_FORMAT/\{repo\}/$REPO}"
SESSION_NAME="${SESSION_NAME/\{branch\}/$SANITIZED_BRANCH}"
SESSION_DIR="$SESSIONS_DIR/$SESSION_NAME"
MARKER="$SESSION_DIR/pipeline-complete.md"

# Only guard branches that have a session folder (pipeline was started for this branch)
# Branches that never used /dev-pipeline are not blocked
if [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

# Session exists — check for completion marker (exact branch match)
if [ -f "$MARKER" ] && grep -qxF "Pipeline completed for branch: $BRANCH" "$MARKER" 2>/dev/null; then
    exit 0
else
    echo "BLOCKED: Pipeline started but not completed for branch '$BRANCH'."
    echo "Run '/dev-pipeline <TICKET>' to complete, or use escape flags to bypass."
    exit 2
fi
