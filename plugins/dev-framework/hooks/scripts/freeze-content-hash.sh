#!/bin/bash
# freeze-content-hash.sh <path>: the CONTENT hash of a freeze doc, the one an `owner-said <n> <path>@<hash>` line
# cites (controller ruling R16). It is the doc with the approval fields removed, so the same plan hashes the same
# before and after approval. The rule, exactly:
#   - Front matter = line 1 is --- AND a later line is --- (a CLOSED block). A doc whose front matter is not closed
#     has no front matter: the whole file is hashed, nothing is stripped.
#   - Inside a closed front matter only: a line starting with status:, approvedBy:, approvedAt: or approvedHash: is
#     dropped (that line only); a line starting with bypassHistory: is dropped together with the indented
#     (space/tab) lines right after it (its multi-line list). Indented lines after any OTHER key are kept.
#   - Body lines are never dropped. CRs are stripped. Prints the sha256 as 64 lowercase hex.
# The one source of this rule: freeze-gate.sh checks with it and the cycle skill writes owner-said with it; changing
# it invalidates every owner-said already written, so tests/v6/hooks/freeze-gate.test.sh fences each clause.
# Exit 0 ok, 2 usage / unreadable file / no sha256 tool.
set -euo pipefail
[ "$#" -eq 1 ] && [ -f "$1" ] || { echo "usage: freeze-content-hash.sh <freeze-doc-path>" >&2; exit 2; }
if command -v sha256sum >/dev/null 2>&1; then SHA() { sha256sum; }
elif command -v shasum >/dev/null 2>&1; then SHA() { shasum -a 256; }
else echo "freeze-content-hash.sh: need sha256sum or shasum" >&2; exit 2; fi
tr -d '\r' <"$1" | awk '
  { L[NR] = $0 }
  END {
    close_at = 0
    if (NR >= 2 && L[1] ~ /^---[[:space:]]*$/) {
      for (i = 2; i <= NR; i++) if (L[i] ~ /^---[[:space:]]*$/) { close_at = i; break }
    }
    drop = 0
    for (i = 1; i <= NR; i++) {
      if (close_at && i > 1 && i < close_at) {
        if (L[i] ~ /^(status|approvedBy|approvedAt|approvedHash):/) { drop = 0; continue }
        if (L[i] ~ /^bypassHistory:/) { drop = 1; continue }
        if (drop && L[i] ~ /^[ \t]/) continue
        drop = 0
      }
      print L[i]
    }
  }
' | SHA | awk '{ print $1 }'
