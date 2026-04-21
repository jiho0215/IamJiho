#!/bin/bash
# phase-gate.sh — Phase boundary validation for the unified /dev workflow.
# Called by SKILL.md at the start and end of each phase.
# Validates progress-log.json state and blocks (exit 2) on failure.
#
# Usage:
#   bash phase-gate.sh verify          — check progress-log.json exists and is valid (Pre-Workflow)
#   bash phase-gate.sh begin <phase>   — validate prerequisites before phase starts
#   bash phase-gate.sh end <phase>     — validate progress map was updated after phase
#
# Exit codes:
#   0 — gate passed
#   2 — gate failed (blocks pipeline)

set -euo pipefail

# --- Dependency check ---
if ! command -v jq &>/dev/null; then
    echo "PHASE GATE BLOCKED: jq is required. Install jq to continue."
    exit 2
fi

# --- Args ---
ACTION="${1:-}"
PHASE="${2:-}"

if [ -z "$ACTION" ]; then
    echo "PHASE GATE ERROR: Usage: phase-gate.sh verify | begin|end <phase-number>"
    exit 2
fi

if [ "$ACTION" != "verify" ] && [ "$ACTION" != "begin" ] && [ "$ACTION" != "end" ]; then
    echo "PHASE GATE ERROR: Action must be 'verify', 'begin', or 'end', got '$ACTION'"
    exit 2
fi

# verify action doesn't need a phase number
if [ "$ACTION" != "verify" ]; then
    if [ -z "$PHASE" ]; then
        echo "PHASE GATE ERROR: Usage: phase-gate.sh begin|end <phase-number>"
        exit 2
    fi
    if ! [[ "$PHASE" =~ ^[0-9]+$ ]] || [ "$PHASE" -lt 1 ] || [ "$PHASE" -gt 7 ]; then
        echo "PHASE GATE ERROR: Phase must be 1-7, got '$PHASE'"
        exit 2
    fi
fi

# --- Shared helpers ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

SESSION_DIR=$(resolve_session_dir)
PROGRESS_LOG="$SESSION_DIR/progress-log.json"

# --- Event emit helpers ---
emit_blocked() {
  local reason="$1" action="$2" phase="${3:-}"
  local data
  if [ -n "$phase" ]; then
    data=$(jq -cn --arg reason "$reason" --arg action "$action" --argjson phase "$phase" \
      '{gate:"phase",phase:$phase,action:$action,reason:$reason}')
  else
    data=$(jq -cn --arg reason "$reason" --arg action "$action" \
      '{gate:"phase",action:$action,reason:$reason}')
  fi
  bash "$SCRIPT_DIR/emit-event.sh" gate.blocked --actor "hook:phase-gate" --data "$data" 2>/dev/null || true
}

emit_passed() {
  local action="$1" phase="${2:-}"
  local data
  if [ -n "$phase" ]; then
    data=$(jq -cn --arg action "$action" --argjson phase "$phase" \
      '{gate:"phase",phase:$phase,action:$action}')
  else
    data=$(jq -cn --arg action "$action" \
      '{gate:"phase",action:$action}')
  fi
  bash "$SCRIPT_DIR/emit-event.sh" gate.passed --actor "hook:phase-gate" --data "$data" 2>/dev/null || true
}

# --- Phase name lookup (unified /dev 7-phase workflow) ---
phase_name() {
  case "$1" in
    1) echo "Requirements" ;;
    2) echo "Research" ;;
    3) echo "Plan + Freeze Doc (GATE 1)" ;;
    4) echo "Test Planning" ;;
    5) echo "Implementation + Layer 1 Review" ;;
    6) echo "Verification + Layer 2 Review" ;;
    7) echo "Documentation + Mistake Capture (GATE 2)" ;;
    *) echo "Unknown" ;;
  esac
}

# =============================================
# VERIFY — check progress-log.json exists and is valid (Pre-Workflow only)
# =============================================
if [ "$ACTION" = "verify" ]; then
    if [ ! -f "$PROGRESS_LOG" ]; then
        echo "PHASE GATE FAILED [verify]"
        echo "  progress-log.json does not exist at: $PROGRESS_LOG"
        echo "  Pre-Workflow must initialize session files first."
        emit_blocked "progress-log missing" "verify"
        exit 2
    fi
    if ! jq empty "$PROGRESS_LOG" 2>/dev/null; then
        echo "PHASE GATE FAILED [verify]"
        echo "  progress-log.json is not valid JSON."
        echo "  File: $PROGRESS_LOG"
        emit_blocked "progress-log invalid JSON" "verify"
        exit 2
    fi
    SCHEMA=$(jq -r '.schemaVersion // "missing"' "$PROGRESS_LOG" 2>/dev/null)
    if [ "$SCHEMA" = "missing" ]; then
        echo "PHASE GATE FAILED [verify]"
        echo "  progress-log.json missing schemaVersion field."
        emit_blocked "progress-log missing schemaVersion" "verify"
        exit 2
    fi
    echo "PHASE GATE PASSED [verify]"
    echo "  progress-log.json exists and is valid at: $PROGRESS_LOG"
    emit_passed "verify"
    exit 0
