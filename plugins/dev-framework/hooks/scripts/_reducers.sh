#!/bin/bash
# _reducers.sh — Shared helpers for view reducer scripts.
# Source with: . "$(dirname "${BASH_SOURCE[0]}")/_reducers.sh"
# Transitively sources _session-lib.sh if resolve_session_dir is not already defined.

if ! declare -F resolve_session_dir >/dev/null 2>&1; then
  # shellcheck source=./_session-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/_session-lib.sh"
fi

events_file() {
  local sd
  sd=$(resolve_session_dir)
  echo "$sd/events.jsonl"
}

views_dir() {
  local sd
  sd=$(resolve_session_dir)
  echo "$sd/views"
}

ensure_views_dir() {
  mkdir -p "$(views_dir)"
}

# Stream events from events.jsonl; missing file → empty output, exit 0.
read_events() {
  local ef
  ef=$(events_file)
  [ -f "$ef" ] || return 0
  cat "$ef"
}

# Atomic write: stdin → temp → rename. Arg: target path.
atomic_write() {
  local target="$1" tmp="$1.tmp.$$"
  cat > "$tmp"
  if ! mv "$tmp" "$target" 2>/dev/null; then
    sleep 1
    mv "$tmp" "$target"
  fi
}
