#!/bin/bash
# load-chronic-patterns.sh — SessionStart hook: load chronic patterns into session context
# Safety: ERR trap ensures unexpected errors never block session start

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

# Try explicit path first, then search project memory dirs
PATTERNS_FILE=""
PATTERNS_FILE_FULL=$(cfg '.paths.patternsFileFull' '')
if [ -n "$PATTERNS_FILE_FULL" ]; then
    RESOLVED="${PATTERNS_FILE_FULL/#\~/$HOME}"
    [ -f "$RESOLVED" ] && PATTERNS_FILE="$RESOLVED"
fi
if [ -z "$PATTERNS_FILE" ]; then
    PATTERNS_FILENAME=$(cfg '.paths.patternsFile' 'workflow_mistake_patterns.md')
    for DIR in "$HOME/.claude/projects"/*/memory/; do
        if [ -f "${DIR}${PATTERNS_FILENAME}" ]; then
            PATTERNS_FILE="${DIR}${PATTERNS_FILENAME}"
            break
        fi
    done
fi

[ -n "$PATTERNS_FILE" ] && [ -f "$PATTERNS_FILE" ] || exit 0

# Extract chronic patterns
# Extract rows between "## Chronic Patterns" and the next "## " header
CHRONIC=$(sed -n '/^## Chronic Patterns$/,/^## /{/^## Chronic Patterns$/d;/^## /d;p}' "$PATTERNS_FILE" | grep '^ *| *P[0-9]' || true)
[ -z "$CHRONIC" ] && exit 0

echo "CHRONIC PATTERNS LOADED for this session — prevent these when writing code:"
PATTERN_IDS=()
while IFS='|' read -r _ id pattern _ _ _ prevention _; do
    id=$(echo "$id" | xargs 2>/dev/null || echo "$id")
    pattern=$(echo "$pattern" | xargs 2>/dev/null || echo "$pattern")
    prevention=$(echo "$prevention" | xargs 2>/dev/null || echo "$prevention")
    [ -z "$id" ] || [ -z "$pattern" ] && continue
    echo "  - $id: $pattern — $prevention"
    PATTERN_IDS+=("$id")
done <<< "$CHRONIC"

# M2.5: emit patterns.loaded event (best-effort; no-op if no active session)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/emit-event.sh" ] && [ ${#PATTERN_IDS[@]} -gt 0 ]; then
    IDS_JSON=$(printf '"%s",' "${PATTERN_IDS[@]}" | sed 's/,$//')
    DATA=$(printf '{"count":%d,"file":"%s","chronicPatterns":[%s]}' \
        "${#PATTERN_IDS[@]}" "$(basename "$PATTERNS_FILE")" "$IDS_JSON")
    bash "$SCRIPT_DIR/emit-event.sh" patterns.loaded \
        --actor "hook:load-chronic-patterns" \
        --data "$DATA" 2>/dev/null || true
fi

exit 0
