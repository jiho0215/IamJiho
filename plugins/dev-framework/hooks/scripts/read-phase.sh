#!/bin/bash
# read-phase.sh — Read a key from a phase YAML file.
#
# Usage: read-phase.sh <yaml-file> <key>
# Key format: dot-separated for nested scalars (e.g. "budget.seconds").
# List fields return one item per line (no leading "- ").
set -euo pipefail

FILE="${1:-}"
KEY="${2:-}"

if [ -z "$FILE" ] || [ -z "$KEY" ]; then
  echo "read-phase: ERROR — usage: read-phase.sh <file> <key>" >&2
  exit 1
fi

if [ ! -f "$FILE" ]; then
  echo "read-phase: ERROR — file not found: $FILE" >&2
  exit 1
fi

awk -v key="$KEY" '
  function strip_quotes(s) {
    sub(/^"/, "", s); sub(/"$/, "", s); return s
  }
  BEGIN {
    split(key, parts, ".")
    target_depth = length(parts)
    for (i = 1; i <= 10; i++) path[i] = ""
    found_key = ""
    emit_list = 0
  }
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  {
    # Compute indent
    line = $0
    match(line, /^[[:space:]]*/)
    indent = RLENGTH
    depth = int(indent / 2) + 1

    # List item
    if (line ~ /^[[:space:]]*- /) {
      if (emit_list) {
        gsub(/^[[:space:]]*- */, "", line)
        print strip_quotes(line)
      }
      next
    }

    # Stop emitting list if a non-list line appears at same-or-shallower depth than the list key
    if (emit_list) {
      if (depth <= list_depth) emit_list = 0
    }

    # Parse "key: value" or "key:"
    trimmed = line
    gsub(/^[[:space:]]+/, "", trimmed)
    colon = index(trimmed, ":")
    if (colon == 0) next
    k = substr(trimmed, 1, colon - 1)
    v = substr(trimmed, colon + 1)
    gsub(/^[[:space:]]+/, "", v)
    gsub(/[[:space:]]+$/, "", v)
    v = strip_quotes(v)

    # Record current key at this depth and clear deeper
    path[depth] = k
    for (d = depth + 1; d <= 10; d++) path[d] = ""

    # Build full dotted path
    full = path[1]
    for (d = 2; d <= depth; d++) {
      if (path[d] != "") full = full "." path[d]
    }

    if (full == key) {
      if (v != "") {
        print v
        exit
      } else {
        # Value is on following lines (a list)
        emit_list = 1
        list_depth = depth
      }
    }
  }
' "$FILE"
