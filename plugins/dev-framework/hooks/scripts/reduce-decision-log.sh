#!/bin/bash
# reduce-decision-log.sh — Regenerate views/decision-log.json from events.jsonl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"
# shellcheck source=./_reducers.sh
. "$SCRIPT_DIR/_reducers.sh"

command -v jq &>/dev/null || { echo "reduce-decision-log: ERROR — jq required" >&2; exit 1; }

EVENTS=$(events_file)
[ -f "$EVENTS" ] || exit 0

ensure_views_dir
VIEW="$(views_dir)/decision-log.json"

jq -s --arg regen "$(iso_utc)" '
  def explicit_decisions:
    [ .[] | select(.type == "decision.recorded") |
      { id: .data.id, seq: .seq, at: .at, phase: .data.phase,
        category: .data.category, decision: .data.decision,
        reason: .data.reason, confidence: .data.confidence,
        source: "explicit" } ];

  def gate_decisions:
    [ .[] | select(.type == "gate.approved") |
      { id: "GATE\(.data.gate)-APPROVED-\(.seq)", seq: .seq, at: .at, phase: null,
        category: "gate-\(.data.gate)", decision: "gate \(.data.gate) approved",
        reason: "approvalMode=\(.data.approvalMode // "?") by=\(.data.approvedBy // "?")",
        confidence: "high", source: "derived" } ];

  def bypass_decisions:
    [ .[] | select(.type == "bypass.created") |
      { id: "BYPASS-\(.seq)", seq: .seq, at: .at, phase: null,
        category: "bypass", decision: "freeze-gate bypass",
        reason: (.data.reason // ""),
        confidence: "high", source: "derived" } ];

  def failure_decisions:
    [ .[] | select(.type == "phase.failed") |
      { id: "FAIL-P\(.data.phase)-\(.seq)", seq: .seq, at: .at, phase: .data.phase,
        category: "phase-failure", decision: "phase \(.data.phase) failed",
        reason: (.data.error // ""),
        confidence: "high", source: "derived" } ];

  {
    schemaVersion: 1,
    source: "events-reducer",
    regeneratedAt: $regen,
    decisions:
      (explicit_decisions + gate_decisions + bypass_decisions + failure_decisions)
      | sort_by(.seq)
  }
' "$EVENTS" | atomic_write "$VIEW"

exit 0
