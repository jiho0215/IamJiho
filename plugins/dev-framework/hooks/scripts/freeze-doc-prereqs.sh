#!/bin/bash
# freeze-doc-prereqs.sh
#
# Verify every entry under §11 Prerequisites of a freeze doc is satisfied.
# A prereq is satisfied if:
#   (a) a ticket.merged event for it exists in $SESSION_DIR/events.jsonl, OR
#   (b) git log --grep=<ticketId> finds a merge commit reachable from HEAD.
#
# Usage:
#   SESSION_DIR=/path freeze-doc-prereqs.sh <freeze-doc-path>
#
# Exit codes:
#   0  all prereqs satisfied (or none listed)
#   1  one or more unmet (lists them on stderr)
#   2  usage / file error

set -euo pipefail

[ "$#" -eq 1 ] || { echo "Usage: $0 <freeze-doc-path>" >&2; exit 2; }
FILE="$1"
[ -f "$FILE" ] || { echo "ERROR: file not found: $FILE" >&2; exit 2; }

# Extract prereq ticket ids: lines under "## §11 Prerequisites" matching
# `- \`<id>\` —` pattern. Stop at next "## " header.
extract_prereqs() {
  awk '
    /^## §11 Prerequisites/ { in_section=1; next }
    in_section && /^## / { in_section=0 }
    in_section && /^- `[^`]+`/ {
      match($0, /`[^`]+`/);
      id = substr($0, RSTART+1, RLENGTH-2);
      print id;
    }
  ' "$FILE"
}

PREREQS=$(extract_prereqs)
[ -z "$PREREQS" ] && exit 0

EVENTS="${SESSION_DIR:-}/events.jsonl"
unmet=()

while IFS= read -r ticket; do
  [ -z "$ticket" ] && continue
  ok=0

  # (a) event check
  if [ -f "$EVENTS" ] && \
     grep -qE "\"type\":\"ticket\.merged\".*\"ticketId\":\"$ticket\"" "$EVENTS"; then
    ok=1
  fi

  # (b) git history fallback
  if [ "$ok" = 0 ] && command -v git >/dev/null 2>&1; then
    if git log --grep="$ticket" --merges --format=%H 2>/dev/null | head -1 | grep -q .; then
      ok=1
    fi
  fi

  [ "$ok" = 0 ] && unmet+=("$ticket")
done <<< "$PREREQS"

if [ "${#unmet[@]}" -gt 0 ]; then
  echo "ERROR: unmet prerequisites:" >&2
  for t in "${unmet[@]}"; do echo "  - $t" >&2; done
  exit 1
fi
exit 0
