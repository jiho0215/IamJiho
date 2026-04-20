#!/bin/bash
# ensure-config.sh — Idempotent config bootstrap for dev-framework plugin.
#
# Creates ~/.claude/autodev/config.json with default schema if absent.
# Safe to call at the start of any /dev invocation (both interactive and autonomous).
# Single source of truth for the default config schema — no inline duplication
# in SKILL.md or other hooks.
#
# Exit codes:
#   0 — config exists (valid or freshly created)
#   non-zero — critical failure (directory creation or write)

set -euo pipefail

CONFIG_DIR="$HOME/.claude/autodev"
CONFIG_FILE="$CONFIG_DIR/config.json"
FREEZE_CATEGORIES_DIR="$CONFIG_DIR/freeze-categories"

# --- Ensure directory exists ---
if ! mkdir -p "$CONFIG_DIR"; then
    echo "ensure-config: ERROR — failed to create $CONFIG_DIR" >&2
    exit 1
fi

# Best-effort: create freeze-categories/ directory so custom category templates
# can be dropped in. Failure here is non-fatal.
mkdir -p "$FREEZE_CATEGORIES_DIR" 2>/dev/null || true

# --- Check existing config validity ---
if [ -f "$CONFIG_FILE" ]; then
    if command -v jq &>/dev/null; then
        if jq empty "$CONFIG_FILE" 2>/dev/null; then
            # Valid JSON — leave as-is. Missing keys fall back to documented defaults.
            exit 0
        fi
        # Malformed JSON — back up and regenerate.
        BACKUP="$CONFIG_FILE.bak.$(date +%s)"
        mv "$CONFIG_FILE" "$BACKUP"
        echo "ensure-config: WARNING — config.json was malformed. Backed up to $BACKUP and regenerating." >&2
    else
        # No jq available — cannot validate. Assume existing file is correct to
        # avoid data loss, but surface the risk so the user can install jq.
        echo "ensure-config: WARNING — jq not found; cannot validate $CONFIG_FILE. Install jq to enable automatic validation and malformed-config recovery." >&2
        exit 0
    fi
fi

# --- Write default config (atomic via temp + rename) ---
TMP_FILE="$CONFIG_FILE.tmp.$$"

cat > "$TMP_FILE" <<'JSON'
{
  "pipeline": {
    "maxReviewIterations": 10,
    "consecutiveZerosToExit": 2,
    "testCoverageTarget": 90,
    "maxActivePatterns": 20,
    "chronicPromotionThreshold": 3,
    "cleanRunsForDemotion": 5,
    "maxRunsRetained": 10,
    "sessionHealthCheckpointPhases": 6,
    "skills": {
      "requirements": "superpowers:brainstorming",
      "exploration": "feature-dev:code-explorer",
      "architect": "feature-dev:code-architect",
      "planning": "superpowers:writing-plans",
      "tdd": "superpowers:test-driven-development",
      "implementation": "superpowers:subagent-driven-development",
      "implementationSequential": "superpowers:executing-plans",
      "implementationParallel": "superpowers:dispatching-parallel-agents",
      "requestReview": "superpowers:requesting-code-review",
      "receiveReview": "superpowers:receiving-code-review",
      "verification": "superpowers:verification-before-completion",
      "finishing": "superpowers:finishing-a-development-branch",
      "debugging": "superpowers:systematic-debugging"
    },
    "agents": {
      "plan": ["requirements-analyst", "architect", "test-strategist"],
      "review": ["code-quality-reviewer", "performance-reviewer", "observability-reviewer"]
    },
    "freezeDoc": {
      "categories": [
        "business-logic",
        "api-contracts",
        "third-party",
        "data",
        "error-model",
        "acceptance-criteria",
        "security",
        "performance"
      ],
      "nonFrozenAllowList": [
        "observability",
        "railroad-composition",
        "pure-function-composition"
      ],
      "customCategoryTemplatesDir": "~/.claude/autodev/freeze-categories/"
    }
  },
  "paths": {
    "sessionsDir": "~/.claude/autodev/sessions",
    "autodevRoot": "~/.claude/autodev",
    "patternsFile": "workflow_mistake_patterns.md"
  },
  "sessionFolderFormat": "{repo}--{branch}",
  "hooks": {
    "pushGuard": {
      "escapeFlags": ["--force", "-f"]
    },
    "testCapture": {
      "testCommand": "dotnet test"
    }
  },
  "sentinels": {
    "begin": "<!-- CHRONIC PATTERNS START -->",
    "end": "<!-- CHRONIC PATTERNS END -->"
  }
}
JSON

# Atomic rename. Retry once on Windows file-lock edge case.
if ! mv "$TMP_FILE" "$CONFIG_FILE" 2>/dev/null; then
    sleep 1
    if ! mv "$TMP_FILE" "$CONFIG_FILE"; then
        rm -f "$TMP_FILE"
        echo "ensure-config: ERROR — failed to write $CONFIG_FILE" >&2
        exit 1
    fi
fi

echo "ensure-config: created default config at $CONFIG_FILE — edit to customize skills, agents, thresholds, and freeze doc categories."
exit 0
