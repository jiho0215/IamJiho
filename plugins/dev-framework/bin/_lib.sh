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

devfw_branch_ok() {  # devfw_branch_ok <name> <what>; refuses option-shaped or invalid branch names
  case "$1" in -*|"") devfw_die 2 "invalid $2: '$1'" ;; esac
  git check-ref-format --branch "$1" >/dev/null 2>&1 || devfw_die 2 "invalid $2: '$1'"
}

# Config lives in the project's core repo: $DEVFW_CONFIG if set, else $DEVFW_CORE/orchestrator.json
# (scripts set DEVFW_CORE from --core-dir). It is never read from the current directory, so
# running a script from an unrelated folder cannot silently pick up, or silently miss, a config.
devfw_config() {  # devfw_config <jq-path> <default>
  local file="${DEVFW_CONFIG:-}" v
  [ -n "$file" ] || { [ -n "${DEVFW_CORE:-}" ] && file="$DEVFW_CORE/orchestrator.json"; }
  if [ -n "$file" ] && [ -f "$file" ]; then
    # Native jq.exe on Windows ends lines with CRLF; strip CR so values compare and match cleanly.
    v=$(jq -c "$1 // empty" "$(devfw_path "$file")" 2>/dev/null | tr -d '\r') || devfw_die 2 "unreadable config: $file"
    if [ -n "$v" ]; then
      case "$v" in \"*\") jq -r . <<<"$v" | tr -d '\r' ;; *) echo "$v" ;; esac
      return 0
    fi
  fi
  echo "$2"
}
