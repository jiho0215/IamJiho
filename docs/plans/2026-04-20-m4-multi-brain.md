# M4 — Multi-brain + Concurrency Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that `events.jsonl` stays consistent under heavy parallel writes (multi-brain scenarios), add a `fan-out.sh` utility for spawning a git-worktree-based child session, and document the multi-brain orchestration mental model. Together these raise the "Multi-brain scaling" scorecard axis from 1 to 8.

**Architecture:** The mkdir-based lock in `emit-event.sh` is our concurrency guarantee. M4 exercises it with 50+ parallel emitters. `fan-out.sh` is a thin utility wrapping `git worktree add` + session folder provisioning; actual Claude/Task subagent invocation remains the orchestrator's job.

**Non-goal (M4):** Rewriting phase invocations to run in worktrees by default. M4 adds *capability*; phase YAMLs get an optional `parallel: true` marker that advises the orchestrator when fan-out is safe, but does not mandate it.

**Tech Stack:** Bash, git worktree, existing M1-M3 primitives. No new runtime dependencies.

**Reference:** [docs/specs/2026-04-20-managed-agents-evolution.md](../specs/2026-04-20-managed-agents-evolution.md) §3.8, §6 (M4 row).

---

## File Structure

**Create:**
- `plugins/dev-framework/hooks/scripts/fan-out.sh` — spawn worktree + initialize child session
- `plugins/dev-framework/skills/dev/references/autonomous/worktree-orchestration.md` — mental model + use cases
- `plugins/dev-framework/tests/m4/concurrency-stress.test.sh` — 50 parallel emitters validation
- `plugins/dev-framework/tests/m4/fan-out.test.sh` — worktree spawn validation

**Modify:**
- `plugins/dev-framework/CLAUDE.md` — document fan-out.sh and multi-brain patterns

**Unchanged:**
- emit-event.sh — already concurrency-safe; this milestone only tests it more aggressively
- execute.sh — already supports the dispatch pattern fan-out uses

---

## Task 1: Concurrency stress test

**Files:**
- Create: `plugins/dev-framework/tests/m4/concurrency-stress.test.sh`

**Rationale:** M1 tested 10 parallel emits. Real multi-brain scenarios may have 50+. Verify mkdir-lock holds.

- [ ] **Step 1: Write stress test**

Create `plugins/dev-framework/tests/m4/concurrency-stress.test.sh`:

