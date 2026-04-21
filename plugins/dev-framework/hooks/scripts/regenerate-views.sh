#!/bin/bash
# regenerate-views.sh — Regenerate all views/ files from events.jsonl.
# Idempotent — safe to call as often as desired.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/reduce-progress-log.sh"
bash "$SCRIPT_DIR/reduce-decision-log.sh"
bash "$SCRIPT_DIR/reduce-pipeline-issues.sh"

exit 0
