#!/bin/bash
# fan-out.sh — Spawn a child session folder (optionally sharing events.jsonl).
#
# Usage: fan-out.sh --name NAME [--target-dir DIR] [--share-events]
#
# Output (stdout): absolute path to child session dir.
# Event emitted in PARENT session: fan-out.spawned {childDir, name, shared}.
#
# Git-worktree creation and Claude/Task subagent dispatch are the orchestrator's
# responsibility. This script only prepares the session-folder substrate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

command -v jq &>/dev/null || { echo "fan-out: ERROR — jq required" >&2; exit 1; }

NAME=""
TARGET_DIR=""
SHARE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --name)          NAME="$2"; shift 2 ;;
    --target-dir)    TARGET_DIR="$2"; shift 2 ;;
    --share-events)  SHARE=1; shift ;;
    *) echo "fan-out: ERROR — unknown flag '$1'" >&2; exit 1 ;;
  esac
done

[ -n "$NAME" ] || { echo "fan-out: ERROR — --name required" >&2; exit 1; }
[ -n "$TARGET_DIR" ] || TARGET_DIR="/tmp/devfw-fanout"

PARENT_DIR=$(resolve_session_dir)
CHILD_DIR="$TARGET_DIR/$NAME"
mkdir -p "$CHILD_DIR"

PARENT_RUN_ID=""
if [ -f "$PARENT_DIR/progress-log.json" ]; then
  PARENT_RUN_ID=$(jq -r '.runId // empty' "$PARENT_DIR/progress-log.json" 2>/dev/null || echo "")
fi

# Construct progress-log via stdin pipe to sidestep git-bash MSYS path translation
# that would rewrite /tmp/... values in --arg (only triggers for arguments that
# look like POSIX absolute paths).
printf '{"schemaVersion":1,"runId":"%s","mode":"fan-out-child","parentName":"%s","status":"in-progress","phases":[]}\n' \
  "$PARENT_RUN_ID" "$NAME" \
  | jq -c . \
  > "$CHILD_DIR/progress-log.json"

if [ "$SHARE" = "1" ] && [ -f "$PARENT_DIR/events.jsonl" ]; then
  # Try true sharing: symlink first, then hardlink. Verify the link is real —
  # on git-bash Windows, ln -s returns success but silently creates a copy.
  LINKED=0
  rm -f "$CHILD_DIR/events.jsonl" 2>/dev/null
  if ln -s "$PARENT_DIR/events.jsonl" "$CHILD_DIR/events.jsonl" 2>/dev/null \
     && [ -L "$CHILD_DIR/events.jsonl" ]; then
    LINKED=1
    ln -s "$PARENT_DIR/.seq" "$CHILD_DIR/.seq" 2>/dev/null || true
  else
    rm -f "$CHILD_DIR/events.jsonl" 2>/dev/null
    # Hardlink test: both paths share inode
    if cp -l "$PARENT_DIR/events.jsonl" "$CHILD_DIR/events.jsonl" 2>/dev/null; then
      PARENT_INODE=$(stat -c '%i' "$PARENT_DIR/events.jsonl" 2>/dev/null || echo 0)
      CHILD_INODE=$(stat -c '%i' "$CHILD_DIR/events.jsonl" 2>/dev/null || echo 1)
      if [ -n "$PARENT_INODE" ] && [ "$PARENT_INODE" = "$CHILD_INODE" ] && [ "$PARENT_INODE" != "0" ]; then
        LINKED=1
        cp -l "$PARENT_DIR/.seq" "$CHILD_DIR/.seq" 2>/dev/null || true
      fi
    fi
  fi
  if [ "$LINKED" = "0" ]; then
    echo "fan-out: WARNING — platform does not support true file linking (Windows without Developer Mode?); falling back to copy (one-way, not shared)" >&2
    rm -f "$CHILD_DIR/events.jsonl" 2>/dev/null
    cp "$PARENT_DIR/events.jsonl" "$CHILD_DIR/events.jsonl"
    [ -f "$PARENT_DIR/.seq" ] && cp "$PARENT_DIR/.seq" "$CHILD_DIR/.seq"
  fi
fi

# Emit the parent-side event (re-target resolution to parent temporarily)
DEVFW_TEST_SESSION_DIR_SAVED="${DEVFW_TEST_SESSION_DIR:-}"
export DEVFW_TEST_SESSION_DIR="$PARENT_DIR"
SHARED_STR=$([ "$SHARE" = "1" ] && echo true || echo false)
DATA_JSON=$(printf '{"childDir":"%s","name":"%s","shared":%s}' "$CHILD_DIR" "$NAME" "$SHARED_STR")
bash "$SCRIPT_DIR/emit-event.sh" fan-out.spawned \
  --actor orchestrator \
  --data "$DATA_JSON" \
  2>/dev/null || true
if [ -n "$DEVFW_TEST_SESSION_DIR_SAVED" ]; then
  export DEVFW_TEST_SESSION_DIR="$DEVFW_TEST_SESSION_DIR_SAVED"
else
  unset DEVFW_TEST_SESSION_DIR
fi

echo "$CHILD_DIR"
exit 0
