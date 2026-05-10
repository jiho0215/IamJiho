#!/bin/bash
set -euo pipefail
SCHEMA="plugins/dev-framework/skills/implement/references/autonomous/events-schema.md"
[ -f "$SCHEMA" ] || { echo "FAIL: schema file missing"; exit 1; }
for type in spike.mode.detected research.dispatched research.findings.captured \
            research.completed research.redispatched ticket.research.completed \
            freeze.doc.approved research.doc.approved; do
  # Require exactly 3 pipe-delimited cells:
  #   | `type` | `{data-shape}` | non-empty-emitter |
  # Data column must be a backtick-quoted brace-block (handles nested braces via
  # greedy .*); emitter column must have at least one non-pipe character.
  grep -qE "^\| \`$type\` \| \`\{.*\}\` \| [^|]+ \|" "$SCHEMA" \
    || { echo "FAIL: event type '$type' not in schema with valid 3-cell shape"; exit 1; }
done
echo "PASS"
