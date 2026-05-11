#!/bin/bash
set -euo pipefail
F="plugins/dev-framework/skills/spike/references/protocols/research-dispatch.md"
[ -f "$F" ] || { echo "FAIL: protocol missing"; exit 1; }
for kw in "fan-out.sh" "research.dispatched" "research.completed" \
          "research.redispatched" "outputDocPath" "blockedStoryTickets" \
          "interactionAllowed"; do
  grep -qF "$kw" "$F" || { echo "FAIL: keyword '$kw' missing"; exit 1; }
done
echo "PASS"
