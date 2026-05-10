#!/bin/bash
set -euo pipefail
SCHEMA="plugins/dev-framework/skills/implement/references/autonomous/events-schema.md"
[ -f "$SCHEMA" ] || { echo "FAIL: schema file missing"; exit 1; }
for type in spike.mode.detected research.dispatched research.findings.captured \
            research.completed research.redispatched ticket.research.completed \
            freeze.doc.approved research.doc.approved; do
  grep -qE "^\| \`$type\`" "$SCHEMA" \
    || { echo "FAIL: event type '$type' not in schema"; exit 1; }
done
echo "PASS"
