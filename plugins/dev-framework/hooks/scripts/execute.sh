#!/bin/bash
# execute.sh — Uniform tool dispatch wrapper with automatic tool.call.* event emission.
#
# Usage:
#   execute.sh <kind> <name> [--input JSON]
#     Start a tool call. For kind=hook/protocol, actually invokes.
#     For kind=skill/agent, emits tool.call.started and returns a JSON dispatch
#     payload the orchestrator forwards to the matching Claude tool.
#
#   execute.sh --complete <kind> <name> [--output JSON]
#     Emit tool.call.completed (close out a previously-started skill/agent call).
#
#   execute.sh --fail <kind> <name> --error MSG
#     Emit tool.call.failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

command -v jq &>/dev/null || { echo "execute: ERROR — jq required" >&2; exit 1; }

MODE="start"
KIND=""
NAME=""
INPUT='{}'
OUTPUT='{}'
ERR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --complete) MODE="complete"; shift ;;
    --fail)     MODE="fail";     shift ;;
    --input)    INPUT="$2";      shift 2 ;;
    --output)   OUTPUT="$2";     shift 2 ;;
    --error)    ERR="$2";        shift 2 ;;
    *)
      if   [ -z "$KIND" ]; then KIND="$1"
      elif [ -z "$NAME" ]; then NAME="$1"
      else echo "execute: ERROR — unexpected arg '$1'" >&2; exit 1
      fi
      shift ;;
  esac
done

[ -n "$KIND" ] && [ -n "$NAME" ] || { echo "execute: ERROR — kind and name required" >&2; exit 1; }

case "$KIND" in
  hook|protocol|skill|agent) ;;
  *) echo "execute: ERROR — invalid kind '$KIND' (hook|protocol|skill|agent)" >&2; exit 1 ;;
esac

emit_started() {
  bash "$SCRIPT_DIR/emit-event.sh" tool.call.started \
    --actor orchestrator \
    --data "$(jq -cn --arg kind "$KIND" --arg name "$NAME" --argjson input "$INPUT" \
      '{kind:$kind, name:$name, input:$input}')" \
    2>/dev/null || true
}

emit_completed() {
  local dur="$1"
  bash "$SCRIPT_DIR/emit-event.sh" tool.call.completed \
    --actor orchestrator \
    --data "$(jq -cn --arg kind "$KIND" --arg name "$NAME" --argjson output "$OUTPUT" --argjson dur "$dur" \
      '{kind:$kind, name:$name, output:$output, durationMs:$dur}')" \
    2>/dev/null || true
}

emit_failed() {
  local src="$1"
  bash "$SCRIPT_DIR/emit-event.sh" tool.call.failed \
    --actor orchestrator \
    --data "$(jq -cn --arg kind "$KIND" --arg name "$NAME" --arg src "$src" --arg err "$ERR" \
      '{kind:$kind, name:$name, failureSource:$src, error:$err}')" \
    2>/dev/null || true
}

if [ "$MODE" = "complete" ]; then
  emit_completed 0
  exit 0
fi

if [ "$MODE" = "fail" ]; then
  emit_failed "explicit"
  exit 0
fi

# --- start mode ---
emit_started
START_MS=$(date +%s%3N 2>/dev/null || echo 0)

case "$KIND" in
  hook)
    ARGS_JSON=$(echo "$INPUT" | jq -r '.args // [] | @sh' 2>/dev/null || echo "")
    TMP_OUT=$(mktemp)
    # shellcheck disable=SC2086
    if eval bash "$SCRIPT_DIR/$NAME" "$ARGS_JSON" >"$TMP_OUT" 2>&1; then
      END_MS=$(date +%s%3N 2>/dev/null || echo 0)
      DUR=$((END_MS - START_MS))
      [ "$DUR" -lt 0 ] && DUR=0
      OUTPUT=$(jq -cn --arg out "$(cat "$TMP_OUT")" '{stdout:$out}')
      emit_completed "$DUR"
    else
      RC=$?
      ERR=$(cat "$TMP_OUT")
      emit_failed "hook-exit-$RC"
      rm -f "$TMP_OUT"
      exit "$RC"
    fi
    rm -f "$TMP_OUT"
    ;;
  protocol)
    REF_PATH="$SCRIPT_DIR/../../skills/implement/references/protocols/$NAME.md"
    if [ -f "$REF_PATH" ]; then
      OUTPUT=$(jq -cn --arg path "$REF_PATH" '{referenceLoaded:$path}')
      END_MS=$(date +%s%3N 2>/dev/null || echo 0)
      DUR=$((END_MS - START_MS))
      [ "$DUR" -lt 0 ] && DUR=0
      emit_completed "$DUR"
    else
      ERR="protocol reference not found: $REF_PATH"
      emit_failed "protocol-not-found"
      exit 1
    fi
    ;;
  skill|agent)
    jq -cn --arg kind "$KIND" --arg name "$NAME" --argjson input "$INPUT" \
      '{kind:$kind, name:$name, input:$input, status:"dispatched",
        note:"Orchestrator LLM: invoke the corresponding Claude tool, then call execute.sh --complete with the output."}'
    ;;
esac
exit 0
