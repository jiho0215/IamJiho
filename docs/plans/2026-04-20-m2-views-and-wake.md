# M2 — Views as Projections + wake() + replay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce reducer scripts that regenerate `views/progress-log.json`, `views/decision-log.json`, `views/pipeline-issues.json` from `events.jsonl`. Add `wake.sh` for stateless restart (returns `{currentPhase, lastSeq, pendingAction, minimumContext}`) and `replay.sh` for seq-level rewind into an alternate session directory. Existing state files remain authoritative during M2 — views are a parallel artifact for validation.

**Architecture:** Events are the source of truth; views are pure functions over events. Reducers share an `_reducers.sh` helper library. `wake.sh` is a special reducer that returns a compact readiness summary rather than a full view. `replay.sh` copies events up to seq N into an alt session dir, then invokes the reducer chain there.

**Semantic equivalence (not byte-equality):** Views are validated to contain the same *information* as the procedurally-written state files (phase entries, decisions, issues), not the same bytes. Fields that aren't captured in events (e.g., `configSnapshot`) are populated from the hand-written files via a one-time bootstrap at M3 switchover.

**Tech Stack:** Bash, jq, standard POSIX tools. Same stack as M1.

**Reference:** [docs/specs/2026-04-20-managed-agents-evolution.md](../specs/2026-04-20-managed-agents-evolution.md) §3.3, §3.5, §6 (M2 row).

---

## File Structure

**Create:**
- `plugins/dev-framework/hooks/scripts/_reducers.sh` — sourced library of reducer helpers
- `plugins/dev-framework/hooks/scripts/reduce-progress-log.sh` — events → views/progress-log.json
- `plugins/dev-framework/hooks/scripts/reduce-decision-log.sh` — events → views/decision-log.json
- `plugins/dev-framework/hooks/scripts/reduce-pipeline-issues.sh` — events → views/pipeline-issues.json
- `plugins/dev-framework/hooks/scripts/regenerate-views.sh` — orchestrator calling all reducers
- `plugins/dev-framework/hooks/scripts/wake.sh` — stateless restart primitive
- `plugins/dev-framework/hooks/scripts/replay.sh` — copies events up to seq N into alt dir and regenerates views there
- `plugins/dev-framework/skills/dev/references/autonomous/views-spec.md` — view schema + reducer rules
- `plugins/dev-framework/tests/m2/*.test.sh` — one per reducer + wake + replay + semantic-equivalence

**Modify:**
- `plugins/dev-framework/CLAUDE.md` — document `views/`, `wake.sh`, `replay.sh`
- `plugins/dev-framework/skills/dev/SKILL.md` — mention views in Session State section (no behavior change)

---

## Task 1: `_reducers.sh` — shared reducer helpers

**Files:**
- Create: `plugins/dev-framework/hooks/scripts/_reducers.sh`
- Test: `plugins/dev-framework/tests/m2/reducers-lib.test.sh`

**Rationale:** Multiple reducers need common operations (iterate events, build ISO timestamps, safely mkdir views/). Extract once.

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m2/reducers-lib.test.sh`:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../../hooks/scripts/_reducers.sh"

[ -f "$LIB" ] || { echo "FAIL: _reducers.sh not found"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

# ensure_views_dir creates views/ under session
ensure_views_dir
[ -d "$DEVFW_TEST_SESSION_DIR/views" ] || { echo "FAIL: views dir not created"; exit 1; }

# events_file returns path to events.jsonl
EF=$(events_file)
[ "$EF" = "$DEVFW_TEST_SESSION_DIR/events.jsonl" ] || { echo "FAIL: events_file path wrong ($EF)"; exit 1; }

# read_events with no file returns empty
OUT=$(read_events)
[ -z "$OUT" ] || { echo "FAIL: read_events with missing file not empty"; exit 1; }

# Seed events, check read_events returns them
echo '{"seq":1,"at":"2026-04-20T10:00:00Z","type":"test","data":{}}' > "$EF"
OUT=$(read_events)
[ -n "$OUT" ] || { echo "FAIL: read_events with data empty"; exit 1; }

echo "PASS: reducers-lib"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m2/reducers-lib.test.sh`
Expected: FAIL with "_reducers.sh not found"

- [ ] **Step 3: Write `_reducers.sh`**

Create `plugins/dev-framework/hooks/scripts/_reducers.sh`:

```bash
#!/bin/bash
# _reducers.sh — Shared helpers for view reducer scripts.
# Source with: . "$(dirname "${BASH_SOURCE[0]}")/_reducers.sh"
# Requires: _session-lib.sh already sourced (for resolve_session_dir).

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

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

# Stream events as raw JSONL. No file → empty output (exit 0).
read_events() {
  local ef
  ef=$(events_file)
  [ -f "$ef" ] || return 0
  cat "$ef"
}

# Atomic write: temp file → rename. Arg: target path. Reads content from stdin.
atomic_write() {
  local target="$1" tmp="$1.tmp.$$"
  cat > "$tmp"
  if ! mv "$tmp" "$target" 2>/dev/null; then
    sleep 1
    mv "$tmp" "$target"
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugins/dev-framework/tests/m2/reducers-lib.test.sh`
Expected: `PASS: reducers-lib`

- [ ] **Step 5: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/_reducers.sh \
        plugins/dev-framework/tests/m2/reducers-lib.test.sh
git commit -m "feat(m2): add _reducers.sh shared helpers"
```

---

## Task 2: `reduce-progress-log.sh` — events → progress-log view

**Files:**
- Create: `plugins/dev-framework/hooks/scripts/reduce-progress-log.sh`
- Test: `plugins/dev-framework/tests/m2/reduce-progress-log.test.sh`

**View schema** (subset of the full progress-log.json; fields that can be derived from events):

```json
{
  "schemaVersion": 1,
  "source": "events-reducer",
  "regeneratedAt": "2026-04-20T...",
  "runId": "run-...",
  "mode": "full-cycle",
  "featureSlug": "...",
  "ticket": "...",
  "status": "in-progress|completed|interrupted|failed",
  "currentPhase": 3,
  "interruptedAt": null,
  "completedAt": null,
  "phases": [
    { "phase": 1, "status": "completed", "startedAt": "...", "completedAt": "...", "durationSeconds": N }
  ],
  "summary": {
    "gateApprovals": { "gate1": "interactive|autonomous|null", "gate2": "interactive|autonomous|null" },
    "bypassCount": 0,
    "consensusRounds": { "phase5": 3, "phase6": 2 }
  }
}
```

**Reducer rules:**

- `status`: derived from latest `session.*` event (`session.started` → in-progress, `session.interrupted` → interrupted, `session.completed` → completed)
- `currentPhase`: highest-seen `phase.started` phase number
- `phases[]`: each `phase.started` creates an entry with `status:"in-progress"`; matching `phase.completed` updates `status:"completed"` + `completedAt`
- `summary.gateApprovals.gateN`: populated from `gate.approved {gate:N}`
- `summary.bypassCount`: count of `bypass.created`
- `summary.consensusRounds.phaseN`: count of `consensus.iteration.started` events per phase

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m2/reduce-progress-log.test.sh`:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
REDUCER="$HOOKS/reduce-progress-log.sh"

