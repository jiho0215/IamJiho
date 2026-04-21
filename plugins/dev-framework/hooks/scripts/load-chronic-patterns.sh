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
    DATA=$(printf '{"count":%d,"file":"%s","domain":"code","chronicPatterns":[%s]}' \
        "${#PATTERN_IDS[@]}" "$(basename "$PATTERNS_FILE")" "$IDS_JSON")
    bash "$SCRIPT_DIR/emit-event.sh" patterns.loaded \
        --actor "hook:load-chronic-patterns" \
        --data "$DATA" 2>/dev/null || true
fi

# --- v4.0+: Chronic design patterns (spike retro output) ---
# Loaded in addition to code patterns. JSON store at ~/.claude/autodev/chronic-design-patterns.json
# Protocol: plugins/dev-framework/skills/spike/references/autonomous/mistake-tracker-protocol.md
DESIGN_STORE="$HOME/.claude/autodev/chronic-design-patterns.json"
if [ -f "$DESIGN_STORE" ]; then
    # Extract only chronic-status patterns; known/resolved are not surfaced to the session.
    CHRONIC_DESIGN=$(jq -r '
        .patterns // []
        | map(select(.status == "chronic"))
        | map("  - " + .id + ": " + .pattern + " — " + (.prevention // ""))
        | .[]
    ' "$DESIGN_STORE" 2>/dev/null || true)

    if [ -n "$CHRONIC_DESIGN" ]; then
        echo ""
        echo "CHRONIC DESIGN PATTERNS LOADED — prevent these when designing/decomposing epics:"
        echo "$CHRONIC_DESIGN"

        # Emit patterns.loaded (design domain) so event log carries both.
        DESIGN_IDS_JSON=$(jq -c '[.patterns[] | select(.status == "chronic") | .id]' "$DESIGN_STORE" 2>/dev/null || echo '[]')
        DESIGN_COUNT=$(jq '[.patterns[] | select(.status == "chronic")] | length' "$DESIGN_STORE" 2>/dev/null || echo 0)
        if [ -f "$SCRIPT_DIR/emit-event.sh" ] && [ "$DESIGN_COUNT" -gt 0 ]; then
            DATA=$(jq -cn --argjson c "$DESIGN_COUNT" --arg f "chronic-design-patterns.json" --argjson ids "$DESIGN_IDS_JSON" \
                '{count:$c, file:$f, domain:"design", chronicPatterns:$ids}')
            bash "$SCRIPT_DIR/emit-event.sh" patterns.loaded \
                --actor "hook:load-chronic-patterns" \
                --data "$DATA" 2>/dev/null || true
        fi
    fi
fi

exit 0