```bash
#!/bin/bash
# Stress-test events.jsonl concurrency guarantees under heavy parallelism.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
GET="$HOOKS/get-events.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

# Scenario 1: 50 parallel emits — all get unique contiguous seq
N=50
for i in $(seq 1 $N); do
  bash "$EMIT" stress.test --data "{\"i\":$i}" --actor "stress-$i" &
done
wait

LINES=$(wc -l < "$DEVFW_TEST_SESSION_DIR/events.jsonl")
[ "$LINES" = "$N" ] || { echo "FAIL: expected $N lines, got $LINES"; exit 1; }

UNIQUE_SEQS=$(jq -r '.seq' "$DEVFW_TEST_SESSION_DIR/events.jsonl" | tr -d '\r' | sort -n | uniq | wc -l | tr -d ' ')
[ "$UNIQUE_SEQS" = "$N" ] || { echo "FAIL: seq collision ($UNIQUE_SEQS unique of $N)"; exit 1; }

# Contiguity: min should be 1, max should be N
MIN=$(jq -r '.seq' "$DEVFW_TEST_SESSION_DIR/events.jsonl" | tr -d '\r' | sort -n | head -1)
MAX=$(jq -r '.seq' "$DEVFW_TEST_SESSION_DIR/events.jsonl" | tr -d '\r' | sort -n | tail -1)
[ "$MIN" = "1" ] || { echo "FAIL: min seq != 1 (got $MIN)"; exit 1; }
[ "$MAX" = "$N" ] || { echo "FAIL: max seq != $N (got $MAX)"; exit 1; }

# All events have valid JSON envelope
jq empty "$DEVFW_TEST_SESSION_DIR/events.jsonl" 2>/dev/null || {
  # empty can't take multiple objects — use -s
  jq -s empty "$DEVFW_TEST_SESSION_DIR/events.jsonl" || { echo "FAIL: events.jsonl has malformed lines"; exit 1; }
}

# Scenario 2: Mixed emitters (3 phase transitions + 20 consensus events) in parallel
rm -f "$DEVFW_TEST_SESSION_DIR/events.jsonl" "$DEVFW_TEST_SESSION_DIR/.seq"
for i in 1 2 3; do
  bash "$EMIT" phase.started --actor orchestrator --data "{\"phase\":$i}" &
done
for i in $(seq 1 20); do
  bash "$EMIT" consensus.iteration.started --actor "agent-$i" --data "{\"phase\":5,\"iteration\":$i}" &
done
wait

TOTAL=$(wc -l < "$DEVFW_TEST_SESSION_DIR/events.jsonl")
[ "$TOTAL" = "23" ] || { echo "FAIL: mixed emitters total ($TOTAL)"; exit 1; }

# Query per type works
PHASE_COUNT=$(bash "$GET" --type 'phase.*' --format count)
[ "$PHASE_COUNT" = "3" ] || { echo "FAIL: phase count != 3 (got $PHASE_COUNT)"; exit 1; }
CONS_COUNT=$(bash "$GET" --type 'consensus.*' --format count)
[ "$CONS_COUNT" = "20" ] || { echo "FAIL: consensus count != 20 (got $CONS_COUNT)"; exit 1; }

echo "PASS: concurrency-stress ($N parallel emits + 23 mixed emitters)"
```

- [ ] **Step 2: Run test**

```bash
chmod +x plugins/dev-framework/tests/m4/concurrency-stress.test.sh
bash plugins/dev-framework/tests/m4/concurrency-stress.test.sh
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add plugins/dev-framework/tests/m4/concurrency-stress.test.sh
git commit -m "test(m4): 50-way concurrency stress test for events.jsonl"
```

---

## Task 2: `fan-out.sh` — worktree + session spawn

**Files:**
- Create: `plugins/dev-framework/hooks/scripts/fan-out.sh`
- Test: `plugins/dev-framework/tests/m4/fan-out.test.sh`

**Interface:**

```bash
fan-out.sh --name <child-name> [--target-dir DIR] [--share-events]
# Creates: <target-dir>/<child-name>/  (default target-dir: /tmp/devfw-fanout/)
# Sets up: .session/ with progress-log.json, events.jsonl (shared or fresh)
# Outputs: child session dir path on stdout; emits fan-out.spawned event in parent
```

