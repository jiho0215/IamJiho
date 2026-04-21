#!/bin/bash
# M3b: every phase YAML has a non-empty instructions section the dispatcher
# can consult alongside SKILL.md prose.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READ="$SCRIPT_DIR/../../hooks/scripts/read-phase.sh"
PHASES="$SCRIPT_DIR/../../phases"

# Every phase must have instructions.entry and instructions.exit
for n in 1 2 3 4 5 6 7; do
  F="$PHASES/phase-$n.yaml"
  ENTRY=$(bash "$READ" "$F" instructions.entry)
  EXIT_STEPS=$(bash "$READ" "$F" instructions.exit)
  [ -n "$ENTRY" ] || { echo "FAIL: phase $n missing instructions.entry"; exit 1; }
  [ -n "$EXIT_STEPS" ] || { echo "FAIL: phase $n missing instructions.exit"; exit 1; }

  # entry should mention phase.started emit
  echo "$ENTRY" | grep -qi "phase.started" || { echo "FAIL: phase $n entry missing phase.started emit"; exit 1; }
  # exit should mention phase.completed emit
  echo "$EXIT_STEPS" | grep -qi "phase.completed" || { echo "FAIL: phase $n exit missing phase.completed emit"; exit 1; }
done

# Phase 3 and 7 must have a gate section
for n in 3 7; do
  GATE=$(bash "$READ" "$PHASES/phase-$n.yaml" instructions.gate)
  [ -n "$GATE" ] || { echo "FAIL: phase $n missing instructions.gate"; exit 1; }
  echo "$GATE" | grep -qi "gate.approved\|gate.rejected" || { echo "FAIL: phase $n gate section missing gate.approved/rejected"; exit 1; }
done

# Phase 5 must have execution_rules and layer1_review
[ -n "$(bash "$READ" "$PHASES/phase-5.yaml" instructions.execution_rules)" ] || { echo "FAIL: phase 5 execution_rules"; exit 1; }
[ -n "$(bash "$READ" "$PHASES/phase-5.yaml" instructions.layer1_review)" ] || { echo "FAIL: phase 5 layer1_review"; exit 1; }

# Phase 6 must have layer2_review and frozen_integrity
[ -n "$(bash "$READ" "$PHASES/phase-6.yaml" instructions.layer2_review)" ] || { echo "FAIL: phase 6 layer2_review"; exit 1; }
[ -n "$(bash "$READ" "$PHASES/phase-6.yaml" instructions.frozen_integrity)" ] || { echo "FAIL: phase 6 frozen_integrity"; exit 1; }

# Phase 7 must have documentation and mistake_capture
[ -n "$(bash "$READ" "$PHASES/phase-7.yaml" instructions.documentation)" ] || { echo "FAIL: phase 7 documentation"; exit 1; }
[ -n "$(bash "$READ" "$PHASES/phase-7.yaml" instructions.mistake_capture)" ] || { echo "FAIL: phase 7 mistake_capture"; exit 1; }

echo "PASS: instructions (M3b)"
