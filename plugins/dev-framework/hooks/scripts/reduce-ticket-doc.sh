#!/bin/bash
# reduce-ticket-doc.sh — For each ticket ref doc under
# <repo>/docs/plan/<epicId>/, regenerate:
#   1. §6 Implementation Notes (between <!-- BEGIN AUTO-GENERATED IMPL LOG --> sentinels) —
#      a condensed log of ticket.* and per-ticket phase.* / consensus.* / gate.* events.
#   2. Frontmatter .status — derived from latest ticket.* event for this ticketId.
#
# Source of truth: events.jsonl. Writer: between sentinels (for §6) and
# frontmatter block (for status). All other content preserved verbatim.
#
# No-op conditions mirror reduce-spike-plan.sh: missing events, no epicId,
# no plan folder, no sentinel markers in the ref doc.

set -uo pipefail
trap 'exit 0' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"
# shellcheck source=./_reducers.sh
. "$SCRIPT_DIR/_reducers.sh"

command -v jq &>/dev/null || exit 0
command -v awk &>/dev/null || exit 0

EVENTS=$(events_file)
[ -f "$EVENTS" ] || exit 0

SESSION_DIR=$(resolve_session_dir)
PROGRESS_LOG="$SESSION_DIR/progress-log.json"
EPIC_ID=""
if [ -f "$PROGRESS_LOG" ]; then
    EPIC_ID=$(jq -r '.epicId // empty' "$PROGRESS_LOG" 2>/dev/null)
fi
if [ -z "$EPIC_ID" ]; then
    EPIC_ID=$(jq -rs '[.[] | select(.type == "session.started") | .data.epicId // empty] | last // empty' "$EVENTS" 2>/dev/null)
fi
[ -n "$EPIC_ID" ] || exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[ -n "$REPO_ROOT" ] || exit 0
PLAN_DIR="$REPO_ROOT/docs/plan/$EPIC_ID"
[ -d "$PLAN_DIR" ] || exit 0

REGEN_AT=$(iso_utc)
BEGIN_MARK='<!-- BEGIN AUTO-GENERATED IMPL LOG -->'
END_MARK='<!-- END AUTO-GENERATED IMPL LOG -->'

# Iterate over every per-ticket ref doc in the plan folder, skipping spike-plan.md
# and anything under shared/.
for DOC in "$PLAN_DIR"/*.md; do
    [ -f "$DOC" ] || continue
    BASENAME=$(basename "$DOC" .md)
    [ "$BASENAME" = "spike-plan" ] && continue

    # Require both sentinels; skip silently otherwise.
    grep -qF "$BEGIN_MARK" "$DOC" || continue
    grep -qF "$END_MARK"   "$DOC" || continue

    TICKET_ID=$(awk '
        BEGIN { in_fm = 0; dashes = 0 }
        /^---[[:space:]]*$/ { dashes++; if (dashes == 1) { in_fm = 1; next } else { exit } }
        in_fm && /^ticketId:[[:space:]]*/ {
            sub(/^ticketId:[[:space:]]*/, "")
            sub(/[[:space:]]*$/, "")
            print
            exit
        }
    ' "$DOC")
    [ -n "$TICKET_ID" ] || continue

    # Build impl log entries for this ticket. Include:
    # - ticket.started / ticket.discovery / ticket.merged
    # - phase.started / phase.completed tagged with this ticket's runId
    # - consensus.converged / consensus.forced_stop for this ticket
    # - gate.approved / gate.rejected for this ticket
    #
    # Because only /implement emits the phase/consensus/gate events (not tagged with
    # ticketId directly), we join by runId: find the runId associated with
    # ticket.started for this ticket, then include events sharing that runId.
    IMPL_LOG=$(jq -rs --arg epic "$EPIC_ID" --arg tid "$TICKET_ID" '
        # runIds associated with this ticket (typically one per /implement invocation)
        def ticket_run_ids:
            [ .[] | select(.type == "ticket.started"
                           and .data.epicId == $epic
                           and .data.ticketId == $tid)
                  | .runId ] | unique;

        . as $all
        | ticket_run_ids as $rids
        | ($all
          | map(select(
                (.type | startswith("ticket.") and (
                    .data.epicId == $epic and .data.ticketId == $tid
                ))
                or (
                    ($rids | length > 0)
                    and (.runId as $r | $rids | index($r) != null)
                    and (
                        (.type | startswith("phase."))
                        or (.type | startswith("consensus.converged"))
                        or (.type | startswith("consensus.forced_stop"))
                        or (.type | startswith("gate."))
                    )
                )
          ))
          | sort_by(.seq)
          | map(
              "- seq " + (.seq|tostring) + " [" + (.at // "") + "] " + .type +
              (
                if .type == "ticket.started"    then " (branch=" + (.data.branch // "?") + ")"
                elif .type == "ticket.merged"   then " (pr=" + (.data.prUrl // "?") + ")"
                elif .type == "ticket.discovery" then " §" + (.data.section // "?") + ": " + (.data.correction // "")
                elif .type == "phase.started"   then " phase=" + (.data.phase | tostring)
                elif .type == "phase.completed" then " phase=" + (.data.phase | tostring)
                elif .type == "consensus.converged" then " phase=" + (.data.phase | tostring) + " iters=" + ((.data.iterations // 0) | tostring) + " fixed=" + ((.data.issuesFixed // 0) | tostring)
                elif .type == "gate.approved"   then " gate=" + ((.data.gate // "?") | tostring) + " by=" + (.data.approvedBy // "?")
                elif .type == "gate.rejected"   then " gate=" + ((.data.gate // "?") | tostring) + " reason=" + (.data.reason // "?")
                else ""
                end
              )
            )
          | join("\n")
        )
    ' "$EVENTS" 2>/dev/null) || continue

    # Resolve status for frontmatter: merged > in-impl > planned
    STATUS=$(jq -rs --arg epic "$EPIC_ID" --arg tid "$TICKET_ID" '
        . as $all
        | if any($all[]; .type == "ticket.merged" and .data.epicId == $epic and .data.ticketId == $tid)
          then "merged"
          elif any($all[]; .type == "ticket.started" and .data.epicId == $epic and .data.ticketId == $tid)
          then "in-impl"
          else "planned"
          end
    ' "$EVENTS" 2>/dev/null) || STATUS="planned"

    REPLACEMENT=$(
        printf '%s\n' "$BEGIN_MARK"
        printf '<!-- Regenerated by reduce-ticket-doc.sh at %s -->\n' "$REGEN_AT"
        if [ -n "$IMPL_LOG" ]; then
            printf '%s\n' "$IMPL_LOG"
        else
            printf '_No implementation events recorded for this ticket yet._\n'
        fi
        printf '%s\n' "$END_MARK"
    )

    # Rewrite the doc: update frontmatter status + replace §6 sentinel block.
    awk -v BEGIN_MARK="$BEGIN_MARK" -v END_MARK="$END_MARK" \
        -v REPLACEMENT="$REPLACEMENT" -v STATUS="$STATUS" '
        BEGIN { in_fm = 0; dashes = 0; skip = 0 }
        /^---[[:space:]]*$/ {
            dashes++
            if (dashes == 1) { in_fm = 1; print; next }
            if (dashes == 2) { in_fm = 0; print; next }
        }
        in_fm && /^status:[[:space:]]*/ {
            print "status: " STATUS
            next
        }
        index($0, BEGIN_MARK) {
            print REPLACEMENT
            skip = 1
            next
        }
        index($0, END_MARK) {
            skip = 0
            next
        }
        skip == 0 { print }
    ' "$DOC" | atomic_write "$DOC"
done

exit 0
