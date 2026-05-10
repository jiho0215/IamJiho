#!/bin/bash
# freeze-doc-hash.sh
#
# Compute or verify the canonical-body sha256 of a freeze doc.
#
# Canonical body = full file content with these lines stripped:
#   - the `approvedHash:` line (it can't hash itself)
#   - the `bypassHistory:` line and any continuation rows (legitimately mutates)
#
# Usage:
#   freeze-doc-hash.sh compute <path>     -> prints sha256 hex (no trailing space)
#   freeze-doc-hash.sh verify <path>      -> exit 0 if approvedHash in file matches recomputed; exit 1 otherwise
#
# Exit codes:
#   0  success
#   1  verify mismatch
#   2  usage / file error

set -euo pipefail

usage() { echo "Usage: $0 {compute|verify} <freeze-doc-path>" >&2; exit 2; }

[ "$#" -eq 2 ] || usage
CMD="$1"; FILE="$2"
[ -f "$FILE" ] || { echo "ERROR: file not found: $FILE" >&2; exit 2; }

# Pick a sha256 utility
if command -v sha256sum >/dev/null 2>&1; then
  SHA() { sha256sum | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  SHA() { shasum -a 256 | awk '{print $1}'; }
else
  echo "ERROR: need sha256sum or shasum" >&2; exit 2
fi

# Strip approvedHash line + bypassHistory block (single-line array form
# OR multiline YAML list). Conservative: strip approvedHash exact match,
# and bypassHistory line plus any indented continuation lines.
canonical_body() {
  awk '
    /^approvedHash:/ { next }
    /^bypassHistory:/ { in_bh=1; next }
    in_bh && /^[ \t]/ { next }
    { in_bh=0; print }
  ' "$1" | tr -d '\r'
}

case "$CMD" in
  compute)
    canonical_body "$FILE" | SHA
    ;;
  verify)
    EXPECTED=$(awk '/^approvedHash:/{print $2; exit}' "$FILE" | tr -d '"')
    [ -n "$EXPECTED" ] && [ "$EXPECTED" != "null" ] || {
      echo "ERROR: approvedHash missing or null" >&2; exit 1
    }
    ACTUAL=$(canonical_body "$FILE" | SHA)
    if [ "$EXPECTED" = "$ACTUAL" ]; then
      exit 0
    else
      echo "ERROR: hash mismatch (expected=$EXPECTED actual=$ACTUAL)" >&2
      exit 1
    fi
    ;;
  *)
    usage
    ;;
esac
