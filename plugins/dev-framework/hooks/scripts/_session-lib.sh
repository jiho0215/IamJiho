#!/bin/bash
# _session-lib.sh — Shared helpers for dev-framework hooks.
# Source with: . "$(dirname "${BASH_SOURCE[0]}")/_session-lib.sh"
#
# Exports: cfg, sanitize_branch, get_repo_name, resolve_session_dir, iso_utc
# Env: DEVFW_CONFIG override default config path
#      DEVFW_TEST_SESSION_DIR override session resolution (tests only)

: "${DEVFW_CONFIG:=$HOME/.claude/autodev/config.json}"

cfg() {
  if [ -f "$DEVFW_CONFIG" ] && command -v jq &>/dev/null; then
    local val
    val=$(jq -r "($1) // empty" "$DEVFW_CONFIG" 2>/dev/null)
    if [ -n "$val" ]; then echo "$val"; return; fi
  fi
  echo "$2"
}

sanitize_branch() {
  echo "$1" | sed 's|[/\\:*?"<>|@]|-|g' | sed 's|\.\.*$||' | cut -c1-64
}

get_repo_name() {
  local url toplevel
  url=$(git remote get-url origin 2>/dev/null) && { basename "$url" .git; return; }
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) && { basename "$toplevel"; return; }
  basename "$(pwd)"
}

resolve_session_dir() {
  if [ -n "${DEVFW_TEST_SESSION_DIR:-}" ]; then
    echo "$DEVFW_TEST_SESSION_DIR"
    return
  fi
  local sessions_dir branch repo sanitized_branch session_format session_name
  sessions_dir=$(cfg '.paths.sessionsDir' "$HOME/.claude/autodev/sessions")
  sessions_dir="${sessions_dir/#\~/$HOME}"
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
  repo=$(get_repo_name)
  sanitized_branch=$(sanitize_branch "$branch")
  session_format=$(cfg '.sessionFolderFormat' '{repo}--{branch}')
  session_name="${session_format/\{repo\}/$repo}"
  session_name="${session_name/\{branch\}/$sanitized_branch}"
  echo "$sessions_dir/$session_name"
}

iso_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
