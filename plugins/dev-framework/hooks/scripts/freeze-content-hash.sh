#!/bin/bash
# freeze-content-hash.sh <path>: the CONTENT hash of a freeze doc, the one an `owner-said <n> <path>@<hash>` line
# cites (controller ruling R16). It is the doc with the approval fields removed, so the same plan hashes the same
# before and after approval: in the front matter (the first ---/--- block, if line 1 is ---) every line matching
# ^(status|approvedBy|approvedAt|approvedHash|bypassHistory): is dropped, plus the indented continuation lines of
# such a field (a multi-line bypassHistory list). CRs are stripped; prints the sha256 as 64 lowercase hex.
# The one source of this rule: freeze-gate.sh checks with it and the cycle skill writes owner-said with it.
# Exit 0 ok, 2 usage / unreadable file / no sha256 tool.
set -euo pipefail
[ "$#" -eq 1 ] && [ -f "$1" ] || { echo "usage: freeze-content-hash.sh <freeze-doc-path>" >&2; exit 2; }
if command -v sha256sum >/dev/null 2>&1; then SHA() { sha256sum; }
elif command -v shasum >/dev/null 2>&1; then SHA() { shasum -a 256; }
else echo "freeze-content-hash.sh: need sha256sum or shasum" >&2; exit 2; fi
tr -d '\r' <"$1" | awk '
  NR == 1 && /^---[[:space:]]*$/ { fm = 1; print; next }
  fm && /^---[[:space:]]*$/ { fm = 0; drop = 0; print; next }
  fm && /^(status|approvedBy|approvedAt|approvedHash|bypassHistory):/ { drop = 1; next }
  fm && drop && /^[ \t]/ { next }
  { drop = 0; print }
' | SHA | awk '{ print $1 }'