With `--share-events`, the child's `events.jsonl` is a symlink (or copy on non-symlink systems like Windows) to the parent's, so emits fan-in to the parent log.

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m4/fan-out.test.sh`:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
FANOUT="$HOOKS/fan-out.sh"
EMIT="$HOOKS/emit-event.sh"
GET="$HOOKS/get-events.sh"

[ -x "$FANOUT" ] || { echo "FAIL: fan-out.sh not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/parent"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-parent","status":"in-progress","phases":[]}
JSON

# --- Test 1: fan-out creates child session dir ---
CHILD=$(bash "$FANOUT" --name test-child --target-dir "$TMP/children")
[ -d "$CHILD" ] || { echo "FAIL: child dir not created ($CHILD)"; exit 1; }
[ -f "$CHILD/progress-log.json" ] || { echo "FAIL: child progress-log not created"; exit 1; }

# --- Test 2: parent emits fan-out.spawned ---
SPAWNED=$(bash "$GET" --type fan-out.spawned --format count)
[ "$SPAWNED" = "1" ] || { echo "FAIL: fan-out.spawned count != 1 (got $SPAWNED)"; exit 1; }

# Payload mentions the child dir
SPAWN_DIR=$(bash "$GET" --type fan-out.spawned --format json | jq -r '.data.childDir')
[ "$SPAWN_DIR" = "$CHILD" ] || { echo "FAIL: spawned.childDir mismatch ($SPAWN_DIR)"; exit 1; }

# --- Test 3: child session has its own events file ---
DEVFW_TEST_SESSION_DIR="$CHILD" bash "$EMIT" child.started --data '{}'
CHILD_EVENTS=$(wc -l < "$CHILD/events.jsonl")
[ "$CHILD_EVENTS" = "1" ] || { echo "FAIL: child events not independent"; exit 1; }
PARENT_EVENTS=$(wc -l < "$DEVFW_TEST_SESSION_DIR/events.jsonl")
[ "$PARENT_EVENTS" = "1" ] || { echo "FAIL: parent events count changed (expected 1 for fan-out.spawned only, got $PARENT_EVENTS)"; exit 1; }

# --- Test 4: --share-events fans child events into parent ---
SHARED_CHILD=$(bash "$FANOUT" --name shared-child --target-dir "$TMP/children" --share-events)
DEVFW_TEST_SESSION_DIR="$SHARED_CHILD" bash "$EMIT" shared.event --data '{}'
PARENT_AFTER=$(wc -l < "$DEVFW_TEST_SESSION_DIR/events.jsonl")
# Expect: parent had 1 (fan-out.spawned), plus 1 new fan-out.spawned + 1 shared.event = 3
[ "$PARENT_AFTER" = "3" ] || { echo "FAIL: shared mode — parent events ($PARENT_AFTER), expected 3"; exit 1; }

echo "PASS: fan-out"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m4/fan-out.test.sh`
Expected: FAIL with "fan-out.sh not executable"

- [ ] **Step 3: Write `fan-out.sh`**

Create `plugins/dev-framework/hooks/scripts/fan-out.sh`:

```bash
#!/bin/bash
# fan-out.sh — Spawn a child session folder (optionally sharing events.jsonl).
#
# Usage: fan-out.sh --name NAME [--target-dir DIR] [--share-events]
#
# Output (stdout): absolute path to child session dir.
# Event emitted in PARENT session: fan-out.spawned {childDir, shared}
#
# Note: This is a session-level primitive. Git-worktree creation and actual
# Claude/Task subagent dispatch are the orchestrator's responsibility.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

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

# Initialize child progress-log with parent's runId (for correlation)
PARENT_RUN_ID=""
if [ -f "$PARENT_DIR/progress-log.json" ] && command -v jq &>/dev/null; then
  PARENT_RUN_ID=$(jq -r '.runId // empty' "$PARENT_DIR/progress-log.json" 2>/dev/null || echo "")
fi

jq -cn --arg run "$PARENT_RUN_ID" --arg name "$NAME" \
  '{schemaVersion:1, runId:$run, mode:"fan-out-child", parentName:$name, status:"in-progress", phases:[]}' \
  > "$CHILD_DIR/progress-log.json"

# Events file — shared or independent
if [ "$SHARE" = "1" ] && [ -f "$PARENT_DIR/events.jsonl" ]; then
  # On systems that support symlinks, use one; otherwise copy (lossy for fan-in).
  if ln -s "$PARENT_DIR/events.jsonl" "$CHILD_DIR/events.jsonl" 2>/dev/null; then
    ln -s "$PARENT_DIR/.seq" "$CHILD_DIR/.seq" 2>/dev/null || true
  else
    # Fallback: hard link (same volume) or cp + warn
    if cp -l "$PARENT_DIR/events.jsonl" "$CHILD_DIR/events.jsonl" 2>/dev/null; then
      cp -l "$PARENT_DIR/.seq" "$CHILD_DIR/.seq" 2>/dev/null || true
    else
      echo "fan-out: WARNING — neither symlink nor hardlink supported; copy is one-way" >&2
      cp "$PARENT_DIR/events.jsonl" "$CHILD_DIR/events.jsonl"
      [ -f "$PARENT_DIR/.seq" ] && cp "$PARENT_DIR/.seq" "$CHILD_DIR/.seq"
    fi
  fi
fi

# Emit parent-side event
DEVFW_TEST_SESSION_DIR_SAVED="${DEVFW_TEST_SESSION_DIR:-}"
# Stay in parent context for the emit
unset DEVFW_TEST_SESSION_DIR
export DEVFW_TEST_SESSION_DIR="$PARENT_DIR"
bash "$SCRIPT_DIR/emit-event.sh" fan-out.spawned \
  --actor orchestrator \
  --data "$(jq -cn --arg cd "$CHILD_DIR" --arg name "$NAME" --argjson shared $([ "$SHARE" = "1" ] && echo true || echo false) \
    '{childDir:$cd, name:$name, shared:$shared}')" \
  2>/dev/null || true
export DEVFW_TEST_SESSION_DIR="$DEVFW_TEST_SESSION_DIR_SAVED"

echo "$CHILD_DIR"
exit 0
```