fi

NAME=$(phase_name "$PHASE")

# =============================================
# BEGIN GATE — validate before phase starts
# =============================================
if [ "$ACTION" = "begin" ]; then

    # --- Check 1: progress-log.json must exist (critical for ALL phases) ---
    if [ ! -f "$PROGRESS_LOG" ]; then
        if [ "$PHASE" -eq 1 ]; then
            echo "PHASE GATE FAILED [Phase $PHASE: $NAME]"
            echo "  progress-log.json does not exist at: $PROGRESS_LOG"
            echo "  Pre-Workflow must initialize session files before Phase 1."
            echo "  Run the Pre-Workflow steps first."
        else
            echo "PHASE GATE FAILED [Phase $PHASE: $NAME]"
            echo "  progress-log.json not found. Session may be corrupted."
            echo "  Session dir: $SESSION_DIR"
        fi
        emit_blocked "progress-log missing" "begin" "$PHASE"
        exit 2
    fi

    # --- Check 2: progress-log.json is valid JSON ---
    if ! jq empty "$PROGRESS_LOG" 2>/dev/null; then
        echo "PHASE GATE FAILED [Phase $PHASE: $NAME]"
        echo "  progress-log.json is not valid JSON."
        echo "  File: $PROGRESS_LOG"
        emit_blocked "progress-log invalid JSON" "begin" "$PHASE"
        exit 2
    fi

    # --- Check 3: pipeline status is not failed/completed/interrupted ---
    PIPELINE_STATUS=$(jq -r '.status // "unknown"' "$PROGRESS_LOG" 2>/dev/null)
    if [ "$PIPELINE_STATUS" = "completed" ]; then
        echo "PHASE GATE FAILED [Phase $PHASE: $NAME]"
        echo "  Pipeline already completed. Start a new run or use --from $PHASE to resume."
        emit_blocked "pipeline already completed" "begin" "$PHASE"
        exit 2
    fi
    if [ "$PIPELINE_STATUS" = "failed" ] && [ "$PHASE" -gt 1 ]; then
        FAILED_PHASE=$(jq -r '[.phases[] | select(.status == "failed")] | last | .phase // "unknown"' "$PROGRESS_LOG" 2>/dev/null)
        echo "PHASE GATE WARNING [Phase $PHASE: $NAME]"
        echo "  Pipeline status is 'failed' (Phase $FAILED_PHASE). Proceeding — may be a --from resume."
    fi
    if [ "$PIPELINE_STATUS" = "interrupted" ]; then
        echo "PHASE GATE WARNING [Phase $PHASE: $NAME]"
        echo "  Pipeline was interrupted (session ended mid-run). Proceeding — assumes --from resume."
        echo "  Note: some phases may still have 'in-progress' status from the interrupted session."
    fi

    # --- Check 4: previous phase must be completed/skipped/failed (Phase 2+) ---
    # 'failed' is accepted because --from N resumes past a known failure.
    # 'in-progress' is NOT accepted — indicates a crash that wasn't resolved by
    # the resume handler. The resume protocol (see references/autonomous/session-management.md
    # § Resume Protocol) must resolve mid-phase crashes before gates run.
    if [ "$PHASE" -gt 1 ]; then
        PREV=$((PHASE - 1))
        PREV_STATUS=$(jq -r ".phases[] | select(.phase == $PREV) | .status // \"missing\"" "$PROGRESS_LOG" 2>/dev/null)

        if [ -z "$PREV_STATUS" ] || [ "$PREV_STATUS" = "missing" ]; then
            echo "PHASE GATE FAILED [Phase $PHASE: $NAME]"
            echo "  Phase $PREV ($(phase_name "$PREV")) has no entry in progress-log.json."
            echo "  Cannot start Phase $PHASE without Phase $PREV being tracked."
            emit_blocked "previous phase missing from progress-log" "begin" "$PHASE"
            exit 2
        fi

        VALID_PREV="completed skipped failed"
        if ! echo "$VALID_PREV" | grep -qw "$PREV_STATUS"; then
            echo "PHASE GATE FAILED [Phase $PHASE: $NAME]"
            echo "  Phase $PREV ($(phase_name "$PREV")) status is '$PREV_STATUS', expected one of: $VALID_PREV."
            echo "  Complete or resolve Phase $PREV before starting Phase $PHASE."
            echo "  If resuming after a crash, ensure the resume protocol (references/autonomous/session-management.md § Resume Protocol) resolved the state."
            emit_blocked "previous phase status invalid" "begin" "$PHASE"
            exit 2
        fi

        if [ "$PREV_STATUS" = "failed" ]; then
            echo "PHASE GATE WARNING [Phase $PHASE: $NAME]"
            echo "  Phase $PREV ($(phase_name "$PREV")) status is 'failed'. Proceeding — assumes --from resume."
        fi
    fi

    # --- Check 5: current phase is not already in-progress (double-start guard) ---
    CURRENT_STATUS=$(jq -r ".phases[] | select(.phase == $PHASE) | .status // \"none\"" "$PROGRESS_LOG" 2>/dev/null)
    if [ "$CURRENT_STATUS" = "in-progress" ]; then
        echo "PHASE GATE WARNING [Phase $PHASE: $NAME]"
        echo "  Phase $PHASE is already in-progress. Possible mid-phase crash recovery."
        echo "  Continuing — the orchestrator should handle crash recovery."
    fi

    echo "PHASE GATE PASSED [begin Phase $PHASE: $NAME]"
    echo "  Session: $SESSION_DIR"
    emit_passed "begin" "$PHASE"
    exit 0
