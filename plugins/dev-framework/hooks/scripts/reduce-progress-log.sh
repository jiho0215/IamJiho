#!/bin/bash
# reduce-progress-log.sh — Regenerate views/progress-log.json from events.jsonl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"
# shellcheck source=./_reducers.sh
. "$SCRIPT_DIR/_reducers.sh"

command -v jq &>/dev/null || { echo "reduce-progress-log: ERROR — jq required" >&2; exit 1; }

EVENTS=$(events_file)
[ -f "$EVENTS" ] || exit 0

ensure_views_dir
VIEW="$(views_dir)/progress-log.json"

jq -s --arg regen "$(iso_utc)" '
  def pick_latest_data(type_prefix; field):
    [ .[] | select(.type | startswith(type_prefix)) | .data[field] // empty ]
    | last // null;

  def build_phases:
    [ .[] | select(.type | startswith("phase.")) ] as $pevs
    | ($pevs | map(.data.phase) | unique | sort) as $nums
    | [ $nums[] as $n
        | ($pevs | map(select(.data.phase == $n))) as $evs
        | ($evs | map(select(.type == "phase.started"))   | first) as $start
        | ($evs | map(select(.type == "phase.completed")) | first) as $complete
        | ($evs | map(select(.type == "phase.failed"))    | first) as $failed
        | {
            phase: $n,
            status: (
              if $failed then "failed"
              elif $complete then "completed"
              elif $start then "in-progress"
              else "unknown"
              end
            ),
            startedAt: ($start.at // null),
            completedAt: ($complete.at // $failed.at // null)
          }
      ];

  def session_status:
    [ .[] | select(.type == "session.started"
                   or .type == "session.interrupted"
                   or .type == "session.completed"
                   or .type == "session.resumed") ]
    | last as $latest
    | if $latest == null then "unknown"
      elif $latest.type == "session.started"     then "in-progress"
      elif $latest.type == "session.interrupted" then "interrupted"
      elif $latest.type == "session.completed"   then "completed"
      else "in-progress"
      end;

  {
    schemaVersion: 1,
    source: "events-reducer",
    regeneratedAt: $regen,
    runId: (
      [ .[] | .runId | select(. != null and . != "") ] | first // null
    ),
    mode:        (pick_latest_data("session.started"; "mode")),
    featureSlug: (pick_latest_data("session.started"; "featureSlug")),
    ticket:      (pick_latest_data("session.started"; "ticket")),
    status:      session_status,
    currentPhase:
      ( [ .[] | select(.type == "phase.started") | .data.phase ] | max // 0 ),
    interruptedAt:
      ( [ .[] | select(.type == "session.interrupted") | .data.interruptedAt ] | last // null ),
    completedAt:
      ( [ .[] | select(.type == "session.completed") | .at ] | last // null ),
    # M2.5: configSnapshot from config.snapshot.recorded (latest wins)
    configSnapshot:
      ( [ .[] | select(.type == "config.snapshot.recorded") | .data ] | last // null ),
    # M2.5: plannedFiles from plan.files.set (latest wins)
    plannedFiles:
      ( [ .[] | select(.type == "plan.files.set") | .data.plannedFiles ] | last // [] ),
    # M2.5: chronicPatternsLoaded count from patterns.loaded
    chronicPatternsLoaded:
      ( [ .[] | select(.type == "patterns.loaded") | .data.count ] | last // 0 ),
    phases: build_phases,
    summary: {
      gateApprovals: {
        gate1: ( [ .[] | select(.type == "gate.approved" and .data.gate == 1) | .data.approvalMode ] | last // null ),
        gate2: ( [ .[] | select(.type == "gate.approved" and .data.gate == 2) | .data.approvalMode ] | last // null )
      },
      bypassCount: ( [ .[] | select(.type == "bypass.created") ] | length ),
      consensusRounds: (
        [ .[] | select(.type == "consensus.iteration.started") | .data.phase ]
        | group_by(.)
        | map({ key: "phase\(.[0])", value: length })
        | from_entries
      ),
      # M2.5: chronic-pattern lifecycle counts
      patternsPromoted: ( [ .[] | select(.type == "patterns.promoted") ] | length ),
      patternsDemoted:  ( [ .[] | select(.type == "patterns.demoted") ] | length )
    }
  }
' "$EVENTS" | atomic_write "$VIEW"

exit 0
