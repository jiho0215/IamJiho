#!/bin/bash
# v5.1 followup: phase-gate.sh phase_name() must be parameterized by SKILL so
# /spike phases (1-7 -> P1..P7) and /implement phases (5-7 -> E1..E3) print
# accurate names in gate error messages.
set -euo pipefail

SCRIPT="plugins/dev-framework/hooks/scripts/phase-gate.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: phase-gate.sh missing"; exit 1; }

# Static grep checks — the function definitions must be present even if the
# script exits on source (it runs CLI logic at top level).
grep -q 'spike:1) echo "P1 Scope"' "$SCRIPT" \
  || { echo "FAIL: spike P1 mapping missing"; exit 1; }
grep -q 'spike:2) echo "P2 Investigate"' "$SCRIPT" \
  || { echo "FAIL: spike P2 mapping missing"; exit 1; }
grep -q 'spike:3) echo "P3 Decompose"' "$SCRIPT" \
  || { echo "FAIL: spike P3 mapping missing"; exit 1; }
grep -q 'spike:4) echo "P4 Spec"' "$SCRIPT" \
  || { echo "FAIL: spike P4 mapping missing"; exit 1; }
grep -q 'spike:5) echo "P5 Review"' "$SCRIPT" \
  || { echo "FAIL: spike P5 mapping missing"; exit 1; }
grep -q 'spike:6) echo "P6 Approve (GATE 1)"' "$SCRIPT" \
  || { echo "FAIL: spike P6 mapping missing"; exit 1; }
grep -q 'spike:7) echo "P7 Retro"' "$SCRIPT" \
  || { echo "FAIL: spike P7 mapping missing"; exit 1; }

grep -q 'implement:5) echo "E1 Execute"' "$SCRIPT" \
  || { echo "FAIL: implement E1 mapping missing"; exit 1; }
grep -q 'implement:6) echo "E2 Verify"' "$SCRIPT" \
  || { echo "FAIL: implement E2 mapping missing"; exit 1; }
grep -q 'implement:7) echo "E3 Finalize (GATE 2)"' "$SCRIPT" \
  || { echo "FAIL: implement E3 mapping missing"; exit 1; }

# Default-SKILL guard: must default to "implement" so legacy callers keep working
grep -q 'SKILL="${SKILL:-implement}"' "$SCRIPT" \
  || { echo "FAIL: SKILL default-to-implement guard missing"; exit 1; }

# Live exercise: extract the phase_name function with its SKILL assignment
# into a temp script and exercise it. This avoids running phase-gate.sh's
# top-level CLI logic which would exit early.
TMP=$(mktemp -t phase-gate-names.XXXXXX.sh)
trap 'rm -f "$TMP"' EXIT

# Extract the SKILL default line and the phase_name() function body.
# bash >=4 supports multiline awk; this is portable enough for git-bash on Windows.
awk '
  /^SKILL="\$\{SKILL:-implement\}"/ { print; next }
  /^phase_name\(\) \{/,/^\}/         { print; next }
' "$SCRIPT" > "$TMP"

# Sanity: the extracted file should contain at least the function header.
grep -q '^phase_name() {' "$TMP" \
  || { echo "FAIL: extraction of phase_name() failed"; exit 1; }

# Source extract and exercise.
# shellcheck disable=SC1090
. "$TMP"

if ! declare -f phase_name >/dev/null; then
  echo "FAIL: phase_name not defined after sourcing extract"
  exit 1
fi

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [ "$got" != "$want" ]; then
    echo "FAIL: $label expected '$want', got '$got'"
    exit 1
  fi
}

SKILL=spike     assert_eq "$(SKILL=spike     phase_name 1)" "P1 Scope"            "spike:1"
SKILL=spike     assert_eq "$(SKILL=spike     phase_name 2)" "P2 Investigate"      "spike:2"
SKILL=spike     assert_eq "$(SKILL=spike     phase_name 3)" "P3 Decompose"        "spike:3"
SKILL=spike     assert_eq "$(SKILL=spike     phase_name 4)" "P4 Spec"             "spike:4"
SKILL=spike     assert_eq "$(SKILL=spike     phase_name 5)" "P5 Review"           "spike:5"
SKILL=spike     assert_eq "$(SKILL=spike     phase_name 6)" "P6 Approve (GATE 1)" "spike:6"
SKILL=spike     assert_eq "$(SKILL=spike     phase_name 7)" "P7 Retro"            "spike:7"

SKILL=implement assert_eq "$(SKILL=implement phase_name 5)" "E1 Execute"          "implement:5"
SKILL=implement assert_eq "$(SKILL=implement phase_name 6)" "E2 Verify"           "implement:6"
SKILL=implement assert_eq "$(SKILL=implement phase_name 7)" "E3 Finalize (GATE 2)" "implement:7"

# Default-SKILL behavior: when SKILL is unset, the script's `SKILL="${SKILL:-implement}"`
# fixes SKILL=implement. Sourcing the extract set SKILL=implement already, so
# explicit unset-then-call to mirror a legacy caller.
unset SKILL
SKILL="${SKILL:-implement}"
assert_eq "$(phase_name 5)" "E1 Execute" "default-skill:5"
assert_eq "$(phase_name 7)" "E3 Finalize (GATE 2)" "default-skill:7"

echo "PASS"
