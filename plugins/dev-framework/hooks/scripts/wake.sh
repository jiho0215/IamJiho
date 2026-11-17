#!/bin/bash
# wake.sh — Stateless restart primitive. Returns compact JSON with session state.
#
# Output schema:
# {
#   sessionDir, lastSeq, eventCount,
#   runId, mode, featureSlug, ticket,
#   currentPhase, status,
#   pendingAction, minimumContext: { freezeDocPath }
# }
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"
# shellcheck source=./_reducers.sh
. "$SCRIPT_DIR/_reducers.sh"

command -v jq &>/dev/null || { echo "wake: ERROR — jq required" >&2; exit 1; }

SESSION_DIR=$(resolve_session_dir)
EVENTS=$(events_file)
PROGRESS_LOG="$SESSION_DIR/progress-log.json"

FREEZE_DOC_PATH=""
if [ -f "$PROGRESS_LOG" ] && jq empty "$PROGRESS_LOG" 2>/dev/null; then
  FREEZE_DOC_PATH=$(jq -r '.freezeDocPath // ""' "$PROGRESS_LOG" 2>/dev/null)
fi

if [ ! -f "$EVENTS" ]; then
  jq -cn \
    --arg sd "$SESSION_DIR" \
    --arg fd "$FREEZE_DOC_PATH" \
    '{
      sessionDir: $sd, lastSeq: 0, eventCount: 0,
      runId: null, mode: null, featureSlug: null, ticket: null,
      currentPhase: 0, status: "no-session",
      pendingAction: "session.not-started",
      minimumContext: { freezeDocPath: $fd }
    }'
  exit 0
fi

jq -s --arg sd "$SESSION_DIR" --arg fd "$FREEZE_DOC_PATH" '
  def latest(t): [ .[] | select(.type == t) ] | last;

  (latest("session.started"))       as $started
  | (latest("session.interrupted")) as $interrupted
  | (latest("session.completed"))   as $completed
  | ([ .[] | select(.type == "consensus.iteration.started") ] | last) as $last_iter
  | ([ .[] | select(.type == "consensus.converged" or .type == "consensus.forced_stop") ] | last) as $last_cons_end
  | ([ .[] | select(.type == "gate.approved" and .data.gate == 1) ] | last) as $gate1
  | ([ .[] | select(.type == "gate.approved" and .data.gate == 2) ] | last) as $gate2
  | ([ .[] | .seq // 0 ] | max // 0) as $max_seq
  | ([ .[] | select(.type == "phase.started") | .data.phase // 0 ] | max // 0) as $cur_phase
  | ([ .[] | select(.type == "phase.completed") | .data.phase ] | max // 0) as $max_completed_phase

  | (
      if $completed   then "completed"
      elif $interrupted then "interrupted"
      elif $started   then "in-progress"
      else "unknown"
      end
    ) as $status

  | (
      if $last_iter == null then null
      elif ($last_cons_end == null) or ($last_iter.seq > $last_cons_end.seq)
      then $last_iter
      else null
      end
    ) as $active_iter

  | (
      if $status == "completed" then "session.complete"
      elif $status == "interrupted" then "session.ready-to-resume"
      elif $active_iter != null then
        "phase.\($active_iter.data.phase).iteration.\($active_iter.data.iteration).active"
      elif $cur_phase > $max_completed_phase then
        "phase.\($cur_phase).completion"
      elif $cur_phase == 3 and $max_completed_phase == 3 and $gate1 == null then
        "gate.1.pending"
      elif $cur_phase == 7 and $max_completed_phase == 7 and $gate2 == null then
        "gate.2.pending"
      else
        "phase.\($cur_phase + 1).ready"
      end
    ) as $pending

  | {
      sessionDir: $sd,
      lastSeq: $max_seq,
      eventCount: (length),
      runId: ( [ .[] | .runId | select(. != null and . != "") ] | first // null ),
      mode: ($started.data.mode // null),
      featureSlug: ($started.data.featureSlug // null),
      ticket: ($started.data.ticket // null),
      currentPhase: $cur_phase,
      status: $status,
      pendingAction: $pending,
      minimumContext: { freezeDocPath: $fd }
    }
' "$EVENTS"

exit 0