[ -x "$REDUCER" ] || { echo "FAIL: reducer not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-abc","status":"in-progress"}
JSON

# Seed events: phase1 complete, phase2 complete, phase3 in-progress, 1 bypass, 2 consensus iterations in phase3
bash "$EMIT" session.started --actor orchestrator --data '{"mode":"full-cycle","featureSlug":"test-feat"}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":3}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":3,"iteration":1}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":3,"iteration":2}'
bash "$EMIT" bypass.created --actor orchestrator --data '{"feature":"test-feat","reason":"emergency","userMessage":"bypass"}'

bash "$REDUCER"
VIEW="$DEVFW_TEST_SESSION_DIR/views/progress-log.json"
[ -f "$VIEW" ] || { echo "FAIL: view not created"; exit 1; }
jq empty "$VIEW" || { echo "FAIL: view invalid JSON"; exit 1; }

# Assertions
[ "$(jq -r '.status' "$VIEW")" = "in-progress" ] || { echo "FAIL: status"; exit 1; }
[ "$(jq -r '.mode' "$VIEW")" = "full-cycle" ] || { echo "FAIL: mode"; exit 1; }
[ "$(jq -r '.featureSlug' "$VIEW")" = "test-feat" ] || { echo "FAIL: featureSlug"; exit 1; }
[ "$(jq -r '.runId' "$VIEW")" = "run-abc" ] || { echo "FAIL: runId"; exit 1; }
[ "$(jq -r '.currentPhase' "$VIEW")" = "3" ] || { echo "FAIL: currentPhase"; exit 1; }
[ "$(jq -r '.phases | length' "$VIEW")" = "3" ] || { echo "FAIL: phases length"; exit 1; }
[ "$(jq -r '.phases[0].status' "$VIEW")" = "completed" ] || { echo "FAIL: phase1 status"; exit 1; }
[ "$(jq -r '.phases[2].status' "$VIEW")" = "in-progress" ] || { echo "FAIL: phase3 status"; exit 1; }
[ "$(jq -r '.summary.bypassCount' "$VIEW")" = "1" ] || { echo "FAIL: bypassCount"; exit 1; }
[ "$(jq -r '.summary.consensusRounds.phase3' "$VIEW")" = "2" ] || { echo "FAIL: consensusRounds.phase3"; exit 1; }

# After session.interrupted, status should flip to interrupted
bash "$EMIT" session.interrupted --actor "hook:sessionend" --data '{"interruptedAt":"2026-04-20T12:00:00Z","currentPhase":3}'
bash "$REDUCER"
[ "$(jq -r '.status' "$VIEW")" = "interrupted" ] || { echo "FAIL: status after interrupt"; exit 1; }
[ "$(jq -r '.interruptedAt' "$VIEW")" = "2026-04-20T12:00:00Z" ] || { echo "FAIL: interruptedAt"; exit 1; }

# After session.completed, status → completed
bash "$EMIT" session.completed --actor orchestrator --data '{"totalMinutes":45}'
bash "$REDUCER"
[ "$(jq -r '.status' "$VIEW")" = "completed" ] || { echo "FAIL: status after complete"; exit 1; }

echo "PASS: reduce-progress-log"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m2/reduce-progress-log.test.sh`
Expected: FAIL with "reducer not executable"

- [ ] **Step 3: Write `reduce-progress-log.sh`**

Create `plugins/dev-framework/hooks/scripts/reduce-progress-log.sh`:

```bash
#!/bin/bash
# reduce-progress-log.sh — Regenerate views/progress-log.json from events.jsonl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"
# shellcheck source=./_reducers.sh
. "$SCRIPT_DIR/_reducers.sh"

command -v jq &>/dev/null || { echo "reduce-progress-log: ERROR — jq required" >&2; exit 1; }

EVENTS=$(events_file)
if [ ! -f "$EVENTS" ]; then
  exit 0
fi

ensure_views_dir
VIEW="$(views_dir)/progress-log.json"

