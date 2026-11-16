#!/bin/bash
# Shared helpers for dev-framework v6 bin/ scripts. Source it; do not execute it.

# Git Bash on Windows rewrites "origin/main:<path>" into a Windows path unless these are set.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

DEVFW_SCRIPT="$(basename "${0:-devfw}")"

# With MSYS_NO_PATHCONV set, a POSIX path like /tmp/x reaches git.exe unconverted and fails.
# Every path a script passes to git must go through devfw_path first.
devfw_path() {  # devfw_path <path>; prints a path native git understands
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

devfw_die() {  # devfw_die <exit-code> <message>
  echo "$DEVFW_SCRIPT: $2" >&2
  exit "$1"
}

devfw_require() {  # devfw_require <tool>...
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || devfw_die 2 "required tool not found: $t"
  done
}

devfw_config() {  # devfw_config <jq-path> <default>; reads $DEVFW_CONFIG or ./orchestrator.json
  local file="${DEVFW_CONFIG:-./orchestrator.json}" v
  if [ -f "$file" ]; then
    v=$(jq -c "$1 // empty" "$(devfw_path "$file")" 2>/dev/null) || devfw_die 2 "unreadable config: $file"
    if [ -n "$v" ]; then
      case "$v" in \"*\") jq -r . <<<"$v" ;; *) echo "$v" ;; esac
      return 0
    fi
  fi
  echo "$2"
}
