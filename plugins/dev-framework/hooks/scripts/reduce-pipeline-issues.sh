#!/bin/bash
# reduce-pipeline-issues.sh — Regenerate views/pipeline-issues.json from events.jsonl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"
# shellcheck source=./_reducers.sh
. "$SCRIPT_DIR/_reducers.sh"

command -v jq &>/dev/null || { echo "reduce-pipeline-issues: ERROR — jq required" >&2; exit 1; }

EVENTS=$(events_file)
[ -f "$EVENTS" ] || exit 0

ensure_views_dir
VIEW="$(views_dir)/pipeline-issues.json"

jq -s --arg regen "$(iso_utc)" '
  def build_phase_entry($phase_events):
    ($phase_events | [.[] | select(.type == "consensus.iteration.started") | .data.iteration] | unique | sort) as $iters
    | ($phase_events | [.[] | select(.type == "consensus.converged")] | first) as $conv
    | ($phase_events | [.[] | select(.type == "consensus.forced_stop")] | first) as $stop
    | {
        iterations: [
          $iters[] as $i
          | ($phase_events | [.[] | select(.data.iteration == $i)]) as $iev
          | {
              iteration: $i,
              issuesFound: (
                [ $iev[] | select(.type == "consensus.issues.found") | (.data.issues // []) | length ]
                | add // 0
              ),
              fixesApplied: (
                [ $iev[] | select(.type == "consensus.fix.applied") ] | length
              )
            }
        ],
        converged: ($conv != null),
        remainingIssues: ($stop.data.remainingIssues // 0)
      };

  [ .[] | select(.type | startswith("consensus.")) ] as $cevs
  | ($cevs | group_by(.runId // "")) as $by_run
  | {
      schemaVersion: 1,
      source: "events-reducer",
      regeneratedAt: $regen,
      runs: [
        $by_run[] as $run_evs
        | ($run_evs | group_by(.data.phase)) as $phase_groups
        | {
            runId: ($run_evs[0].runId // ""),
            phases: (
              [ $phase_groups[] as $pg
                | { key: "\($pg[0].data.phase)", value: build_phase_entry($pg) }
              ] | from_entries
            )
          }
      ]
    }
' "$EVENTS" | atomic_write "$VIEW"

exit 0