# Single jq program performs the reduction. See views-spec.md for schema.
jq -s --arg regen "$(iso_utc)" '
  # Extract latest value of a field from the latest event matching type predicate.
  def pick_latest_data(type_prefix; field):
    [ .[] | select(.type | startswith(type_prefix)) | .data[field] // empty ]
    | last // null;

  # Build phase entries from phase.started/phase.completed pairs.
  def build_phases:
    [ .[] | select(.type | startswith("phase.")) ] as $pevs
    | ($pevs | map(.data.phase) | unique | sort) as $nums
    | [ $nums[] as $n
        | ($pevs | map(select(.data.phase == $n))) as $evs
        | ($evs | map(select(.type == "phase.started")) | first) as $start
        | ($evs | map(select(.type == "phase.completed")) | first) as $complete
        | ($evs | map(select(.type == "phase.failed"))    | first) as $failed
        | {
            phase: $n,
            status: (
              if $failed then "failed"
              elif $complete then "completed"
              elif $start then "in-progress"
              else "unknown"
              end
            ),
            startedAt: ($start.at // null),
            completedAt: ($complete.at // $failed.at // null)
          }
      ];

  # Derive overall status from session.* events (latest wins).
  def session_status:
    [ .[] | select(.type == "session.started"     or
                   .type == "session.interrupted" or
                   .type == "session.completed"   or
                   .type == "session.resumed") ]
    | last as $latest
    | if $latest == null then "unknown"
      elif $latest.type == "session.started"     then "in-progress"
      elif $latest.type == "session.interrupted" then "interrupted"
      elif $latest.type == "session.completed"   then "completed"
      else "in-progress"
      end;

  {
    schemaVersion: 1,
    source: "events-reducer",
    regeneratedAt: $regen,
    runId: (
      [ .[] | .runId | select(. != null and . != "") ] | first // null
    ),
    mode:        (pick_latest_data("session.started"; "mode")),
    featureSlug: (pick_latest_data("session.started"; "featureSlug")),
    ticket:      (pick_latest_data("session.started"; "ticket")),
    status:      session_status,
    currentPhase:
      ( [ .[] | select(.type == "phase.started") | .data.phase ] | max // 0 ),
    interruptedAt:
      ( [ .[] | select(.type == "session.interrupted") | .data.interruptedAt ] | last // null ),
    completedAt:
      ( [ .[] | select(.type == "session.completed") | .at ] | last // null ),
    phases: build_phases,
    summary: {
      gateApprovals: {
        gate1: ( [ .[] | select(.type == "gate.approved" and .data.gate == 1) | .data.approvalMode ] | last // null ),
        gate2: ( [ .[] | select(.type == "gate.approved" and .data.gate == 2) | .data.approvalMode ] | last // null )
      },
      bypassCount: ( [ .[] | select(.type == "bypass.created") ] | length ),
      consensusRounds: (
        [ .[] | select(.type == "consensus.iteration.started") | .data.phase ]
        | group_by(.)
        | map({ key: "phase\(.[0])", value: length })
        | from_entries
      )
    }
  }
' "$EVENTS" | atomic_write "$VIEW"

exit 0
```

- [ ] **Step 4: Make executable, run test**

Run:
```bash
chmod +x plugins/dev-framework/hooks/scripts/reduce-progress-log.sh
bash plugins/dev-framework/tests/m2/reduce-progress-log.test.sh
```

Expected: `PASS: reduce-progress-log`

- [ ] **Step 5: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/reduce-progress-log.sh \
        plugins/dev-framework/tests/m2/reduce-progress-log.test.sh
git commit -m "feat(m2): reduce-progress-log.sh events → view"
```

---

## Task 3: `reduce-decision-log.sh` — events → decision-log view

**Files:**
- Create: `plugins/dev-framework/hooks/scripts/reduce-decision-log.sh`
- Test: `plugins/dev-framework/tests/m2/reduce-decision-log.test.sh`

**View schema:**

```json
{
  "schemaVersion": 1,
  "source": "events-reducer",
  "regeneratedAt": "...",
  "decisions": [
    { "id": "D001", "seq": 5, "at": "...", "phase": 3,
      "category": "gate-1", "decision": "...", "reason": "...", "confidence": "..." }
  ]
}
```

**Reducer rule:** every `decision.recorded` event → one row. `gate.approved`, `gate.rejected`, `bypass.created`, `phase.failed` also synthesize decision entries with derived categories (see views-spec.md).

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m2/reduce-decision-log.test.sh`:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
REDUCER="$HOOKS/reduce-decision-log.sh"

[ -x "$REDUCER" ] || { echo "FAIL: reducer not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

bash "$EMIT" decision.recorded --actor orchestrator \
  --data '{"id":"D001","phase":1,"category":"plan","decision":"use OAuth","reason":"industry standard","confidence":"high"}'
bash "$EMIT" gate.approved --actor orchestrator --data '{"gate":1,"approvalMode":"interactive","approvedBy":"test"}'
bash "$EMIT" bypass.created --actor orchestrator --data '{"feature":"f","reason":"emergency","userMessage":"m"}'
bash "$EMIT" phase.failed --actor orchestrator --data '{"phase":4,"error":"test failed"}'

bash "$REDUCER"
VIEW="$DEVFW_TEST_SESSION_DIR/views/decision-log.json"
[ -f "$VIEW" ] || { echo "FAIL: view not created"; exit 1; }

# Should have 4 decisions: 1 explicit + 3 derived
COUNT=$(jq -r '.decisions | length' "$VIEW")
[ "$COUNT" = "4" ] || { echo "FAIL: decisions count != 4 (got $COUNT)"; exit 1; }

# First decision should be the explicit one
[ "$(jq -r '.decisions[0].id' "$VIEW")" = "D001" ] || { echo "FAIL: id D001"; exit 1; }
[ "$(jq -r '.decisions[0].category' "$VIEW")" = "plan" ] || { echo "FAIL: category plan"; exit 1; }

# Derived: gate-1
HAS_G1=$(jq -r '.decisions[] | select(.category == "gate-1") | .category' "$VIEW")
[ "$HAS_G1" = "gate-1" ] || { echo "FAIL: gate-1 derived"; exit 1; }

# Derived: bypass
HAS_BP=$(jq -r '.decisions[] | select(.category == "bypass") | .category' "$VIEW")
[ "$HAS_BP" = "bypass" ] || { echo "FAIL: bypass derived"; exit 1; }

# Derived: phase-failure
HAS_PF=$(jq -r '.decisions[] | select(.category == "phase-failure") | .category' "$VIEW")
[ "$HAS_PF" = "phase-failure" ] || { echo "FAIL: phase-failure derived"; exit 1; }

echo "PASS: reduce-decision-log"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m2/reduce-decision-log.test.sh`
Expected: FAIL with "reducer not executable"

- [ ] **Step 3: Write `reduce-decision-log.sh`**

Create `plugins/dev-framework/hooks/scripts/reduce-decision-log.sh`:

```bash
#!/bin/bash
# reduce-decision-log.sh — Regenerate views/decision-log.json from events.jsonl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"
# shellcheck source=./_reducers.sh
. "$SCRIPT_DIR/_reducers.sh"

command -v jq &>/dev/null || { echo "reduce-decision-log: ERROR — jq required" >&2; exit 1; }

EVENTS=$(events_file)
[ -f "$EVENTS" ] || exit 0

ensure_views_dir
VIEW="$(views_dir)/decision-log.json"

jq -s --arg regen "$(iso_utc)" '
  # Build decisions from decision.recorded + derived decisions from gates/bypass/failure.
  def explicit_decisions:
    [ .[] | select(.type == "decision.recorded") |
      { id: .data.id, seq: .seq, at: .at, phase: .data.phase,
        category: .data.category, decision: .data.decision,
        reason: .data.reason, confidence: .data.confidence,
        source: "explicit" } ];

  def gate_decisions:
    [ .[] | select(.type == "gate.approved") |
      { id: "GATE\(.data.gate)-APPROVED-\(.seq)", seq: .seq, at: .at, phase: null,
        category: "gate-\(.data.gate)", decision: "gate \(.data.gate) approved",
        reason: "approvalMode=\(.data.approvalMode // "?") by=\(.data.approvedBy // "?")",
        confidence: "high", source: "derived" } ];

  def bypass_decisions:
    [ .[] | select(.type == "bypass.created") |
      { id: "BYPASS-\(.seq)", seq: .seq, at: .at, phase: null,
        category: "bypass", decision: "freeze-gate bypass",
        reason: (.data.reason // ""),
        confidence: "high", source: "derived" } ];

  def failure_decisions:
    [ .[] | select(.type == "phase.failed") |
      { id: "FAIL-P\(.data.phase)-\(.seq)", seq: .seq, at: .at, phase: .data.phase,
        category: "phase-failure", decision: "phase \(.data.phase) failed",
        reason: (.data.error // ""),
        confidence: "high", source: "derived" } ];

  {
    schemaVersion: 1,
    source: "events-reducer",
    regeneratedAt: $regen,
    decisions:
      (explicit_decisions + gate_decisions + bypass_decisions + failure_decisions)
      | sort_by(.seq)
  }
' "$EVENTS" | atomic_write "$VIEW"

exit 0
```

- [ ] **Step 4: Executable + test**

```bash
chmod +x plugins/dev-framework/hooks/scripts/reduce-decision-log.sh
bash plugins/dev-framework/tests/m2/reduce-decision-log.test.sh
```

- [ ] **Step 5: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/reduce-decision-log.sh \
        plugins/dev-framework/tests/m2/reduce-decision-log.test.sh
git commit -m "feat(m2): reduce-decision-log.sh events → view"
```

---

## Task 4: `reduce-pipeline-issues.sh` — events → pipeline-issues view

**Files:**
- Create: `plugins/dev-framework/hooks/scripts/reduce-pipeline-issues.sh`
- Test: `plugins/dev-framework/tests/m2/reduce-pipeline-issues.test.sh`

**View schema:**

```json
{
  "schemaVersion": 1,
  "source": "events-reducer",
  "regeneratedAt": "...",
  "runs": [
    {
      "runId": "run-abc",
      "phases": {
        "5": {
          "iterations": [
            { "iteration": 1, "issuesFound": 3, "fixesApplied": 3 },
            { "iteration": 2, "issuesFound": 0, "fixesApplied": 0 }
          ],
          "converged": true,
          "remainingIssues": 0
        }
      }
    }
  ]
}
```

**Rule:** group `consensus.*` events by `runId` → `phase` → `iteration`; count `consensus.issues.found` and `consensus.fix.applied` per iteration; populate `converged` / `remainingIssues` from `consensus.converged` / `consensus.forced_stop`.

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m2/reduce-pipeline-issues.test.sh`:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
REDUCER="$HOOKS/reduce-pipeline-issues.sh"

[ -x "$REDUCER" ] || { echo "FAIL: reducer not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-aaa","status":"in-progress"}
JSON

bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":5,"iteration":1}'
bash "$EMIT" consensus.issues.found      --actor "agent:x" --data '{"phase":5,"iteration":1,"issues":[{"s":"H"},{"s":"M"},{"s":"L"}]}'
bash "$EMIT" consensus.fix.applied       --actor orchestrator --data '{"phase":5,"iteration":1,"issueId":"I1"}'
bash "$EMIT" consensus.fix.applied       --actor orchestrator --data '{"phase":5,"iteration":1,"issueId":"I2"}'
bash "$EMIT" consensus.fix.applied       --actor orchestrator --data '{"phase":5,"iteration":1,"issueId":"I3"}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":5,"iteration":2}'
bash "$EMIT" consensus.converged         --actor orchestrator --data '{"phase":5,"iterations":2,"issuesFixed":3}'

bash "$REDUCER"
VIEW="$DEVFW_TEST_SESSION_DIR/views/pipeline-issues.json"
[ -f "$VIEW" ] || { echo "FAIL: view not created"; exit 1; }

# Exactly 1 run, 1 phase (5), 2 iterations
[ "$(jq -r '.runs | length' "$VIEW")" = "1" ] || { echo "FAIL: runs length"; exit 1; }
[ "$(jq -r '.runs[0].runId' "$VIEW")" = "run-aaa" ] || { echo "FAIL: runId"; exit 1; }
[ "$(jq -r '.runs[0].phases."5".iterations | length' "$VIEW")" = "2" ] || { echo "FAIL: iterations length"; exit 1; }
[ "$(jq -r '.runs[0].phases."5".iterations[0].issuesFound' "$VIEW")" = "3" ] || { echo "FAIL: issuesFound"; exit 1; }
[ "$(jq -r '.runs[0].phases."5".iterations[0].fixesApplied' "$VIEW")" = "3" ] || { echo "FAIL: fixesApplied"; exit 1; }
[ "$(jq -r '.runs[0].phases."5".converged' "$VIEW")" = "true" ] || { echo "FAIL: converged"; exit 1; }
[ "$(jq -r '.runs[0].phases."5".remainingIssues' "$VIEW")" = "0" ] || { echo "FAIL: remainingIssues"; exit 1; }

echo "PASS: reduce-pipeline-issues"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m2/reduce-pipeline-issues.test.sh`
Expected: FAIL with "reducer not executable"

- [ ] **Step 3: Write `reduce-pipeline-issues.sh`**

Create `plugins/dev-framework/hooks/scripts/reduce-pipeline-issues.sh`:

```bash
#!/bin/bash
# reduce-pipeline-issues.sh — Regenerate views/pipeline-issues.json from events.jsonl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"
# shellcheck source=./_reducers.sh
. "$SCRIPT_DIR/_reducers.sh"

command -v jq &>/dev/null || { echo "reduce-pipeline-issues: ERROR — jq required" >&2; exit 1; }

EVENTS=$(events_file)
[ -f "$EVENTS" ] || exit 0

ensure_views_dir
VIEW="$(views_dir)/pipeline-issues.json"

jq -s --arg regen "$(iso_utc)" '
  # Group consensus.* events by runId -> phase -> iteration.
  def build_phase_entry(phase_num; phase_events):
    (phase_events | [.[] | select(.type == "consensus.iteration.started") | .data.iteration] | unique | sort) as $iters
    | (phase_events | [.[] | select(.type == "consensus.converged")] | first) as $conv
    | (phase_events | [.[] | select(.type == "consensus.forced_stop")] | first) as $stop
    | {
        iterations: [
          $iters[] as $i
          | ( phase_events | [.[] | select(.data.iteration == $i)] ) as $iev
          | {
              iteration: $i,
              issuesFound: (
                [ $iev[] | select(.type == "consensus.issues.found") | (.data.issues // []) | length ]
                | add // 0
              ),
              fixesApplied: (
                [ $iev[] | select(.type == "consensus.fix.applied") ] | length
              )
            }
        ],
        converged: ($conv != null),
        remainingIssues: ($stop.data.remainingIssues // 0)
      };

  ([.[] | select(.type | startswith("consensus."))]
   | group_by(.runId)) as $runs_grouped
  | {
      schemaVersion: 1,
      source: "events-reducer",
      regeneratedAt: $regen,
      runs: [
        $runs_grouped[] as $r
        | ($r | group_by(.data.phase)) as $phase_groups
        | {
            runId: ($r[0].runId // ""),
            phases: (
              [ $phase_groups[] as $pg
                | { key: "\($pg[0].data.phase)", value: build_phase_entry($pg[0].data.phase; $pg) }
              ] | from_entries
            )
          }
      ]
    }
' "$EVENTS" | atomic_write "$VIEW"

exit 0
```

- [ ] **Step 4: Executable + test**

```bash
chmod +x plugins/dev-framework/hooks/scripts/reduce-pipeline-issues.sh
bash plugins/dev-framework/tests/m2/reduce-pipeline-issues.test.sh
```

- [ ] **Step 5: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/reduce-pipeline-issues.sh \
        plugins/dev-framework/tests/m2/reduce-pipeline-issues.test.sh
git commit -m "feat(m2): reduce-pipeline-issues.sh events → view"
```

---

## Task 5: `regenerate-views.sh` — master orchestrator

**Files:**
- Create: `plugins/dev-framework/hooks/scripts/regenerate-views.sh`
- Test: `plugins/dev-framework/tests/m2/regenerate-views.test.sh`

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m2/regenerate-views.test.sh`:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
REGEN="$HOOKS/regenerate-views.sh"

[ -x "$REGEN" ] || { echo "FAIL: regenerate-views not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-xyz","status":"in-progress"}
JSON

bash "$EMIT" session.started --actor orchestrator --data '{"mode":"full-cycle","featureSlug":"x"}'
bash "$EMIT" decision.recorded --actor orchestrator --data '{"id":"D001","phase":1,"category":"plan","decision":"a","reason":"b","confidence":"high"}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":5,"iteration":1}'

bash "$REGEN"

VIEWS="$DEVFW_TEST_SESSION_DIR/views"
[ -f "$VIEWS/progress-log.json" ] || { echo "FAIL: progress-log not generated"; exit 1; }
[ -f "$VIEWS/decision-log.json" ] || { echo "FAIL: decision-log not generated"; exit 1; }
[ -f "$VIEWS/pipeline-issues.json" ] || { echo "FAIL: pipeline-issues not generated"; exit 1; }

for f in "$VIEWS"/*.json; do
  jq empty "$f" || { echo "FAIL: $f invalid JSON"; exit 1; }
done

echo "PASS: regenerate-views"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m2/regenerate-views.test.sh`
Expected: FAIL

- [ ] **Step 3: Write `regenerate-views.sh`**

```bash
#!/bin/bash
# regenerate-views.sh — Regenerate all views/ files from events.jsonl.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/reduce-progress-log.sh"
bash "$SCRIPT_DIR/reduce-decision-log.sh"
bash "$SCRIPT_DIR/reduce-pipeline-issues.sh"

exit 0
```

- [ ] **Step 4: Executable + test + commit**

```bash
chmod +x plugins/dev-framework/hooks/scripts/regenerate-views.sh
bash plugins/dev-framework/tests/m2/regenerate-views.test.sh
git add plugins/dev-framework/hooks/scripts/regenerate-views.sh \
        plugins/dev-framework/tests/m2/regenerate-views.test.sh
git commit -m "feat(m2): regenerate-views.sh master orchestrator"
```

---

## Task 6: `wake.sh` — stateless restart primitive

**Files:**
- Create: `plugins/dev-framework/hooks/scripts/wake.sh`
- Test: `plugins/dev-framework/tests/m2/wake.test.sh`

**Output schema** (stdout JSON, single object):

```json
{
  "sessionDir": "/path/to/session",
  "lastSeq": 47,
  "eventCount": 47,
  "runId": "run-abc",
  "mode": "full-cycle",
  "featureSlug": "x",
  "currentPhase": 3,
  "status": "in-progress",
  "pendingAction": "phase.3.completion | gate.1.pending | phase.5.iteration.2.active | session.ready-to-resume | session.complete",
  "minimumContext": {
    "freezeDocPath": "docs/specs/x-freeze.md",
    "tddPlanPath": "/path/tdd-plan.md",
    "planDoc": "docs/plans/x.md"
  }
}
```

**`pendingAction` decision tree:**

1. If latest event is `session.completed` → `session.complete`
2. If latest event is `session.interrupted` → `session.ready-to-resume`
3. Find latest `consensus.iteration.started` without a later `consensus.converged` / `consensus.forced_stop` → `phase.{N}.iteration.{M}.active`
4. Find latest `phase.started` without matching `phase.completed` → `phase.{N}.completion`
5. If GATE 1 pending (phase 3 complete but no `gate.approved {gate:1}`) → `gate.1.pending`
6. Otherwise → `phase.{N}.ready` (N = currentPhase + 1)

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m2/wake.test.sh`:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
WAKE="$HOOKS/wake.sh"

[ -x "$WAKE" ] || { echo "FAIL: wake not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"

# Test 1: no session → returns null-ish state
mkdir -p "$DEVFW_TEST_SESSION_DIR"
OUT=$(bash "$WAKE")
echo "$OUT" | jq empty || { echo "FAIL: wake output invalid JSON"; exit 1; }
[ "$(echo "$OUT" | jq -r '.lastSeq')" = "0" ] || { echo "FAIL: empty session lastSeq != 0"; exit 1; }

# Test 2: session started, phase 1 in progress → pendingAction phase.1.completion
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-w1","status":"in-progress"}
JSON
bash "$EMIT" session.started --actor orchestrator --data '{"mode":"full-cycle","featureSlug":"f1"}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":1}'
OUT=$(bash "$WAKE")
[ "$(echo "$OUT" | jq -r '.currentPhase')" = "1" ] || { echo "FAIL: currentPhase != 1"; exit 1; }
[ "$(echo "$OUT" | jq -r '.pendingAction')" = "phase.1.completion" ] || { echo "FAIL: pendingAction phase 1"; exit 1; }

# Test 3: phase 3 complete, no GATE 1 approval → pendingAction gate.1.pending
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":3}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":3}'
OUT=$(bash "$WAKE")
[ "$(echo "$OUT" | jq -r '.pendingAction')" = "gate.1.pending" ] || { echo "FAIL: gate.1.pending (got $(echo "$OUT" | jq -r '.pendingAction'))"; exit 1; }

# Test 4: after gate.approved → phase.4.ready
bash "$EMIT" gate.approved --actor orchestrator --data '{"gate":1,"approvalMode":"interactive","approvedBy":"test"}'
OUT=$(bash "$WAKE")
[ "$(echo "$OUT" | jq -r '.pendingAction')" = "phase.4.ready" ] || { echo "FAIL: phase.4.ready (got $(echo "$OUT" | jq -r '.pendingAction'))"; exit 1; }

# Test 5: active consensus iteration
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":5}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":5,"iteration":3}'
OUT=$(bash "$WAKE")
[ "$(echo "$OUT" | jq -r '.pendingAction')" = "phase.5.iteration.3.active" ] || { echo "FAIL: iteration active (got $(echo "$OUT" | jq -r '.pendingAction'))"; exit 1; }

# Test 6: after session.interrupted → ready-to-resume
bash "$EMIT" session.interrupted --actor "hook:sessionend" --data '{"interruptedAt":"2026-04-20T12:00:00Z","currentPhase":5}'
OUT=$(bash "$WAKE")
[ "$(echo "$OUT" | jq -r '.pendingAction')" = "session.ready-to-resume" ] || { echo "FAIL: resume (got $(echo "$OUT" | jq -r '.pendingAction'))"; exit 1; }

# Test 7: after session.completed → complete
bash "$EMIT" session.completed --actor orchestrator --data '{"totalMinutes":60}'
OUT=$(bash "$WAKE")
[ "$(echo "$OUT" | jq -r '.pendingAction')" = "session.complete" ] || { echo "FAIL: complete"; exit 1; }

echo "PASS: wake"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m2/wake.test.sh`
Expected: FAIL

- [ ] **Step 3: Write `wake.sh`**

```bash
#!/bin/bash
# wake.sh — Stateless restart primitive. Returns compact JSON with session state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"
# shellcheck source=./_reducers.sh
. "$SCRIPT_DIR/_reducers.sh"

command -v jq &>/dev/null || { echo "wake: ERROR — jq required" >&2; exit 1; }

SESSION_DIR=$(resolve_session_dir)
EVENTS=$(events_file)
PROGRESS_LOG="$SESSION_DIR/progress-log.json"

# Pull freezeDocPath from progress-log if present (events don't carry it yet)
FREEZE_DOC_PATH=""
if [ -f "$PROGRESS_LOG" ] && jq empty "$PROGRESS_LOG" 2>/dev/null; then
  FREEZE_DOC_PATH=$(jq -r '.freezeDocPath // ""' "$PROGRESS_LOG" 2>/dev/null)
fi

if [ ! -f "$EVENTS" ]; then
  jq -cn \
    --arg sd "$SESSION_DIR" \
    --arg fd "$FREEZE_DOC_PATH" \
    '{
      sessionDir: $sd, lastSeq: 0, eventCount: 0,
      runId: null, mode: null, featureSlug: null, ticket: null,
      currentPhase: 0, status: "no-session",
      pendingAction: "session.not-started",
      minimumContext: { freezeDocPath: $fd }
    }'
  exit 0
fi

jq -s --arg sd "$SESSION_DIR" --arg fd "$FREEZE_DOC_PATH" '
  # Latest event of a given type
  def latest(t): [ .[] | select(.type == t) ] | last;
  # Latest event whose type starts with prefix
  def latest_prefix(p): [ .[] | select(.type | startswith(p)) ] | last;

  (latest("session.started"))     as $started
  | (latest("session.interrupted")) as $interrupted
  | (latest("session.completed"))   as $completed
  | (latest("phase.started"))       as $last_ps
  | (latest("phase.completed"))     as $last_pc
  | ([ .[] | select(.type == "consensus.iteration.started") ] | last) as $last_iter
  | ([ .[] | select(.type == "consensus.converged" or .type == "consensus.forced_stop") ] | last) as $last_cons_end
  | ([ .[] | select(.type == "gate.approved" and .data.gate == 1) ] | last) as $gate1
  | ([ .[] | select(.type == "gate.approved" and .data.gate == 2) ] | last) as $gate2
  | ([ .[] | .seq // 0 ] | max // 0) as $max_seq

  # Current phase = max phase ever started
  | ([ .[] | select(.type == "phase.started") | .data.phase // 0 ] | max // 0) as $cur_phase

  # Session status
  | (
      if $completed   then "completed"
      elif $interrupted then "interrupted"
      elif $started   then "in-progress"
      else "unknown"
      end
    ) as $status

  # Active iteration = latest iter without a later converged/forced_stop
  | (
      if $last_iter == null then null
      elif ($last_cons_end == null) or ($last_iter.seq > $last_cons_end.seq)
      then $last_iter
      else null
      end
    ) as $active_iter

  # Phase N is completed when a phase.completed with data.phase == N exists with seq > that phase's phase.started
  | ([ .[] | select(.type == "phase.completed") | .data.phase ] | max // 0) as $max_completed_phase

  # pendingAction
  | (
      if $status == "completed" then "session.complete"
      elif $status == "interrupted" then "session.ready-to-resume"
      elif $active_iter != null then
        "phase.\($active_iter.data.phase).iteration.\($active_iter.data.iteration).active"
      elif $cur_phase > $max_completed_phase then
        "phase.\($cur_phase).completion"
      elif $cur_phase == 3 and $max_completed_phase == 3 and $gate1 == null then
        "gate.1.pending"
      elif $cur_phase == 7 and $max_completed_phase == 7 and $gate2 == null then
        "gate.2.pending"
      else
        "phase.\($cur_phase + 1).ready"
      end
    ) as $pending

  | {
      sessionDir: $sd,
      lastSeq: $max_seq,
      eventCount: (length),
      runId: ( [ .[] | .runId | select(. != null and . != "") ] | first // null ),
      mode: ($started.data.mode // null),
      featureSlug: ($started.data.featureSlug // null),
      ticket: ($started.data.ticket // null),
      currentPhase: $cur_phase,
      status: $status,
      pendingAction: $pending,
      minimumContext: { freezeDocPath: $fd }
    }
' "$EVENTS"

exit 0
```

- [ ] **Step 4: Executable + test**

```bash
chmod +x plugins/dev-framework/hooks/scripts/wake.sh
bash plugins/dev-framework/tests/m2/wake.test.sh
```

- [ ] **Step 5: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/wake.sh \
        plugins/dev-framework/tests/m2/wake.test.sh
git commit -m "feat(m2): wake.sh stateless restart primitive"
```

---

## Task 7: `replay.sh` — seq-level rewind

**Files:**
- Create: `plugins/dev-framework/hooks/scripts/replay.sh`
- Test: `plugins/dev-framework/tests/m2/replay.test.sh`

**Behavior:** Copies events up to `--until-seq N` (or all if omitted) into `--target DIR` (default: `$SESSION_DIR/.replay/`), then runs `regenerate-views.sh` against that target. Leaves original session untouched.

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m2/replay.test.sh`:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
REPLAY="$HOOKS/replay.sh"

[ -x "$REPLAY" ] || { echo "FAIL: replay not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-rep","status":"in-progress"}
JSON

bash "$EMIT" session.started --actor orchestrator --data '{"mode":"full-cycle"}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.started --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.completed --actor orchestrator --data '{"phase":2}'

# Replay to seq 3 (only session.started + phase1 started+completed)
TARGET="$TMP/replayed"
bash "$REPLAY" --until-seq 3 --target "$TARGET"

[ -f "$TARGET/events.jsonl" ] || { echo "FAIL: replay target missing events"; exit 1; }
LINES=$(wc -l < "$TARGET/events.jsonl")
[ "$LINES" = "3" ] || { echo "FAIL: replay should have 3 events, got $LINES"; exit 1; }
[ -f "$TARGET/views/progress-log.json" ] || { echo "FAIL: views not regenerated"; exit 1; }

# View should show currentPhase = 1
CP=$(jq -r '.currentPhase' "$TARGET/views/progress-log.json")
[ "$CP" = "1" ] || { echo "FAIL: replayed currentPhase != 1 (got $CP)"; exit 1; }

# Original session untouched
ORIG_COUNT=$(wc -l < "$DEVFW_TEST_SESSION_DIR/events.jsonl")
[ "$ORIG_COUNT" = "5" ] || { echo "FAIL: original modified"; exit 1; }

# Default (no --until-seq) copies all
bash "$REPLAY" --target "$TMP/all"
ALL_COUNT=$(wc -l < "$TMP/all/events.jsonl")
[ "$ALL_COUNT" = "5" ] || { echo "FAIL: default replay count"; exit 1; }

echo "PASS: replay"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m2/replay.test.sh`

- [ ] **Step 3: Write `replay.sh`**

```bash
#!/bin/bash
# replay.sh — Copy events up to --until-seq N into --target DIR and regenerate views.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"
# shellcheck source=./_reducers.sh
. "$SCRIPT_DIR/_reducers.sh"

command -v jq &>/dev/null || { echo "replay: ERROR — jq required" >&2; exit 1; }

UNTIL_SEQ=""
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --until-seq) UNTIL_SEQ="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    *) echo "replay: ERROR — unknown flag '$1'" >&2; exit 1 ;;
  esac
done

SOURCE_DIR=$(resolve_session_dir)
SOURCE_EVENTS="$SOURCE_DIR/events.jsonl"

if [ ! -f "$SOURCE_EVENTS" ]; then
  echo "replay: no events.jsonl in source session" >&2
  exit 1
fi

if [ -z "$TARGET" ]; then
  TARGET="$SOURCE_DIR/.replay"
fi

mkdir -p "$TARGET"

if [ -n "$UNTIL_SEQ" ]; then
  jq -c --argjson limit "$UNTIL_SEQ" 'select(.seq <= $limit)' "$SOURCE_EVENTS" > "$TARGET/events.jsonl"
else
  cp "$SOURCE_EVENTS" "$TARGET/events.jsonl"
fi

# Copy progress-log.json so runId is available for reducers
if [ -f "$SOURCE_DIR/progress-log.json" ]; then
  cp "$SOURCE_DIR/progress-log.json" "$TARGET/progress-log.json"
fi

# Set last seq file
LAST=$(jq -s 'map(.seq) | max // 0' "$TARGET/events.jsonl")
printf '%d' "$LAST" > "$TARGET/.seq"

# Regenerate views in target
DEVFW_TEST_SESSION_DIR="$TARGET" bash "$SCRIPT_DIR/regenerate-views.sh"

echo "replay: wrote $(wc -l < "$TARGET/events.jsonl" | tr -d ' ') events to $TARGET (views regenerated)"
exit 0
```

- [ ] **Step 4: Executable + test + commit**

```bash
chmod +x plugins/dev-framework/hooks/scripts/replay.sh
bash plugins/dev-framework/tests/m2/replay.test.sh
git add plugins/dev-framework/hooks/scripts/replay.sh \
        plugins/dev-framework/tests/m2/replay.test.sh
git commit -m "feat(m2): replay.sh seq-level rewind into alt dir"
```

---

## Task 8: Views schema reference doc

**Files:**
- Create: `plugins/dev-framework/skills/dev/references/autonomous/views-spec.md`

- [ ] **Step 1: Write spec doc** (content below)

Create `plugins/dev-framework/skills/dev/references/autonomous/views-spec.md`:

```markdown
# Views Spec

Views are **pure functions over `events.jsonl`**. They live under `$SESSION_DIR/views/` and are regenerated by reducer scripts. During M2 they are parallel artifacts (not authoritative); M3 may switch reads.

## Reducer contract

Each reducer:
1. Reads `events.jsonl` via `read_events()` (no file → empty array, exit 0).
2. Applies a jq program that produces one JSON document.
3. Atomically writes to `views/<name>.json` via `atomic_write()`.
4. Is idempotent — running N times produces the same view.
5. Is total — every event is accounted for (ignored events must be explicit, not silent).

## Views catalogued

### `views/progress-log.json`

Subset of `progress-log.json` schema derivable from events. Omits: `configSnapshot`, `plannedFiles`, `chronicPatternsLoaded`. See `reduce-progress-log.sh`.

### `views/decision-log.json`

Every `decision.recorded` event → one row. Also derives rows from `gate.approved` (category `gate-N`), `bypass.created` (category `bypass`), and `phase.failed` (category `phase-failure`). Sorted by seq.

### `views/pipeline-issues.json`

Groups `consensus.*` events by `runId` → `phase` → `iteration`. Counts `issuesFound` / `fixesApplied` per iteration. Marks `converged` / `remainingIssues` from terminal consensus events.

## Invariants

1. **Views are disposable.** Deleting `views/` and running `regenerate-views.sh` must restore the same content.
2. **No side effects.** Reducers never modify `events.jsonl` or existing state files.
3. **Schema version.** Each view has `schemaVersion: 1`. Increment on breaking schema changes; reducers must handle both versions during the deprecation window.
4. **Regeneration is cheap.** Expect <100ms for typical sessions (< 1000 events). If slower, add snapshot caching in M3+.

## Semantic equivalence (M2 goal)

For each M1-tracked state transition, the view must reflect it. Byte-equality with the procedurally-written state file is NOT required — the procedural file contains fields that events don't carry yet.

## Fields not yet captured in events (requires M2.5 if needed)

- `configSnapshot` — emit `config.snapshot.recorded` event at Pre-Workflow
- `plannedFiles` — emit `plan.files.set` event at Phase 3 completion
- `chronicPatternsLoaded` — emit `patterns.loaded` event at SessionStart hook
- `summary.totalDurationMinutes` — derivable from `at` timestamps; add to reducer
- `configSnapshot.*` sub-fields — same as `configSnapshot` above
```

- [ ] **Step 2: Commit**

```bash
git add plugins/dev-framework/skills/dev/references/autonomous/views-spec.md
git commit -m "docs(m2): add views-spec reference"
```

---

## Task 9: Semantic equivalence integration test

**Files:**
- Create: `plugins/dev-framework/tests/m2/semantic-equivalence.test.sh`

**Goal:** run a representative session flow, then for each M1-emitted state transition verify it appears correctly in the regenerated view.

- [ ] **Step 1: Write the test**

Create `plugins/dev-framework/tests/m2/semantic-equivalence.test.sh`:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
REGEN="$HOOKS/regenerate-views.sh"
WAKE="$HOOKS/wake.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{"schemaVersion":1,"runId":"run-sem","status":"in-progress","freezeDocPath":"docs/specs/x-freeze.md"}
JSON

# Simulate a full Phase 1-3 flow with GATE 1
bash "$EMIT" session.started     --actor orchestrator --data '{"mode":"full-cycle","featureSlug":"semtest"}'
bash "$EMIT" phase.started       --actor orchestrator --data '{"phase":1}'
bash "$EMIT" decision.recorded   --actor orchestrator --data '{"id":"D001","phase":1,"category":"plan","decision":"x","reason":"y","confidence":"high"}'
bash "$EMIT" phase.completed     --actor orchestrator --data '{"phase":1}'
bash "$EMIT" phase.started       --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.completed     --actor orchestrator --data '{"phase":2}'
bash "$EMIT" phase.started       --actor orchestrator --data '{"phase":3}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":3,"iteration":1}'
bash "$EMIT" consensus.issues.found      --actor "agent:arch" --data '{"phase":3,"iteration":1,"issues":[{"s":"H"}]}'
bash "$EMIT" consensus.fix.applied       --actor orchestrator --data '{"phase":3,"iteration":1,"issueId":"I1"}'
bash "$EMIT" consensus.iteration.started --actor orchestrator --data '{"phase":3,"iteration":2}'
bash "$EMIT" consensus.converged         --actor orchestrator --data '{"phase":3,"iterations":2,"issuesFixed":1}'
bash "$EMIT" phase.completed             --actor orchestrator --data '{"phase":3}'
bash "$EMIT" gate.approved               --actor orchestrator --data '{"gate":1,"approvalMode":"interactive","approvedBy":"tester"}'

bash "$REGEN"

# --- Assertions on progress-log view ---
PV="$DEVFW_TEST_SESSION_DIR/views/progress-log.json"
[ "$(jq -r '.status' "$PV")" = "in-progress" ] || { echo "FAIL: pv.status"; exit 1; }
[ "$(jq -r '.mode' "$PV")" = "full-cycle" ] || { echo "FAIL: pv.mode"; exit 1; }
[ "$(jq -r '.currentPhase' "$PV")" = "3" ] || { echo "FAIL: pv.currentPhase"; exit 1; }
[ "$(jq -r '.phases | length' "$PV")" = "3" ] || { echo "FAIL: pv.phases length"; exit 1; }
[ "$(jq -r '.phases[2].status' "$PV")" = "completed" ] || { echo "FAIL: pv.phase3.status"; exit 1; }
[ "$(jq -r '.summary.gateApprovals.gate1' "$PV")" = "interactive" ] || { echo "FAIL: pv.gateApprovals.gate1"; exit 1; }
[ "$(jq -r '.summary.consensusRounds.phase3' "$PV")" = "2" ] || { echo "FAIL: pv.consensusRounds.phase3"; exit 1; }

# --- Assertions on decision-log view ---
DV="$DEVFW_TEST_SESSION_DIR/views/decision-log.json"
# 1 explicit decision + 1 gate-1 derived = 2
[ "$(jq -r '.decisions | length' "$DV")" = "2" ] || { echo "FAIL: dv.decisions length"; exit 1; }

# --- Assertions on pipeline-issues view ---
IV="$DEVFW_TEST_SESSION_DIR/views/pipeline-issues.json"
[ "$(jq -r '.runs[0].runId' "$IV")" = "run-sem" ] || { echo "FAIL: iv.runId"; exit 1; }
[ "$(jq -r '.runs[0].phases."3".iterations | length' "$IV")" = "2" ] || { echo "FAIL: iv.iterations"; exit 1; }
[ "$(jq -r '.runs[0].phases."3".converged' "$IV")" = "true" ] || { echo "FAIL: iv.converged"; exit 1; }

# --- Assertions on wake ---
WO=$(bash "$WAKE")
[ "$(echo "$WO" | jq -r '.pendingAction')" = "phase.4.ready" ] || { echo "FAIL: wake pendingAction (got $(echo "$WO" | jq -r '.pendingAction'))"; exit 1; }
[ "$(echo "$WO" | jq -r '.status')" = "in-progress" ] || { echo "FAIL: wake.status"; exit 1; }
[ "$(echo "$WO" | jq -r '.minimumContext.freezeDocPath')" = "docs/specs/x-freeze.md" ] || { echo "FAIL: wake.freezeDocPath"; exit 1; }

echo "PASS: semantic-equivalence"
```

- [ ] **Step 2: Run test**

Run: `bash plugins/dev-framework/tests/m2/semantic-equivalence.test.sh`
Expected: `PASS`

- [ ] **Step 3: Commit**

```bash
git add plugins/dev-framework/tests/m2/semantic-equivalence.test.sh
git commit -m "test(m2): semantic equivalence integration test"
```

---

## Task 10: Run all M1+M2 tests together

- [ ] **Step 1: Combined suite**

Run:
```bash
cd /c/Users/jiho0/repos/dev-framework
for t in plugins/dev-framework/tests/m1/*.test.sh plugins/dev-framework/tests/m2/*.test.sh; do
  bash "$t" > /tmp/test-out 2>&1 && echo "✓ $t" || { echo "✗ $t"; cat /tmp/test-out; exit 1; }
done
echo "ALL M1+M2 TESTS PASS"
```

Expected: all PASS.

---

## Task 11: Update CLAUDE.md with views + wake

**Files:**
- Modify: `plugins/dev-framework/CLAUDE.md`

- [ ] **Step 1: Add views/ rows + wake description**

Under the Session State table, add `views/` row:

```markdown
| `views/` | Regenerated views (M2+); pure functions over `events.jsonl`. Contains `progress-log.json`, `decision-log.json`, `pipeline-issues.json`. Disposable — regenerate via `hooks/scripts/regenerate-views.sh`. |
```

In the Events subsection (M1+), add to the primitives list:

```markdown
- `regenerate-views.sh` — regenerate all views from events
- `wake.sh` — returns compact JSON with `{sessionDir, lastSeq, currentPhase, status, pendingAction, minimumContext}` for stateless restart
- `replay.sh --until-seq N --target DIR` — copy events up to seq N into an alt dir and regenerate views there (rewind/branch primitive)
```

- [ ] **Step 2: Commit**

```bash
git add plugins/dev-framework/CLAUDE.md
git commit -m "docs(m2): document views, wake, replay in CLAUDE.md"
```

---

## Self-Review Checklist

**1. Spec coverage:**
- [ ] §3.3 views — Tasks 2-5
- [ ] §3.5 stateless dispatcher — wake.sh (Task 6) is a prerequisite; dispatcher itself is M3
- [ ] §6 M2 success: "views regenerated from events match original" — semantic equivalence test (Task 9)

**2. Placeholder scan:**
- [ ] No TBD
- [ ] Every jq program complete (not abbreviated)
- [ ] Every file path exact

**3. Type consistency:**
- [ ] Reducer view names match across scripts and docs
- [ ] Event field names match between emit sites (M1) and reducer jq paths

**4. Behavior preservation:**
- [ ] No existing hooks modified (M2 is entirely additive — new files only, except CLAUDE.md doc update)
- [ ] `events.jsonl` append path unchanged (emit-event.sh untouched)
- [ ] M1 tests continue to pass

**5. Dependencies:**
- [ ] jq present (already required by M1)
- [ ] mkdir-based locks (none in M2 — reducers are read-only on events, atomic-write on views)
