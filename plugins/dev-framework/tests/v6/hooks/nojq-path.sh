#!/bin/bash
# Sourced by hook tests (not a test itself: no .test.sh suffix). nojq_path <scratch-dir>: prints a PATH equal to
# the current one minus jq: a PATH entry holding jq is replaced by a scratch dir linking every other entry of it
# (on Windows Git Bash jq usually sits alone in its dir, which is simply dropped). Fails when jq is still found.
nojq_path() {
  local scratch="$1" out="" d f k=0 IFS=:
  for d in $PATH; do
    [ -n "$d" ] || continue
    if [ -e "$d/jq" ] || [ -e "$d/jq.exe" ]; then
      k=$((k + 1)); mkdir -p "$scratch/$k"
      for f in "$d"/*; do
        case "${f##*/}" in jq|jq.exe) continue ;; esac
        [ -e "$f" ] && ln -s "$f" "$scratch/$k/" 2>/dev/null
      done
      d="$scratch/$k"
    fi
    out="${out:+$out:}$d"
  done
  if PATH="$out" command -v jq >/dev/null 2>&1; then return 1; fi
  printf '%s\n' "$out"
}
