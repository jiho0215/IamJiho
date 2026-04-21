#!/bin/bash
# regenerate-views.sh — Regenerate all views/ files from events.jsonl.
# Idempotent — safe to call as often as desired.
#
# Core views (always run): progress-log, decision-log, pipeline-issues.
# Epic-scoped views (v4.0+, run only when epicId is present): spike-plan
# registry §7 and per-ticket ref-doc impl logs under <repo>/docs/plan/<epic>/.
# The epic-scoped reducers no-op safely when no epic context exists, so we
# can invoke them unconditionally.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/reduce-progress-log.sh"
bash "$SCRIPT_DIR/reduce-decision-log.sh"
bash "$SCRIPT_DIR/reduce-pipeline-issues.sh"
bash "$SCRIPT_DIR/reduce-spike-plan.sh"
bash "$SCRIPT_DIR/reduce-ticket-doc.sh"

exit 0
