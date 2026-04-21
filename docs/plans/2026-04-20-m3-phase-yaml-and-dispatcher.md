# M3 — Phase YAML + Dispatcher + execute.sh + modelProfile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract each phase's metadata (requiredRefs, emits, invocations, artifacts) to `phases/phase-N.yaml`. Introduce `execute.sh` for uniform tool dispatch with auto-event-emission. Add `config.pipeline.modelProfile` knob (no-op default) that will let future model versions skip dead-weight iterations. Narrative prose stays in SKILL.md.

**Architecture:** Phase YAMLs are **metadata only** — they declare what to load, emit, invoke, produce. SKILL.md remains the authoritative narrative source; it gains a dispatcher preamble that reads the current phase's YAML at entry. `execute.sh` is a thin wrapper that standardizes `invoke a named skill/agent/protocol/hook` into a single calling convention with automatic `tool.call.*` event emission.

**Non-goal (M3):** Turning narrative prompts into data. Prompts remain prose in SKILL.md. YAML tells the dispatcher which prose section to consult.

**Tech Stack:** Bash, jq, YAML parsed via `yq` (if available) or fallback to awk-based parser for simple schemas. If yq is not available we use a minimal shell-native YAML reader suitable for our flat-key YAML files.

**Reference:** [docs/specs/2026-04-20-managed-agents-evolution.md](../specs/2026-04-20-managed-agents-evolution.md) §3.4, §3.5, §3.6, §3.7.

---

## File Structure

**Create:**
- `plugins/dev-framework/phases/phase-1.yaml` … `phase-7.yaml` — metadata per phase
- `plugins/dev-framework/phases/README.md` — index + YAML schema doc
- `plugins/dev-framework/hooks/scripts/read-phase.sh` — read a phase YAML field (bash-friendly)
- `plugins/dev-framework/hooks/scripts/execute.sh` — uniform tool dispatch wrapper with auto-events
- `plugins/dev-framework/skills/dev/references/autonomous/dispatcher-spec.md` — dispatcher loop contract + YAML schema
- `plugins/dev-framework/tests/m3/*.test.sh` — one per script + integration

**Modify:**
- `plugins/dev-framework/skills/dev/SKILL.md` — add dispatcher preamble that reads phase YAML for requiredRefs/emits; existing phase prose unchanged
- `plugins/dev-framework/hooks/scripts/ensure-config.sh` — add `modelProfile: "balanced"` to default config
- `plugins/dev-framework/CLAUDE.md` — document phase YAMLs, execute.sh, modelProfile

**Unchanged:**
- Existing hooks (phase-gate, freeze-gate, push-guard, sessionend, precompact) — M3 is additive for them
- M1/M2 primitives (emit-event, get-events, reducers, wake, replay) — untouched

---

## Task 1: Phase YAML schema spec

**Files:**
- Create: `plugins/dev-framework/phases/README.md`

**Rationale:** Before writing 7 YAMLs, lock the schema so they're consistent.

- [ ] **Step 1: Write `phases/README.md`**

Create `plugins/dev-framework/phases/README.md`:

```markdown
# Phase YAMLs

Each `phase-N.yaml` captures Phase N's **metadata** — what it needs, emits, invokes, and produces. Narrative prose lives in [`../skills/dev/SKILL.md`](../skills/dev/SKILL.md).

Read by the dispatcher preamble at phase entry (see [`../skills/dev/references/autonomous/dispatcher-spec.md`](../skills/dev/references/autonomous/dispatcher-spec.md)).

## Schema

```yaml
phase: <int 1-7>
name: <human-readable phase name>
skillMdSection: <anchor into SKILL.md, e.g. "Phase 1 — Requirements">

requiredRefs:
  - <path under skills/dev/references/, e.g. "methodology/DECISION_MAKING.md">
  # Dispatcher lazy-loads these at phase entry. Empty list means phase relies
  # only on the global companion-references table.

emits:
  # Events the orchestrator should emit during this phase.
  entry:
    - type: phase.started
      data: { phase: <N> }
  exit:
    - type: phase.completed
      data: { phase: <N>, metrics: "${phaseMetrics}" }

invokes:
  # Skills, agents, or protocols this phase dispatches.
  - kind: skill
    config: pipeline.skills.requirements
    when: mode == "interactive"
    fallback: inline  # "inline" means SKILL.md prose handles it if skill unavailable
  - kind: protocol
    name: multi-agent-consensus
    input:
      task_type: validate
      agents_config: pipeline.agents.plan
      context_template: "Validate requirements completeness..."

produces:
  - kind: artifact
    path: "docs/specs/${featureSlug}-requirements.md"
  - kind: freeze-doc-sections
    sections: [1, 5, 6]