fi

# =============================================
# END GATE — validate after phase completes
# =============================================
if [ "$ACTION" = "end" ]; then

    # --- Check 1: progress-log.json still exists ---
    if [ ! -f "$PROGRESS_LOG" ]; then
        echo "PHASE GATE FAILED [end Phase $PHASE: $NAME]"
        echo "  progress-log.json disappeared during phase execution."
        emit_blocked "progress-log disappeared" "end" "$PHASE"
        exit 2
    fi

    # --- Check 2: current phase exists in phases array ---
    PHASE_ENTRY=$(jq -r ".phases[] | select(.phase == $PHASE)" "$PROGRESS_LOG" 2>/dev/null)
    if [ -z "$PHASE_ENTRY" ]; then
        echo "PHASE GATE FAILED [end Phase $PHASE: $NAME]"
        echo "  Phase $PHASE has no entry in progress-log.json."
        echo "  The phase must update the progress map before the end gate."
        emit_blocked "phase entry missing from progress-log" "end" "$PHASE"
        exit 2
    fi

    # --- Check 3: current phase status is completed ---
    CURRENT_STATUS=$(jq -r ".phases[] | select(.phase == $PHASE) | .status" "$PROGRESS_LOG" 2>/dev/null)
    if [ "$CURRENT_STATUS" != "completed" ] && [ "$CURRENT_STATUS" != "skipped" ]; then
        echo "PHASE GATE FAILED [end Phase $PHASE: $NAME]"
        echo "  Phase $PHASE status is '$CURRENT_STATUS', expected 'completed' or 'skipped'."
        echo "  Update progress-log.json before closing the phase gate."
        emit_blocked "phase status not completed" "end" "$PHASE"
        exit 2
    fi

    # --- Check 4: completedAt timestamp is set ---
    COMPLETED_AT=$(jq -r ".phases[] | select(.phase == $PHASE) | .completedAt // \"null\"" "$PROGRESS_LOG" 2>/dev/null)
    if [ "$COMPLETED_AT" = "null" ] || [ -z "$COMPLETED_AT" ]; then
        echo "PHASE GATE FAILED [end Phase $PHASE: $NAME]"
        echo "  Phase $PHASE completedAt is not set."
        echo "  Timestamp the phase completion in progress-log.json."
        emit_blocked "completedAt not set" "end" "$PHASE"
        exit 2
    fi

    # --- Check 5: currentPhase in progress-log is updated ---
    LOGGED_PHASE=$(jq -r '.currentPhase // 0' "$PROGRESS_LOG" 2>/dev/null)
    if [ "$LOGGED_PHASE" -lt "$PHASE" ]; then
        echo "PHASE GATE WARNING [end Phase $PHASE: $NAME]"
        echo "  currentPhase in progress-log.json is $LOGGED_PHASE, expected >= $PHASE."
        echo "  The orchestrator should advance currentPhase after completing a phase."
    fi

    echo "PHASE GATE PASSED [end Phase $PHASE: $NAME]"
    echo "  Status: $CURRENT_STATUS | CompletedAt: $COMPLETED_AT"
    emit_passed "end" "$PHASE"
    exit 0
fi