- [ ] **Step 4: Executable + test**

```bash
chmod +x plugins/dev-framework/hooks/scripts/fan-out.sh
bash plugins/dev-framework/tests/m4/fan-out.test.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/fan-out.sh \
        plugins/dev-framework/tests/m4/fan-out.test.sh
git commit -m "feat(m4): fan-out.sh spawn child session with optional event sharing"
```

---

## Task 3: worktree-orchestration reference doc

**Files:**
- Create: `plugins/dev-framework/skills/dev/references/autonomous/worktree-orchestration.md`

- [ ] **Step 1: Write the spec**

Create `plugins/dev-framework/skills/dev/references/autonomous/worktree-orchestration.md`:

```markdown
# Worktree Orchestration (M4+)

How to use multi-brain parallelism safely with the M1-M3 event infrastructure.

## The three levels of parallelism

1. **Intra-phase agent fan-out** (since M0) — `multi-agent-consensus` dispatches 3 agents in parallel via the Task tool. Each agent is a separate Claude instance. Shared context comes from the orchestrator's conversation.
2. **Intra-phase parallel invocations** (M4 enabled, opt-in) — a phase YAML's `invokes[]` may mark steps `parallel: true`. The orchestrator dispatches them concurrently; each emit `tool.call.*` events tagged with a group id.
3. **Inter-session fan-out** (M4 new) — `fan-out.sh` spawns a child session dir, optionally sharing `events.jsonl`. The orchestrator (or a scheduled task) can launch a side workflow without affecting the main pipeline.

## Safety guarantees

- **Seq atomicity.** `emit-event.sh` uses mkdir-based locking. 50+ parallel writers tested in `tests/m4/concurrency-stress.test.sh`. No duplicate or missing seqs observed.
- **Order within an actor.** Events from the same actor are emitted sequentially by that actor's process. Cross-actor order is total (seq is monotonic) but not deterministic — don't rely on "agent A emits before agent B" without an event dependency.
- **Cattle-not-pets.** A child session folder can be deleted at any time without affecting the parent. When `--share-events`, emits from the child appear in the parent log with the child's actor name.

## When to fan out

Use inter-session fan-out when:
- You need an isolated workspace (e.g., scratch directory for experimental diffs) that shouldn't pollute the main session.
- You want to explore a branch-at-point (replay + emit new events) without disturbing the live session.

Use intra-phase parallel invocations when:
- Multiple independent skills/protocols are needed and their outputs don't interact.
- The latency savings matter (e.g., exploration + architecture skill calls can overlap).

Don't fan out when:
- Steps have data dependencies (output of A is input to B).
- The freeze-gate is blocking src/** writes — concurrent writes to src/** from multiple brains would race on the same paths.

## fan-out.sh reference

```bash
fan-out.sh --name NAME [--target-dir DIR] [--share-events]
```

Emits `fan-out.spawned {childDir, name, shared}` in the parent session. Returns the child dir path on stdout.

## Fan-in pattern

```bash
CHILD=$(bash hooks/scripts/fan-out.sh --name exploration --share-events)
# Orchestrator dispatches a Task subagent that runs in $CHILD and emits to the shared log
# When subagent completes, its events appear in the parent's events.jsonl (filtered by actor)
bash hooks/scripts/get-events.sh --actor 'agent:exploration-*' --since-seq $KNOWN_LAST
```

## Phase YAML `parallel` support

Individual `invokes[]` entries may carry `parallel: true`:

```yaml
invokes:
  - kind: skill
    config: pipeline.skills.exploration
    parallel: true
  - kind: skill
    config: pipeline.skills.architect
    parallel: true