gates:
  begin:
    - script: phase-gate.sh
      args: ["begin", "<N>"]
  end:
    - script: phase-gate.sh
      args: ["end", "<N>"]

budget:
  seconds: <int>

userGate: <none|1|2>  # marks GATE 1 (phase 3) or GATE 2 (phase 7) phases
```

## Variable substitution

Tokens like `${config.pipeline.skills.requirements}` or `${featureSlug}` are expanded by the dispatcher at runtime using `config.json` and session state.

## Why YAML and not JSON

Hand-editability and multi-line string support (prompt templates). The schema is deliberately flat — no deeply-nested structures — so a simple shell-native parser works when `yq` is not installed.

## Invariants

1. **Metadata only.** No narrative. If you want to explain *how* to do something, update SKILL.md prose.
2. **No runtime state.** Phase YAML must not contain mutable state. State lives in events.jsonl.
3. **Stable references.** A required ref's path must exist in the repo.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/dev-framework/phases/README.md
git commit -m "docs(m3): phase YAML schema spec"
```

---

## Task 2: `read-phase.sh` — YAML reader

**Files:**
- Create: `plugins/dev-framework/hooks/scripts/read-phase.sh`
- Test: `plugins/dev-framework/tests/m3/read-phase.test.sh`

**Rationale:** Our YAMLs use flat schemas. A 100-line bash parser handles them; `yq` is optional.

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m3/read-phase.test.sh`:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READ="$SCRIPT_DIR/../../hooks/scripts/read-phase.sh"
[ -x "$READ" ] || { echo "FAIL: read-phase.sh not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/phase-test.yaml" <<'YAML'
phase: 3
name: "Test Phase"
skillMdSection: "Phase 3 — Test"
requiredRefs:
  - methodology/DECISION_MAKING.md
  - protocols/multi-agent-consensus.md
budget:
  seconds: 120
userGate: 1
YAML

# Get a scalar
[ "$(bash "$READ" "$TMP/phase-test.yaml" phase)" = "3" ] || { echo "FAIL: phase scalar"; exit 1; }
[ "$(bash "$READ" "$TMP/phase-test.yaml" name)" = "Test Phase" ] || { echo "FAIL: name scalar"; exit 1; }
[ "$(bash "$READ" "$TMP/phase-test.yaml" budget.seconds)" = "120" ] || { echo "FAIL: nested scalar"; exit 1; }
[ "$(bash "$READ" "$TMP/phase-test.yaml" userGate)" = "1" ] || { echo "FAIL: userGate"; exit 1; }

# Get a list
REFS=$(bash "$READ" "$TMP/phase-test.yaml" requiredRefs)
echo "$REFS" | grep -q "methodology/DECISION_MAKING.md" || { echo "FAIL: list item 1"; exit 1; }
echo "$REFS" | grep -q "protocols/multi-agent-consensus.md" || { echo "FAIL: list item 2"; exit 1; }
[ "$(echo "$REFS" | wc -l)" = "2" ] || { echo "FAIL: list count"; exit 1; }

# Missing key → empty output, exit 0
OUT=$(bash "$READ" "$TMP/phase-test.yaml" nonexistent)
[ -z "$OUT" ] || { echo "FAIL: missing key should be empty"; exit 1; }

# Missing file → exit 1
set +e
bash "$READ" "$TMP/nonexistent.yaml" phase 2>/dev/null
RC=$?
set -e
[ "$RC" = "1" ] || { echo "FAIL: missing file should exit 1"; exit 1; }

echo "PASS: read-phase"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m3/read-phase.test.sh`
Expected: FAIL with "read-phase.sh not executable"

- [ ] **Step 3: Write `read-phase.sh`**

Create `plugins/dev-framework/hooks/scripts/read-phase.sh`:

```bash
#!/bin/bash
# read-phase.sh — Read a key from a phase YAML file.
#
# Usage: read-phase.sh <yaml-file> <key>
# Key format: dot-separated for nested scalars (e.g. "budget.seconds").
# List fields return one item per line (no leading "- ").
#
# Uses yq if available; falls back to awk-based parser for our flat schema.
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

# Try yq first (if jq-compatible syntax available)
if command -v yq &>/dev/null; then
  # yq eval works for both scalar and list
  OUT=$(yq eval ".$KEY" "$FILE" 2>/dev/null || echo "null")
  if [ "$OUT" = "null" ] || [ -z "$OUT" ]; then
    exit 0
  fi
  # For lists, yq outputs "- item" — strip the "- " prefix
  echo "$OUT" | sed 's/^- //'
  exit 0
fi

# Awk fallback for flat + one-level nested schemas.
# Handles: scalar (key: value), nested (key: \n  subkey: value), and list (key: \n  - item).
awk -v key="$KEY" '
  BEGIN {
    split(key, parts, ".")
    target_depth = length(parts)
    current_path[0] = ""
    in_list = 0
    list_for = ""
  }
  /^[[:space:]]*#/ { next }     # comments
  /^[[:space:]]*$/ { next }      # blank lines
  {
    # Determine indent
    match($0, /^[[:space:]]*/)
    indent = RLENGTH
    depth = int(indent / 2) + 1

    # List item
    if ($0 ~ /^[[:space:]]*- /) {
      if (list_for != "") {
        # Are we matching the requested key at this depth?
        gsub(/^[[:space:]]*- */, "", $0)
        # Strip surrounding quotes if present
        gsub(/^"/, "", $0)
        gsub(/"$/, "", $0)
        if (list_for == key) print $0
      }
      next
    }

    # Parse "key: value" or "key:"
    line = $0
    gsub(/^[[:space:]]+/, "", line)
    colon = index(line, ":")
    if (colon == 0) next
    k = substr(line, 1, colon - 1)
    v = substr(line, colon + 1)
    gsub(/^[[:space:]]+/, "", v)
    gsub(/[[:space:]]+$/, "", v)
    # strip surrounding quotes
    gsub(/^"/, "", v)
    gsub(/"$/, "", v)

    # Track current path
    current_path[depth] = k
    # Clear deeper levels
    for (d = depth + 1; d <= 10; d++) current_path[d] = ""

    # Build full path up to depth
    full = current_path[1]
    for (d = 2; d <= depth; d++) {
      if (current_path[d] != "") full = full "." current_path[d]
    }

    if (full == key) {
      if (v == "") {
        # Could be a list that follows; set flag
        list_for = key
      } else {
        print v
        exit
      }
    } else {
      # If we are inside a list collection for a different key, reset
      if (list_for != "" && depth <= target_depth) list_for = ""
    }
  }
' "$FILE"
```

- [ ] **Step 4: Make executable, run test**

```bash
chmod +x plugins/dev-framework/hooks/scripts/read-phase.sh
bash plugins/dev-framework/tests/m3/read-phase.test.sh
```

Expected: `PASS: read-phase`

- [ ] **Step 5: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/read-phase.sh \
        plugins/dev-framework/tests/m3/read-phase.test.sh
git commit -m "feat(m3): read-phase.sh YAML reader"
```

---

## Task 3: Seven phase YAMLs

**Files:**
- Create: `plugins/dev-framework/phases/phase-1.yaml` ... `phase-7.yaml`

- [ ] **Step 1: Author each phase YAML**

Create each file using the schema from Task 1. The content for each phase should mirror the metadata currently embedded in SKILL.md. Example for Phase 1:

Create `plugins/dev-framework/phases/phase-1.yaml`:

```yaml
phase: 1
name: "Requirements"
skillMdSection: "Phase 1 — Requirements"

requiredRefs:
  - templates/FEATURE_SPEC_TEMPLATE.md

emits:
  entry:
    - type: phase.started
      data: "{\"phase\":1}"
  exit:
    - type: phase.completed
      data: "{\"phase\":1}"

invokes:
  - kind: skill
    config: pipeline.skills.requirements
    when: mode == "interactive"
    fallback: inline
  - kind: protocol
    name: multi-agent-consensus
    input:
      task_type: validate
      agents_config: pipeline.agents.plan
      context: "Validate requirements completeness, unambiguity, and testability."

produces:
  - kind: artifact
    path: "docs/specs/${featureSlug}-requirements.md"
  - kind: freeze-doc-sections
    sections: [1, 5, 6]

gates:
  begin:
    - script: phase-gate.sh
      args: ["begin", "1"]
  end:
    - script: phase-gate.sh
      args: ["end", "1"]

budget:
  seconds: 30

userGate: none
```

Repeat for phases 2-7, each mirroring the corresponding SKILL.md section. Phase 3 has `userGate: 1`, Phase 7 has `userGate: 2`.

Abbreviated content for phases 2-7 (author file in full):

- Phase 2 (Research): requiredRefs: `templates/ADR_TEMPLATE.md`; invokes `pipeline.skills.exploration`, `pipeline.skills.architect`, `multi-agent-consensus`; produces `docs/adr/ADR-NNN-*.md` + freeze sections 2,3,4,7,8; budget 120s.
- Phase 3 (Plan + GATE 1): requiredRefs: `autonomous/review-loop-protocol.md`, `templates/FREEZE_DOC_TEMPLATE.md`; invokes `pipeline.skills.planning`, `multi-agent-consensus`, `review-loop-protocol`; produces freeze doc section 9 + APPROVED status; `userGate: 1`; budget 600s.
- Phase 4 (Test Planning): requiredRefs: `protocols/test-planning.md`, `methodology/TESTING_STRATEGY.md`, `templates/TEST_PLAN_TEMPLATE.md`; invokes `pipeline.skills.tdd`, `multi-agent-consensus`; produces `SESSION_DIR/tdd-plan.md` + `docs/test-plans/...`; budget 120s.
- Phase 5 (Implementation + Layer 1 Review): requiredRefs: `standards/*`, `autonomous/review-loop-protocol.md`, `protocols/multi-agent-consensus.md`; invokes `pipeline.skills.implementation`, `pipeline.skills.requestReview`, `pipeline.skills.receiveReview`, `review-loop-protocol`, `multi-agent-consensus` (agents: review), `pipeline.skills.debugging`; budget 900s.
- Phase 6 (Verification + Layer 2 Review): requiredRefs: `standards/*`, `autonomous/review-loop-protocol.md`; invokes `pipeline.skills.verification`, `pipeline.skills.tdd`, `review-loop-protocol`, `multi-agent-consensus`, `pipeline.skills.receiveReview`; budget 600s.
- Phase 7 (Documentation + GATE 2): requiredRefs: `protocols/project-docs.md`, `methodology/DOCUMENTATION_STANDARDS.md`, `autonomous/mistake-tracker-protocol.md`; invokes `pipeline.skills.finishing`; produces updated ADRs, freeze doc archival, `pipeline-complete.md`; `userGate: 2`; budget 300s.

- [ ] **Step 2: Verify all 7 files are readable via read-phase.sh**

Run:
```bash
for n in 1 2 3 4 5 6 7; do
  f="plugins/dev-framework/phases/phase-$n.yaml"
  echo "--- $f"
  bash plugins/dev-framework/hooks/scripts/read-phase.sh "$f" phase
  bash plugins/dev-framework/hooks/scripts/read-phase.sh "$f" name
  bash plugins/dev-framework/hooks/scripts/read-phase.sh "$f" requiredRefs | head -3
done
```

Expected: each phase reads correctly.

- [ ] **Step 3: Commit**

```bash
git add plugins/dev-framework/phases/phase-*.yaml
git commit -m "feat(m3): phase YAMLs for phases 1-7"
```

---

## Task 4: `execute.sh` — uniform tool dispatch

**Files:**
- Create: `plugins/dev-framework/hooks/scripts/execute.sh`
- Test: `plugins/dev-framework/tests/m3/execute.test.sh`

**Interface:**

```bash
execute.sh <kind> <name> [--input JSON]
# kind ∈ {hook, protocol, skill, agent}
#   hook:     invoke a bash hook script (name is script filename)
#   protocol: load and consult an internal reference protocol (name is markdown file stem)
#   skill:    invocation hint — the orchestrator LLM is expected to call the Skill tool
#   agent:    invocation hint — the orchestrator LLM is expected to dispatch via Task tool
```

For `hook` and `protocol`, execute.sh actually invokes (shell and read, respectively). For `skill` and `agent`, execute.sh emits the `tool.call.started` event and outputs a JSON payload the LLM can forward to the actual Skill/Task tool. The LLM calls back with `execute.sh --complete <kind> <name> --output JSON` to emit `tool.call.completed`.

All invocations emit `tool.call.started` and `tool.call.completed` / `tool.call.failed` automatically.

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m3/execute.test.sh`:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EXEC="$HOOKS/execute.sh"
GET="$HOOKS/get-events.sh"

[ -x "$EXEC" ] || { echo "FAIL: execute.sh not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

# --- Test 1: hook kind — invokes a real hook and emits events ---
# Use phase-gate.sh verify against a valid progress-log
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"status":"in-progress","runId":"run-exec","currentPhase":1,"phases":[]}
JSON
bash "$EXEC" hook phase-gate.sh --input '{"args":["verify"]}' > /dev/null 2>&1 || true

STARTED=$(bash "$GET" --type tool.call.started --format count)
[ "$STARTED" = "1" ] || { echo "FAIL: tool.call.started count != 1 (got $STARTED)"; exit 1; }

COMPLETED=$(bash "$GET" --type tool.call.completed --format count)
[ "$COMPLETED" = "1" ] || { echo "FAIL: tool.call.completed count != 1 (got $COMPLETED)"; exit 1; }

# Verify data fields
KIND=$(bash "$GET" --type tool.call.started --format json | jq -r '.data.kind')
[ "$KIND" = "hook" ] || { echo "FAIL: started.data.kind ($KIND)"; exit 1; }
NAME=$(bash "$GET" --type tool.call.started --format json | jq -r '.data.name')
[ "$NAME" = "phase-gate.sh" ] || { echo "FAIL: started.data.name ($NAME)"; exit 1; }

# --- Test 2: skill kind — emits event + returns JSON payload (no actual invoke) ---
OUT=$(bash "$EXEC" skill "superpowers:brainstorming" --input '{"topic":"test"}')
echo "$OUT" | jq empty || { echo "FAIL: skill output not valid JSON"; exit 1; }
[ "$(echo "$OUT" | jq -r '.kind')" = "skill" ] || { echo "FAIL: skill payload kind"; exit 1; }
[ "$(echo "$OUT" | jq -r '.name')" = "superpowers:brainstorming" ] || { echo "FAIL: skill payload name"; exit 1; }
[ "$(echo "$OUT" | jq -r '.status')" = "dispatched" ] || { echo "FAIL: skill payload status"; exit 1; }

SKILL_EV=$(bash "$GET" --type tool.call.started --actor 'orchestrator' --format count)
[ "$SKILL_EV" -ge "2" ] || { echo "FAIL: skill event not emitted"; exit 1; }

# --- Test 3: --complete flag emits tool.call.completed ---
bash "$EXEC" --complete skill "superpowers:brainstorming" --output '{"result":"ok"}'
COMP_COUNT=$(bash "$GET" --type tool.call.completed --format count)
[ "$COMP_COUNT" = "2" ] || { echo "FAIL: completed count after --complete ($COMP_COUNT)"; exit 1; }

# --- Test 4: failure path emits tool.call.failed ---
bash "$EXEC" --fail skill "superpowers:nonexistent" --error "skill not found"
FAIL_COUNT=$(bash "$GET" --type tool.call.failed --format count)
[ "$FAIL_COUNT" = "1" ] || { echo "FAIL: failed count ($FAIL_COUNT)"; exit 1; }

echo "PASS: execute"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m3/execute.test.sh`
Expected: FAIL

- [ ] **Step 3: Write `execute.sh`**

Create `plugins/dev-framework/hooks/scripts/execute.sh`:

```bash
#!/bin/bash
# execute.sh — Uniform tool dispatch wrapper with automatic tool.call.* event emission.
#
# Usage:
#   execute.sh <kind> <name> [--input JSON]
#     Start a tool call. For kind=hook/protocol, actually invokes. For kind=skill/agent,
#     emits tool.call.started and returns a JSON payload the orchestrator forwards to the
#     appropriate Claude tool.
#
#   execute.sh --complete <kind> <name> [--output JSON]
#     Emit tool.call.completed for a previously started skill/agent call.
#
#   execute.sh --fail <kind> <name> --error MSG
#     Emit tool.call.failed.
set -euo pipefail

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
      if [ -z "$KIND" ]; then KIND="$1"
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
    ARGS=$(echo "$INPUT" | jq -r '.args // [] | join(" ")' 2>/dev/null || echo "")
    if bash "$SCRIPT_DIR/$NAME" $ARGS >/tmp/exec-out-$$ 2>&1; then
      END_MS=$(date +%s%3N 2>/dev/null || echo 0)
      OUTPUT=$(jq -cn --arg out "$(cat /tmp/exec-out-$$)" '{stdout:$out}')
      emit_completed $((END_MS - START_MS))
    else
      RC=$?
      ERR=$(cat /tmp/exec-out-$$)
      emit_failed "hook-exit-$RC"
      rm -f /tmp/exec-out-$$
      exit "$RC"
    fi
    rm -f /tmp/exec-out-$$
    ;;
  protocol)
    REF_PATH="$SCRIPT_DIR/../../skills/dev/references/protocols/$NAME.md"
    if [ -f "$REF_PATH" ]; then
      OUTPUT=$(jq -cn --arg path "$REF_PATH" '{referenceLoaded:$path}')
      END_MS=$(date +%s%3N 2>/dev/null || echo 0)
      emit_completed $((END_MS - START_MS))
    else
      ERR="protocol reference not found: $REF_PATH"
      emit_failed "protocol-not-found"
      exit 1
    fi
    ;;
  skill|agent)
    # Emit started; orchestrator LLM handles actual invocation via Skill/Task tool.
    # Return a dispatch payload the LLM forwards.
    jq -cn --arg kind "$KIND" --arg name "$NAME" --argjson input "$INPUT" \
      '{kind:$kind, name:$name, input:$input, status:"dispatched",
        note:"Orchestrator LLM: invoke the corresponding Claude tool, then call execute.sh --complete with the output."}'
    ;;
esac
exit 0
```

- [ ] **Step 4: Executable + test**

```bash
chmod +x plugins/dev-framework/hooks/scripts/execute.sh
bash plugins/dev-framework/tests/m3/execute.test.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/execute.sh \
        plugins/dev-framework/tests/m3/execute.test.sh
git commit -m "feat(m3): execute.sh uniform tool dispatch with auto events"
```

---

## Task 5: Dispatcher spec reference

**Files:**
- Create: `plugins/dev-framework/skills/dev/references/autonomous/dispatcher-spec.md`

- [ ] **Step 1: Write the spec**

Create `plugins/dev-framework/skills/dev/references/autonomous/dispatcher-spec.md`:

```markdown
# Dispatcher Spec

SKILL.md's phase body is prose; metadata lives in `../../../phases/phase-N.yaml`. The dispatcher preamble reads the YAML at phase entry and uses it to:

1. **Lazy-load required references** (`requiredRefs[]`) — only read what this phase needs.
2. **Emit entry events** (`emits.entry[]`).
3. **Gate** on `gates.begin[]` scripts.
4. **Consult SKILL.md prose** for `skillMdSection` — this is the *narrative* (how to actually do the work, including LLM prompts and dialogue).
5. **Invoke** tools via `execute.sh <kind> <name>` per `invokes[]`.
6. **Produce** artifacts per `produces[]`.
7. **Gate** on `gates.end[]` scripts.
8. **Emit exit events** (`emits.exit[]`).

This separation keeps narrative editable (change SKILL.md) while making metadata machine-actionable (change YAML).

## Dispatcher pseudocode

```
on phase entry:
  yaml = read_phase("phases/phase-${N}.yaml")
  for ref in yaml.requiredRefs:
    load_reference(ref)  # Read tool
  for ev in yaml.emits.entry:
    bash emit-event.sh ${ev.type} --data ${ev.data}
  for g in yaml.gates.begin:
    bash execute.sh hook ${g.script} --input '{"args": ${g.args}}'
  consult SKILL.md §${yaml.skillMdSection} for the phase narrative
  for inv in yaml.invokes:
    bash execute.sh ${inv.kind} ${resolved_name}
  for p in yaml.produces:
    verify artifact produced
  for g in yaml.gates.end:
    bash execute.sh hook ${g.script} --input '{"args": ${g.args}}'
  for ev in yaml.emits.exit:
    bash emit-event.sh ${ev.type} --data ${ev.data}
```

## Variable substitution

YAML token → substitution:

| Token | Source |
|---|---|
| `${featureSlug}` | progress-log.json `.featureSlug` |
| `${ticket}` | progress-log.json `.ticket` |
| `${config.pipeline.skills.X}` | config.json at that path |
| `${config.pipeline.agents.X}` | config.json at that path |
| `${phaseMetrics}` | Dispatcher assembles at phase end from event log |

## Invocation semantics by kind

- **hook**: script under `hooks/scripts/`. `execute.sh hook <name> --input '{"args":[...]}'` runs the script with those args. Exit code is propagated.
- **protocol**: reference under `skills/dev/references/protocols/`. `execute.sh protocol <name>` records that the protocol was loaded (for events); the LLM must still read the file for content.
- **skill**: Claude Skill tool. `execute.sh skill <name>` emits `tool.call.started` and returns a dispatch payload; orchestrator invokes the real Skill tool; then `execute.sh --complete skill <name>` closes the call.
- **agent**: Task subagent. Same protocol as skill.

## Config modelProfile

`config.pipeline.modelProfile ∈ {conservative, balanced, trust-model}`:

- `conservative`: maximum iterations, 3 agents, all gates — for older/cheaper models.
- `balanced`: current defaults (`maxReviewIterations: 10`, `agents: 3`). The M1/M2-era baseline.
- `trust-model`: `maxReviewIterations: null` (model declares convergence), `agents: auto` (1 for frontier). For Opus 4.7+ class models.

Profile changes are recorded in `session.started.data.modelProfile`. Event-log retrospection lets us compare quality across profiles.

## Non-requirements (this is NOT M3)

- Replacing SKILL.md prose with YAML-as-data. Prose narrative stays.
- Machine-evaluated preconditions/postconditions. YAML declares; dispatcher/LLM checks.
- Full multi-brain parallelism. That's M4.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/dev-framework/skills/dev/references/autonomous/dispatcher-spec.md
git commit -m "docs(m3): dispatcher spec reference"
```

---

## Task 6: Lazy reference loading in SKILL.md

**Files:**
- Modify: `plugins/dev-framework/skills/dev/SKILL.md`

- [ ] **Step 1: Add dispatcher preamble at the top of Section B**

Before the `### Phase 1 — Requirements` header, insert a "## Dispatcher Preamble (per-phase)" section explaining that before entering each phase, the orchestrator must read the phase YAML and lazy-load declared refs. Reference dispatcher-spec.md for details.

Specifically, add after the current `### Session Initialization (both modes)` subsection:

```markdown
### Dispatcher Preamble (per phase, M3+)

Before running any phase body below, read `phases/phase-${N}.yaml` and act on its metadata:

1. **Lazy-load refs:** For each entry in `requiredRefs[]`, read that file with the Read tool. Do not eager-load the entire Companion References table — phase YAMLs declare what's actually needed.
2. **Emit entry events:** Execute each emit in `emits.entry[]`.
3. **Run begin gates:** Run each script listed in `gates.begin[]`.
4. **Consult the narrative:** The phase body below (§`skillMdSection`) contains the actual how-to.
5. **Invoke:** For each entry in `invokes[]`, call `execute.sh <kind> <name> --input '...'`. For `kind: skill` and `kind: agent`, you must invoke the actual Skill/Task tool after emit-started and then call `execute.sh --complete` after.
6. **Run end gates** and **emit exit events** when the phase body concludes.

The narrative prose for each phase remains authoritative; YAML is for metadata and automation.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/dev-framework/skills/dev/SKILL.md
git commit -m "docs(m3): add dispatcher preamble to SKILL.md"
```

---

## Task 7: `modelProfile` config knob

**Files:**
- Modify: `plugins/dev-framework/hooks/scripts/ensure-config.sh`
- Test: `plugins/dev-framework/tests/m3/model-profile.test.sh`

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m3/model-profile.test.sh`:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_CONFIG="$TMP/config.json"

bash "$HOOKS/ensure-config.sh"
[ -f "$DEVFW_CONFIG" ] || { echo "FAIL: config not created"; exit 1; }

# Must include modelProfile default
PROFILE=$(jq -r '.pipeline.modelProfile // empty' "$DEVFW_CONFIG")
[ "$PROFILE" = "balanced" ] || { echo "FAIL: modelProfile default != 'balanced' (got $PROFILE)"; exit 1; }

echo "PASS: model-profile"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m3/model-profile.test.sh`
Expected: FAIL with modelProfile empty.

Note: this test needs `ensure-config.sh` to honor `DEVFW_CONFIG` env. If it currently hardcodes `$HOME/.claude/autodev/config.json`, the test will reveal it. Verify ensure-config.sh supports the env override; if not, add support as part of Step 3.

- [ ] **Step 3: Modify `ensure-config.sh`**

Edit `plugins/dev-framework/hooks/scripts/ensure-config.sh`:

1. At the top, replace `CONFIG_DIR="$HOME/.claude/autodev"` and `CONFIG_FILE="$CONFIG_DIR/config.json"` with:

   ```bash
   CONFIG_FILE="${DEVFW_CONFIG:-$HOME/.claude/autodev/config.json}"
   CONFIG_DIR="$(dirname "$CONFIG_FILE")"
   ```

2. In the `cat > "$TMP_FILE" <<'JSON'` heredoc, inside `"pipeline"`, add before `"skills"`:

   ```json
       "modelProfile": "balanced",
   ```

   Value comment (as a sibling doc, not JSON comment since JSON doesn't support them): update `CLAUDE.md` to explain.

- [ ] **Step 4: Run test**

```bash
bash plugins/dev-framework/tests/m3/model-profile.test.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/ensure-config.sh \
        plugins/dev-framework/tests/m3/model-profile.test.sh
git commit -m "feat(m3): modelProfile config knob (default balanced)"
```

---

## Task 8: Integration — phase YAML + dispatcher events

**Files:**
- Create: `plugins/dev-framework/tests/m3/dispatcher-integration.test.sh`

- [ ] **Step 1: Write integration test**

Create a test that simulates a phase entry sequence using the YAMLs + execute.sh:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
PHASES="$SCRIPT_DIR/../../phases"
EMIT="$HOOKS/emit-event.sh"
EXEC="$HOOKS/execute.sh"
READ="$HOOKS/read-phase.sh"
GET="$HOOKS/get-events.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"status":"in-progress","runId":"run-disp","currentPhase":0,"phases":[]}
JSON

# Simulate Phase 1 entry:
# 1. Read YAML metadata
PHASE_NUM=$(bash "$READ" "$PHASES/phase-1.yaml" phase)
[ "$PHASE_NUM" = "1" ] || { echo "FAIL: read phase"; exit 1; }

NAME=$(bash "$READ" "$PHASES/phase-1.yaml" name)
[ "$NAME" = "Requirements" ] || { echo "FAIL: read name"; exit 1; }

# 2. Emit entry event (simulating what the dispatcher does)
bash "$EMIT" phase.started --actor orchestrator --data "{\"phase\":$PHASE_NUM}"

# 3. Dispatch a hook via execute.sh (phase-gate.sh begin 1)
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"status":"in-progress","runId":"run-disp","currentPhase":1,"phases":[]}
JSON
bash "$EXEC" hook phase-gate.sh --input '{"args":["begin","1"]}' > /dev/null 2>&1

# Verify tool.call.started + completed emitted
STARTED=$(bash "$GET" --type tool.call.started --format count)
[ "$STARTED" -ge "1" ] || { echo "FAIL: started event missing"; exit 1; }

COMPLETED=$(bash "$GET" --type tool.call.completed --format count)
[ "$COMPLETED" -ge "1" ] || { echo "FAIL: completed event missing"; exit 1; }

# Verify event stream shows correct ordering
SEQ_ORDER=$(bash "$GET" --format summary | awk '{print $NF}' | paste -sd,)
echo "$SEQ_ORDER" | grep -q "phase.started" || { echo "FAIL: no phase.started in stream"; exit 1; }
echo "$SEQ_ORDER" | grep -q "tool.call" || { echo "FAIL: no tool.call in stream"; exit 1; }

echo "PASS: dispatcher-integration"
```

- [ ] **Step 2: Run test + commit**

```bash
chmod +x plugins/dev-framework/tests/m3/dispatcher-integration.test.sh
bash plugins/dev-framework/tests/m3/dispatcher-integration.test.sh
git add plugins/dev-framework/tests/m3/dispatcher-integration.test.sh
git commit -m "test(m3): phase YAML + dispatcher integration test"
```

---

## Task 9: Run all M1+M2+M3 tests

- [ ] **Step 1: Combined run**

```bash
cd /c/Users/jiho0/repos/dev-framework
set +e
FAILED=0
for t in plugins/dev-framework/tests/m1/*.test.sh plugins/dev-framework/tests/m2/*.test.sh plugins/dev-framework/tests/m3/*.test.sh; do
  bash "$t" > /tmp/t-out 2>&1 && echo "✓ $t" || { echo "✗ $t"; cat /tmp/t-out; FAILED=$((FAILED+1)); }
done
echo "ALL: $([ $FAILED -eq 0 ] && echo PASS || echo "$FAILED FAILED")"
```

Expected: all PASS.

---

## Task 10: CLAUDE.md update

**Files:**
- Modify: `plugins/dev-framework/CLAUDE.md`

- [ ] **Step 1: Add phases/ + execute.sh + modelProfile sections**

Under "Plugin Structure" tree, add `phases/` directory. Under the Events section add `execute.sh` to the primitives list. Add a new "Model Profile (M3+)" subsection under Config:

```markdown
### Model Profile (M3+)

`config.pipeline.modelProfile` controls how aggressively the pipeline assumes model capability:

| Value | Iterations | Agents | Notes |
|---|---|---|---|
| `conservative` | 15 max | 3 | Older or cheaper models |
| `balanced` (default) | 10 max | 3 | Matches M1/M2 behavior |
| `trust-model` | null (model declares) | auto (1 for frontier) | For Opus 4.7+ class |

Profile is recorded on each run via `session.started.data.modelProfile` so retrospective event-log queries can compare quality across profiles.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/dev-framework/CLAUDE.md
git commit -m "docs(m3): document phases/, execute.sh, modelProfile"
```

---

## Self-Review Checklist

**1. Spec coverage:**
- [ ] §3.4 phase YAMLs — Task 3
- [ ] §3.5 dispatcher loop — Tasks 5, 6 (prose dispatcher; full loop is M3b if needed)
- [ ] §3.6 uniform tool dispatch — Task 4
- [ ] §3.7 modelProfile config — Task 7

**2. Behavior preservation:**
- [ ] All M1+M2 tests still pass (Task 9)
- [ ] SKILL.md narrative untouched (only preamble added)
- [ ] Existing hooks unmodified

**3. Non-requirements respected:**
- [ ] No conversion of SKILL.md prompts to YAML
- [ ] No removal of procedural writes (M2 views are still parallel, not authoritative)

**4. Dependencies:**
- [ ] jq (existing), yq (optional — fallback in read-phase.sh)