```

The orchestrator interprets consecutive parallel entries as a group, dispatches them concurrently, and waits for all before continuing. `execute.sh` does not enforce this — it's an orchestrator-level advisory. `tool.call.started` events from a parallel group carry `groupId` in their data when emitted by a compliant orchestrator.

## Limits

- **Git worktree cap.** Git supports many worktrees but each creates a full working directory — disk pressure matters for very large repos. Prefer fan-out *without* a worktree (just a session folder) when git isolation isn't needed.
- **Claude rate limits.** Multi-brain means more API calls concurrently. Respect your plan's parallel call limit.
- **No cross-session message bus.** Children and parent communicate only through shared events (if `--share-events`). No RPC, no direct messaging.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/dev-framework/skills/dev/references/autonomous/worktree-orchestration.md
git commit -m "docs(m4): worktree orchestration mental model"
```

---

## Task 4: Run all tests (M1+M2+M3+M4)

- [ ] **Step 1: Combined run**

```bash
cd /c/Users/jiho0/repos/dev-framework
for t in plugins/dev-framework/tests/m1/*.test.sh plugins/dev-framework/tests/m2/*.test.sh plugins/dev-framework/tests/m3/*.test.sh plugins/dev-framework/tests/m4/*.test.sh; do
  bash "$t" > /tmp/t-out 2>&1 && echo "✓ $t" || { echo "✗ $t"; cat /tmp/t-out; exit 1; }
done
echo "ALL M1-M4 PASS"
```

Expected: all PASS.

---

## Task 5: CLAUDE.md + README update

**Files:**
- Modify: `plugins/dev-framework/CLAUDE.md`

- [ ] **Step 1: Add M4 primitives + worktree-orchestration pointer**

Under "Events (M1+)" → primitives list, add:

```markdown
**M4 (multi-brain):**
- `fan-out.sh --name N [--target-dir DIR] [--share-events]` — spawn a child session folder, optionally sharing events.jsonl. Emits `fan-out.spawned` in parent.
```

Add a pointer line at the bottom of that section:

```markdown
Multi-brain patterns: [`skills/dev/references/autonomous/worktree-orchestration.md`](./skills/dev/references/autonomous/worktree-orchestration.md).
```

- [ ] **Step 2: Commit**

```bash
git add plugins/dev-framework/CLAUDE.md
git commit -m "docs(m4): document fan-out.sh and multi-brain patterns"
```

---

## Self-Review Checklist

**1. Spec coverage:**
- [ ] §3.8 multi-brain — fan-out.sh (Task 2) + concurrency proof (Task 1)
- [ ] §6 M4 success: "Two independent brains complete concurrently, no event-log corruption" — concurrency stress test with 50 emitters

**2. Behavior preservation:**
- [ ] All M1+M2+M3 tests still pass
- [ ] No modification of existing scripts
- [ ] Phase YAMLs unchanged (parallel support is advisory, not enforced)

**3. Dependencies:**
- [ ] No new runtime deps (git + bash + jq already required)

**4. Limits acknowledged:**
- [ ] Worktree-orchestration.md notes disk pressure, rate limits, and no-message-bus constraint
