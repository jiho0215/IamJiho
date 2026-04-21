# M1 — Event Log Dual-Write Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce an append-only `events.jsonl` event log to each session folder, with `emit-event.sh` and `get-events.sh` primitives. Dual-write: every existing state transition in hooks and SKILL.md emits a corresponding event alongside current file writes. Zero change to existing behavior.

**Architecture:** New events.jsonl file at `$SESSION_DIR/events.jsonl` with atomic mkdir-based locking on `.seq` counter. Shared session-resolution helpers extracted to `_session-lib.sh` to DRY the duplicated logic across existing hooks. Each hook and each SKILL.md phase transition adds an `emit-event.sh <type> --data '...'` call.

**Tech Stack:** Bash (git-bash-compatible on Windows), jq (already a dependency), standard POSIX tools. No new runtime dependencies.

**Reference:** [docs/specs/2026-04-20-managed-agents-evolution.md](../specs/2026-04-20-managed-agents-evolution.md) §3.1, §3.2.

---

## File Structure

**Create:**
- `plugins/dev-framework/hooks/scripts/_session-lib.sh` — sourced helper library
- `plugins/dev-framework/hooks/scripts/emit-event.sh` — append event with atomic seq
- `plugins/dev-framework/hooks/scripts/get-events.sh` — jq-backed query
- `plugins/dev-framework/skills/dev/references/autonomous/events-schema.md` — event type catalog
- `plugins/dev-framework/tests/m1/emit-event.test.sh` — verification script
- `plugins/dev-framework/tests/m1/get-events.test.sh` — verification script
- `plugins/dev-framework/tests/m1/dual-write-integration.test.sh` — end-to-end check

**Modify (dual-write additions only; no behavior change):**
- `plugins/dev-framework/hooks/scripts/phase-gate.sh` — source lib, emit events at pass/block
- `plugins/dev-framework/hooks/scripts/freeze-gate.sh` — source lib, emit `gate.blocked` when blocking
- `plugins/dev-framework/hooks/scripts/push-guard.sh` — source lib, emit `gate.blocked` / `gate.passed`
- `plugins/dev-framework/hooks/scripts/sessionend.sh` — source lib, emit `session.interrupted` / `bypass.preserved`
- `plugins/dev-framework/hooks/scripts/ensure-config.sh` — source lib (opportunistic DRY)
- `plugins/dev-framework/hooks/scripts/precompact.sh` — source lib, emit `session.precompact`
- `plugins/dev-framework/skills/dev/SKILL.md` — emit events at phase start, phase end, GATE 1, GATE 2, bypass create, decisions

---

## Task 1: Shared session-resolution helpers (`_session-lib.sh`)

**Files:**
- Create: `plugins/dev-framework/hooks/scripts/_session-lib.sh`
- Test: `plugins/dev-framework/tests/m1/session-lib.test.sh`

**Rationale:** Four existing scripts (`phase-gate.sh`, `sessionend.sh`, `freeze-gate.sh`, `push-guard.sh`) duplicate `cfg()`, `sanitize_branch()`, `get_repo_name()`, and SESSION_DIR resolution. Extract now so M1 event scripts and future M2+ scripts share one implementation.

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m1/session-lib.test.sh`:

```bash
#!/bin/bash
# Verify _session-lib.sh helpers behave correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../../hooks/scripts/_session-lib.sh"

[ -f "$LIB" ] || { echo "FAIL: _session-lib.sh not found at $LIB"; exit 1; }

# shellcheck disable=SC1090
. "$LIB"

# sanitize_branch
[ "$(sanitize_branch 'feature/auth-flow')" = "feature-auth-flow" ] \
  || { echo "FAIL: sanitize_branch slash"; exit 1; }
[ "$(sanitize_branch 'foo@bar:baz')" = "foo-bar-baz" ] \
  || { echo "FAIL: sanitize_branch special chars"; exit 1; }
[ "$(sanitize_branch 'trailing...')" = "trailing" ] \
  || { echo "FAIL: sanitize_branch trailing dots"; exit 1; }

# iso_utc format (must match ^YYYY-MM-DDTHH:MM:SSZ$)
ts=$(iso_utc)
[[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || { echo "FAIL: iso_utc format ($ts)"; exit 1; }

# cfg fallback (nonexistent config file → should return default)
export DEVFW_CONFIG="/tmp/nonexistent-devfw-$$.json"
[ "$(cfg '.any.key' 'fallback')" = "fallback" ] \
  || { echo "FAIL: cfg fallback"; exit 1; }

# resolve_session_dir returns non-empty absolute path
sd=$(resolve_session_dir)
[ -n "$sd" ] || { echo "FAIL: resolve_session_dir empty"; exit 1; }
[[ "$sd" == /* ]] || [[ "$sd" =~ ^[A-Za-z]: ]] \
  || { echo "FAIL: resolve_session_dir not absolute ($sd)"; exit 1; }

echo "PASS: session-lib helpers"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m1/session-lib.test.sh`
Expected: FAIL with "_session-lib.sh not found"

- [ ] **Step 3: Write `_session-lib.sh` implementation**

Create `plugins/dev-framework/hooks/scripts/_session-lib.sh`:

```bash
#!/bin/bash
# _session-lib.sh — Shared helpers for dev-framework hooks.
# Source with: . "$(dirname "${BASH_SOURCE[0]}")/_session-lib.sh"
#
# Exports: cfg, sanitize_branch, get_repo_name, resolve_session_dir, iso_utc
# Env: DEVFW_CONFIG (override default config path)

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugins/dev-framework/tests/m1/session-lib.test.sh`
Expected: `PASS: session-lib helpers`

- [ ] **Step 5: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/_session-lib.sh \
        plugins/dev-framework/tests/m1/session-lib.test.sh
git commit -m "feat(m1): add _session-lib.sh shared helpers"
```

---

## Task 2: `emit-event.sh` — atomic event append

**Files:**
- Create: `plugins/dev-framework/hooks/scripts/emit-event.sh`
- Test: `plugins/dev-framework/tests/m1/emit-event.test.sh`

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m1/emit-event.test.sh`:

```bash
#!/bin/bash
# Verify emit-event.sh creates valid JSONL entries with atomic seq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"

[ -x "$EMIT" ] || { echo "FAIL: emit-event.sh not found or not executable"; exit 1; }

# Isolated test session dir
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Override session resolution via DEVFW_TEST_SESSION_DIR env (lib honors this)
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

# --- Test 1: no-op when session dir missing ---
export DEVFW_TEST_SESSION_DIR="$TMP/nonexistent"
bash "$EMIT" test.noop --data '{}' 2>/dev/null
# Exit 0, and no events.jsonl should be created
[ ! -f "$TMP/nonexistent/events.jsonl" ] \
  || { echo "FAIL: no-op path created events.jsonl"; exit 1; }

# --- Test 2: happy path writes valid JSON with seq=1 ---
export DEVFW_TEST_SESSION_DIR="$TMP/session"
bash "$EMIT" phase.started --data '{"phase":1}' --actor "test"
EVENTS="$DEVFW_TEST_SESSION_DIR/events.jsonl"
[ -f "$EVENTS" ] || { echo "FAIL: events.jsonl not created"; exit 1; }
LINE=$(cat "$EVENTS")
echo "$LINE" | jq empty || { echo "FAIL: line is not valid JSON"; exit 1; }
[ "$(echo "$LINE" | jq -r '.seq')" = "1" ] \
  || { echo "FAIL: seq != 1 (got $(echo "$LINE" | jq -r '.seq'))"; exit 1; }
[ "$(echo "$LINE" | jq -r '.type')" = "phase.started" ] \
  || { echo "FAIL: type mismatch"; exit 1; }
[ "$(echo "$LINE" | jq -r '.actor')" = "test" ] \
  || { echo "FAIL: actor mismatch"; exit 1; }
[ "$(echo "$LINE" | jq -r '.data.phase')" = "1" ] \
  || { echo "FAIL: data.phase mismatch"; exit 1; }

# --- Test 3: subsequent emits increment seq ---
bash "$EMIT" phase.completed --data '{"phase":1}' --actor "test"
bash "$EMIT" phase.started --data '{"phase":2}' --actor "test"
COUNT=$(wc -l < "$EVENTS")
[ "$COUNT" = "3" ] || { echo "FAIL: expected 3 events, got $COUNT"; exit 1; }
SEQ2=$(sed -n '2p' "$EVENTS" | jq -r '.seq')
SEQ3=$(sed -n '3p' "$EVENTS" | jq -r '.seq')
[ "$SEQ2" = "2" ] || { echo "FAIL: seq2 != 2 (got $SEQ2)"; exit 1; }
[ "$SEQ3" = "3" ] || { echo "FAIL: seq3 != 3 (got $SEQ3)"; exit 1; }

# --- Test 4: concurrent emits don't duplicate seq ---
rm -f "$EVENTS" "$DEVFW_TEST_SESSION_DIR/.seq"
for i in 1 2 3 4 5 6 7 8 9 10; do
  bash "$EMIT" concurrent.test --data "{\"i\":$i}" --actor "test" &
done
wait
COUNT=$(wc -l < "$EVENTS")
[ "$COUNT" = "10" ] || { echo "FAIL: expected 10 events under concurrency, got $COUNT"; exit 1; }
UNIQUE_SEQS=$(jq -r '.seq' "$EVENTS" | sort -n | uniq | wc -l)
[ "$UNIQUE_SEQS" = "10" ] || { echo "FAIL: seq collisions under concurrency ($UNIQUE_SEQS unique of 10)"; exit 1; }

# --- Test 5: invalid --data JSON is rejected (falls back to {}) ---
rm -f "$EVENTS" "$DEVFW_TEST_SESSION_DIR/.seq"
bash "$EMIT" bad.data --data 'not-json' --actor "test"
DATA=$(jq -r '.data' "$EVENTS")
[ "$DATA" = "{}" ] || { echo "FAIL: invalid data not sanitized (got $DATA)"; exit 1; }

echo "PASS: emit-event"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m1/emit-event.test.sh`
Expected: FAIL with "emit-event.sh not found or not executable"

- [ ] **Step 3: Extend `_session-lib.sh` with `resolve_session_dir` override hook**

The test uses `DEVFW_TEST_SESSION_DIR` to bypass git-based resolution. Update `resolve_session_dir` at the top to honor this env:

Edit `plugins/dev-framework/hooks/scripts/_session-lib.sh`:

Replace the existing `resolve_session_dir()` function with:

```bash
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
```

- [ ] **Step 4: Write `emit-event.sh` implementation**

Create `plugins/dev-framework/hooks/scripts/emit-event.sh`:

```bash
#!/bin/bash
# emit-event.sh — Append one event to $SESSION_DIR/events.jsonl.
#
# Usage: emit-event.sh <type> [--data JSON] [--actor ACTOR] [--run-id ID]
#
# No-op (exit 0) when session dir doesn't exist — early-phase invocations must
# not fail. Uses mkdir-based lock on .seq.lock (NTFS-safe).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

TYPE="${1:-}"
if [ -z "$TYPE" ]; then
  echo "emit-event: ERROR — missing event type argument" >&2
  exit 1
fi
shift

DATA='{}'
ACTOR='orchestrator'
RUN_ID_OVERRIDE=''
while [ $# -gt 0 ]; do
  case "$1" in
    --data) DATA="$2"; shift 2 ;;
    --actor) ACTOR="$2"; shift 2 ;;
    --run-id) RUN_ID_OVERRIDE="$2"; shift 2 ;;
    *) echo "emit-event: WARNING — unknown flag '$1'" >&2; shift ;;
  esac
done

SESSION_DIR=$(resolve_session_dir)
[ -d "$SESSION_DIR" ] || exit 0

EVENTS_FILE="$SESSION_DIR/events.jsonl"
SEQ_FILE="$SESSION_DIR/.seq"
LOCK_DIR="$SESSION_DIR/.seq.lock"

RUN_ID="$RUN_ID_OVERRIDE"
if [ -z "$RUN_ID" ] && [ -f "$SESSION_DIR/progress-log.json" ] && command -v jq &>/dev/null; then
  RUN_ID=$(jq -r '.runId // empty' "$SESSION_DIR/progress-log.json" 2>/dev/null || echo "")
fi

LOCK_TRIES=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  LOCK_TRIES=$((LOCK_TRIES + 1))
  if [ "$LOCK_TRIES" -gt 50 ]; then
    echo "emit-event: ERROR — could not acquire lock at $LOCK_DIR after 50 tries" >&2
    exit 1
  fi
  sleep 0.1
done
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

LAST_SEQ=0
if [ -f "$SEQ_FILE" ]; then
  LAST_SEQ=$(cat "$SEQ_FILE" 2>/dev/null || echo 0)
  [[ "$LAST_SEQ" =~ ^[0-9]+$ ]] || LAST_SEQ=0
fi
NEW_SEQ=$((LAST_SEQ + 1))
AT=$(iso_utc)

if command -v jq &>/dev/null; then
  echo "$DATA" | jq empty 2>/dev/null || DATA='{}'
  jq -cn \
    --argjson seq "$NEW_SEQ" \
    --arg at "$AT" \
    --arg run "$RUN_ID" \
    --arg actor "$ACTOR" \
    --arg type "$TYPE" \
    --argjson data "$DATA" \
    '{seq:$seq, at:$at, runId:$run, actor:$actor, type:$type, data:$data}' \
    >> "$EVENTS_FILE"
else
  printf '{"seq":%d,"at":"%s","runId":"%s","actor":"%s","type":"%s","data":%s}\n' \
    "$NEW_SEQ" "$AT" "$RUN_ID" "$ACTOR" "$TYPE" "$DATA" \
    >> "$EVENTS_FILE"
fi

printf '%d' "$NEW_SEQ" > "$SEQ_FILE.tmp" && mv "$SEQ_FILE.tmp" "$SEQ_FILE"
exit 0
```

- [ ] **Step 5: Make emit-event.sh executable**

Run: `chmod +x plugins/dev-framework/hooks/scripts/emit-event.sh`

- [ ] **Step 6: Run test to verify it passes**

Run: `bash plugins/dev-framework/tests/m1/emit-event.test.sh`
Expected: `PASS: emit-event`

- [ ] **Step 7: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/emit-event.sh \
        plugins/dev-framework/hooks/scripts/_session-lib.sh \
        plugins/dev-framework/tests/m1/emit-event.test.sh
git commit -m "feat(m1): add emit-event.sh with atomic seq assignment"
```

---

## Task 3: `get-events.sh` — query events

**Files:**
- Create: `plugins/dev-framework/hooks/scripts/get-events.sh`
- Test: `plugins/dev-framework/tests/m1/get-events.test.sh`

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-framework/tests/m1/get-events.test.sh`:

```bash
#!/bin/bash
# Verify get-events.sh filters correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"
EMIT="$HOOKS/emit-event.sh"
GET="$HOOKS/get-events.sh"

[ -x "$GET" ] || { echo "FAIL: get-events.sh not found or not executable"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

# Seed 5 events
bash "$EMIT" phase.started     --data '{"phase":1}' --actor "orchestrator"
bash "$EMIT" phase.completed   --data '{"phase":1}' --actor "orchestrator"
bash "$EMIT" phase.started     --data '{"phase":2}' --actor "orchestrator"
bash "$EMIT" consensus.issue.found --data '{"phase":2,"severity":"HIGH"}' --actor "agent:architect"
bash "$EMIT" phase.completed   --data '{"phase":2}' --actor "orchestrator"

# --- Test 1: no filter → all events ---
COUNT=$(bash "$GET" --format count)
[ "$COUNT" = "5" ] || { echo "FAIL: no filter count != 5 (got $COUNT)"; exit 1; }

# --- Test 2: exact type match ---
COUNT=$(bash "$GET" --type phase.started --format count)
[ "$COUNT" = "2" ] || { echo "FAIL: exact type count != 2 (got $COUNT)"; exit 1; }

# --- Test 3: prefix type match ---
COUNT=$(bash "$GET" --type 'phase.*' --format count)
[ "$COUNT" = "4" ] || { echo "FAIL: prefix type count != 4 (got $COUNT)"; exit 1; }

# --- Test 4: phase filter ---
COUNT=$(bash "$GET" --phase 2 --format count)
[ "$COUNT" = "3" ] || { echo "FAIL: phase filter count != 3 (got $COUNT)"; exit 1; }

# --- Test 5: since-seq ---
COUNT=$(bash "$GET" --since-seq 4 --format count)
[ "$COUNT" = "2" ] || { echo "FAIL: since-seq count != 2 (got $COUNT)"; exit 1; }

# --- Test 6: actor prefix ---
COUNT=$(bash "$GET" --actor 'agent:*' --format count)
[ "$COUNT" = "1" ] || { echo "FAIL: actor prefix count != 1 (got $COUNT)"; exit 1; }

# --- Test 7: limit ---
COUNT=$(bash "$GET" --limit 2 --format count)
[ "$COUNT" = "2" ] || { echo "FAIL: limit count != 2 (got $COUNT)"; exit 1; }

# --- Test 8: summary format has tab-separated columns ---
SUMMARY=$(bash "$GET" --type phase.started --format summary | head -n1)
echo "$SUMMARY" | grep -q $'\t' || { echo "FAIL: summary missing tabs"; exit 1; }

# --- Test 9: combined filter ---
COUNT=$(bash "$GET" --type 'phase.*' --phase 2 --format count)
[ "$COUNT" = "2" ] || { echo "FAIL: combined filter count != 2 (got $COUNT)"; exit 1; }

# --- Test 10: nonexistent events.jsonl → exit 0, no output ---
rm "$DEVFW_TEST_SESSION_DIR/events.jsonl"
OUT=$(bash "$GET" --format count)
[ "$OUT" = "0" ] || [ -z "$OUT" ] || { echo "FAIL: missing events.jsonl should give 0/empty (got '$OUT')"; exit 1; }

echo "PASS: get-events"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/dev-framework/tests/m1/get-events.test.sh`
Expected: FAIL with "get-events.sh not found or not executable"

- [ ] **Step 3: Write `get-events.sh` implementation**

Create `plugins/dev-framework/hooks/scripts/get-events.sh`:

```bash
#!/bin/bash
# get-events.sh — Query events.jsonl for the current session.
#
# Usage:
#   get-events.sh [--type T] [--phase N] [--actor A] [--since-seq N]
#                 [--until-seq N] [--run-id ID] [--limit N]
#                 [--format json|summary|count]
#
# --type and --actor accept exact match or trailing-* prefix (e.g. "phase.*").
# --format defaults to json. json/summary emit lines; count emits a single integer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

command -v jq &>/dev/null || { echo "get-events: ERROR — jq required" >&2; exit 1; }

TYPE=''
PHASE=''
ACTOR=''
SINCE_SEQ=''
UNTIL_SEQ=''
RUN_ID=''
LIMIT=''
FORMAT='json'

while [ $# -gt 0 ]; do
  case "$1" in
    --type) TYPE="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --actor) ACTOR="$2"; shift 2 ;;
    --since-seq) SINCE_SEQ="$2"; shift 2 ;;
    --until-seq) UNTIL_SEQ="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    *) echo "get-events: ERROR — unknown flag '$1'" >&2; exit 1 ;;
  esac
done

SESSION_DIR=$(resolve_session_dir)
EVENTS_FILE="$SESSION_DIR/events.jsonl"

if [ ! -f "$EVENTS_FILE" ]; then
  case "$FORMAT" in
    count) echo 0 ;;
    *) : ;;
  esac
  exit 0
fi

FILTER='.'

add_type_or_actor_filter() {
  local field="$1" val="$2"
  if [ -z "$val" ]; then return; fi
  if [[ "$val" == *'*' ]]; then
    local prefix="${val%\*}"
    FILTER="$FILTER | select(.$field | startswith(\"$prefix\"))"
  else
    FILTER="$FILTER | select(.$field == \"$val\")"
  fi
}

add_type_or_actor_filter type "$TYPE"
add_type_or_actor_filter actor "$ACTOR"
[ -n "$PHASE" ]      && FILTER="$FILTER | select(.data.phase == $PHASE)"
[ -n "$SINCE_SEQ" ]  && FILTER="$FILTER | select(.seq >= $SINCE_SEQ)"
[ -n "$UNTIL_SEQ" ]  && FILTER="$FILTER | select(.seq <= $UNTIL_SEQ)"
[ -n "$RUN_ID" ]     && FILTER="$FILTER | select(.runId == \"$RUN_ID\")"

RESULT=$(jq -c "$FILTER" "$EVENTS_FILE")

if [ -n "$LIMIT" ]; then
  RESULT=$(echo "$RESULT" | head -n "$LIMIT")
fi

case "$FORMAT" in
  json)    [ -n "$RESULT" ] && echo "$RESULT" ;;
  summary) [ -n "$RESULT" ] && echo "$RESULT" | jq -r '[.seq, .at, .actor, .type] | @tsv' ;;
  count)   if [ -z "$RESULT" ]; then echo 0; else echo "$RESULT" | wc -l | tr -d ' '; fi ;;
  *) echo "get-events: ERROR — unknown format '$FORMAT'" >&2; exit 1 ;;
esac
exit 0
```

- [ ] **Step 4: Make get-events.sh executable**

Run: `chmod +x plugins/dev-framework/hooks/scripts/get-events.sh`

- [ ] **Step 5: Run test to verify it passes**

Run: `bash plugins/dev-framework/tests/m1/get-events.test.sh`
Expected: `PASS: get-events`

- [ ] **Step 6: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/get-events.sh \
        plugins/dev-framework/tests/m1/get-events.test.sh
git commit -m "feat(m1): add get-events.sh query primitive"
```

---

## Task 4: Event schema reference document

**Files:**
- Create: `plugins/dev-framework/skills/dev/references/autonomous/events-schema.md`

**Rationale:** Event types and their data payloads need a canonical catalog so SKILL.md and future dispatcher have a shared vocabulary.

- [ ] **Step 1: Write the schema document**

Create `plugins/dev-framework/skills/dev/references/autonomous/events-schema.md`:

```markdown
# Events Schema

Append-only event log at `$SESSION_DIR/events.jsonl`. Each line is one event.

## Event envelope

Every event has:

| Field | Type | Description |
|---|---|---|
| `seq` | int | Monotonically increasing per session. Assigned atomically by `emit-event.sh`. |
| `at` | string | ISO-8601 UTC timestamp (e.g. `2026-04-20T10:30:00Z`). |
| `runId` | string | Pipeline run identifier. Empty string if emitted before progress-log.json exists. |
| `actor` | string | Who emitted. Examples: `orchestrator`, `agent:code-quality-reviewer`, `hook:freeze-gate`, `skill:superpowers:brainstorming`, `user`. |
| `type` | string | Dot-separated event type. See catalog below. |
| `data` | object | Type-specific payload. Always an object, may be `{}`. |

## Type catalog

### `phase.*` — phase lifecycle

| Type | Data | Emitted by |
|---|---|---|
| `phase.started` | `{phase: int}` | SKILL.md at Begin gate pass |
| `phase.completed` | `{phase: int, metrics?: object}` | SKILL.md at End gate pass |
| `phase.failed` | `{phase: int, error: string}` | SKILL.md in Phase Failure Protocol |
| `phase.skipped` | `{phase: int, reason: string}` | SKILL.md when Skip-to-next chosen |

### `gate.*` — gate events

| Type | Data | Emitted by |
|---|---|---|
| `gate.passed` | `{gate: "phase\|freeze\|push", detail: object}` | phase-gate.sh, freeze-gate.sh, push-guard.sh |
| `gate.blocked` | `{gate: "phase\|freeze\|push", reason: string, detail?: object}` | same hooks |
| `gate.approved` | `{gate: 1\|2, approvalMode: "interactive\|autonomous", approvedBy: string}` | SKILL.md at GATE 1 or GATE 2 |
| `gate.rejected` | `{gate: 1\|2, reason: string, returnToPhase?: int}` | SKILL.md at GATE 1/GATE 2 rejection |

### `consensus.*` — multi-agent consensus

| Type | Data | Emitted by |
|---|---|---|
| `consensus.started` | `{phase: int, taskType: string, agents: string[]}` | SKILL.md entering consensus |
| `consensus.iteration.started` | `{phase: int, iteration: int}` | review-loop emitted by SKILL.md |
| `consensus.agent.dispatched` | `{phase: int, iteration: int, agent: string}` | SKILL.md |
| `consensus.issues.found` | `{phase: int, iteration: int, agent: string, issues: object[]}` | SKILL.md (post-agent) |
| `consensus.fix.applied` | `{phase: int, iteration: int, issueId: string, file?: string}` | SKILL.md |
| `consensus.converged` | `{phase: int, iterations: int, issuesFixed: int}` | SKILL.md |
| `consensus.forced_stop` | `{phase: int, iterations: int, remainingIssues: int}` | SKILL.md at iteration cap |

### `bypass.*` — freeze-gate bypass lifecycle

| Type | Data | Emitted by |
|---|---|---|
| `bypass.created` | `{feature: string, reason: string, userMessage: string}` | SKILL.md on bypass request |
| `bypass.preserved` | `{at: string, runId: string, preservedAt: string}` | sessionend.sh |
| `bypass.archived` | `{count: int}` | SKILL.md at GATE 2 (freeze doc bypassHistory merge) |

### `tool.call.*` — dispatched tool invocations

Emitted by `execute.sh` wrapper (introduced in M3). Not emitted in M1.

| Type | Data |
|---|---|
| `tool.call.started` | `{kind: string, name: string, inputHash: string}` |
| `tool.call.completed` | `{kind: string, name: string, durationMs: int, outputSummary?: string}` |
| `tool.call.failed` | `{kind: string, name: string, failureSource: string, error: string}` |

### `reference.*` — lazy reference loading

Emitted when dispatcher loads a reference file. Not emitted in M1.

| Type | Data |
|---|---|
| `reference.loaded` | `{path: string, phase: int}` |

### `artifact.*` — file changes visible to orchestrator

Optional. Not emitted in M1. M2+ may hook via post-tool-use.

### `session.*` — session lifecycle

| Type | Data | Emitted by |
|---|---|---|
| `session.started` | `{mode: string, featureSlug?: string, ticket?: string}` | SKILL.md Pre-Workflow |
| `session.interrupted` | `{interruptedAt: string, currentPhase: int}` | sessionend.sh |
| `session.resumed` | `{fromPhase: int, fromSeq: int}` | SKILL.md --from handler |
| `session.precompact` | `{reason: string}` | precompact.sh |
| `session.completed` | `{totalMinutes: number}` | SKILL.md at GATE 2 |

### `decision.*` — user or orchestrator decisions

Alongside the existing decision-log.json (dual-write in M1).

| Type | Data |
|---|---|
| `decision.recorded` | `{id: string, phase: int, category: string, decision: string, reason: string, confidence: string}` |

## Invariants

1. **Monotonic seq.** Within a session, `seq` strictly increases. Concurrent writes serialized by mkdir lock on `.seq.lock`.
2. **Append-only.** Never rewrite `events.jsonl`. Regenerated views live in `$SESSION_DIR/views/` (M2+).
3. **No PII in `data`.** Never include credentials, tokens, or full secret payloads.
4. **Stability.** Once deployed, an event type's schema may only extend (add optional fields). Breaking changes require a new type name.

## Query examples

```bash
# All phase transitions for current session
bash hooks/scripts/get-events.sh --type 'phase.*'

# Where did we block freeze-gate?
bash hooks/scripts/get-events.sh --type gate.blocked --format summary

# Consensus performance in Phase 5
bash hooks/scripts/get-events.sh --type consensus.iteration.started --phase 5 --format count

# Events since last known seq (for wake())
bash hooks/scripts/get-events.sh --since-seq 42
```
```

- [ ] **Step 2: Commit**

```bash
git add plugins/dev-framework/skills/dev/references/autonomous/events-schema.md
git commit -m "docs(m1): add events schema reference"
```

---

## Task 5: Dual-write in `phase-gate.sh`

**Files:**
- Modify: `plugins/dev-framework/hooks/scripts/phase-gate.sh`

- [ ] **Step 1: Refactor `phase-gate.sh` to source `_session-lib.sh`**

Edit `plugins/dev-framework/hooks/scripts/phase-gate.sh`:

Replace the session-resolution block (after `set -euo pipefail` and arg parsing, starting at the `# --- Config loading with fallback defaults ---` comment through the `PROGRESS_LOG="$SESSION_DIR/progress-log.json"` line) with:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_session-lib.sh
. "$SCRIPT_DIR/_session-lib.sh"

SESSION_DIR=$(resolve_session_dir)
PROGRESS_LOG="$SESSION_DIR/progress-log.json"
```

(The shared lib provides `cfg`, `sanitize_branch`, `get_repo_name`, `iso_utc`; delete the now-unused inline definitions.)

- [ ] **Step 2: Add event emits at each exit point**

At the end of the `verify` branch (before `exit 0` of the PASSED path), add:

```bash
    bash "$SCRIPT_DIR/emit-event.sh" gate.passed \
      --actor "hook:phase-gate" \
      --data '{"gate":"phase","action":"verify"}'
    exit 0
```

For each `PHASE GATE FAILED [verify]` exit point, add before `exit 2`:

```bash
    bash "$SCRIPT_DIR/emit-event.sh" gate.blocked \
      --actor "hook:phase-gate" \
      --data "$(jq -cn --arg reason "<reason string>" '{gate:"phase",action:"verify",reason:$reason}')"
    exit 2
```

Use a descriptive `reason` like `"progress-log.json missing"`, `"progress-log.json invalid JSON"`, `"progress-log.json missing schemaVersion"`.

For the `begin` branch PASSED exit, add before `exit 0`:

```bash
    bash "$SCRIPT_DIR/emit-event.sh" gate.passed \
      --actor "hook:phase-gate" \
      --data "$(jq -cn --argjson phase "$PHASE" --arg action "begin" '{gate:"phase",phase:$phase,action:$action}')"
    exit 0
```

For each `PHASE GATE FAILED [Phase $PHASE: $NAME]` exit (begin branch), add before `exit 2`:

```bash
    bash "$SCRIPT_DIR/emit-event.sh" gate.blocked \
      --actor "hook:phase-gate" \
      --data "$(jq -cn --argjson phase "$PHASE" --arg action "begin" --arg reason "<reason string>" \
        '{gate:"phase",phase:$phase,action:$action,reason:$reason}')"
    exit 2
```

Use reasons like `"progress-log missing"`, `"progress-log invalid JSON"`, `"pipeline already completed"`, `"previous phase not completed"`.

Do the same for the `end` branch: emit `gate.passed` on success and `gate.blocked` on each failure with distinct reasons.

- [ ] **Step 3: Manual smoke test**

Run (in a test session):

```bash
export DEVFW_TEST_SESSION_DIR=/tmp/phase-gate-smoke-$$
mkdir -p "$DEVFW_TEST_SESSION_DIR"
# No progress-log.json → verify should fail and emit gate.blocked
bash plugins/dev-framework/hooks/scripts/phase-gate.sh verify 2>/dev/null || true
# Check that the event was emitted
bash plugins/dev-framework/hooks/scripts/get-events.sh --type gate.blocked --format count
# Expected: 1
```

- [ ] **Step 4: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/phase-gate.sh
git commit -m "feat(m1): dual-write events in phase-gate.sh"
```

---

## Task 6: Dual-write in `freeze-gate.sh`

**Files:**
- Modify: `plugins/dev-framework/hooks/scripts/freeze-gate.sh`

- [ ] **Step 1: Read current freeze-gate.sh to identify block exit points**

Run: `grep -n 'exit 2' plugins/dev-framework/hooks/scripts/freeze-gate.sh`

- [ ] **Step 2: Source `_session-lib.sh` and emit `gate.blocked` at each block point**

Edit `plugins/dev-framework/hooks/scripts/freeze-gate.sh`:

- Near the top (after the shebang + set command), add:

  ```bash
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=./_session-lib.sh
  . "$SCRIPT_DIR/_session-lib.sh"
  ```

  And replace inline `cfg()`, `sanitize_branch()`, session-dir resolution with the lib versions.

- At each `exit 2` (block) point, before the exit, add:

  ```bash
  bash "$SCRIPT_DIR/emit-event.sh" gate.blocked \
    --actor "hook:freeze-gate" \
    --data "$(jq -cn --arg reason "<specific reason>" --arg path "${EDITED_PATH:-}" \
      '{gate:"freeze",reason:$reason,path:$path}')"
  ```

  Reasons: `"freeze doc not approved"`, `"branch mismatch"`, `"no active session"`, etc. — match the existing echo messages.

- At each successful pass-through (implicit exit 0), emit `gate.passed` only when a src/** edit is actually being gated (not on every non-src edit). Add:

  ```bash
  bash "$SCRIPT_DIR/emit-event.sh" gate.passed \
    --actor "hook:freeze-gate" \
    --data "$(jq -cn --arg path "${EDITED_PATH:-}" '{gate:"freeze",path:$path}')"
  ```

- [ ] **Step 3: Smoke test**

Trigger a freeze-gate block in a test session and run `bash get-events.sh --type gate.blocked`.

- [ ] **Step 4: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/freeze-gate.sh
git commit -m "feat(m1): dual-write events in freeze-gate.sh"
```

---

## Task 7: Dual-write in `push-guard.sh`

**Files:**
- Modify: `plugins/dev-framework/hooks/scripts/push-guard.sh`

- [ ] **Step 1: Source lib and add emits at block/allow points**

Same pattern as Tasks 5–6. Each `exit 2` (block) emits:

```bash
bash "$SCRIPT_DIR/emit-event.sh" gate.blocked \
  --actor "hook:push-guard" \
  --data "$(jq -cn --arg reason "<reason>" '{gate:"push",reason:$reason}')"
```

And the allow path (after `pipeline-complete.md` present, or ticket-scoped bypass):

```bash
bash "$SCRIPT_DIR/emit-event.sh" gate.passed \
  --actor "hook:push-guard" \
  --data '{"gate":"push"}'
```

- [ ] **Step 2: Smoke test + commit**

```bash
git add plugins/dev-framework/hooks/scripts/push-guard.sh
git commit -m "feat(m1): dual-write events in push-guard.sh"
```

---

## Task 8: Dual-write in `sessionend.sh`

**Files:**
- Modify: `plugins/dev-framework/hooks/scripts/sessionend.sh`

- [ ] **Step 1: Source lib, emit session.interrupted + bypass.preserved**

Edit `plugins/dev-framework/hooks/scripts/sessionend.sh`:

- Replace inline helpers with the lib source.
- Inside the `if [ "$CURRENT_STATUS" = "in-progress" ]; then` block, after the jq update to mark interrupted, add:

  ```bash
  bash "$SCRIPT_DIR/emit-event.sh" session.interrupted \
    --actor "hook:sessionend" \
    --data "$(jq -cn --arg at "$TIMESTAMP" \
      --argjson phase "$(jq -r '.currentPhase // 0' "$PROGRESS_LOG")" \
      '{interruptedAt:$at, currentPhase:$phase}')"
  ```

- Inside the bypass-preservation block, after the successful jq append to `bypass-audit.jsonl`, add:

  ```bash
  bash "$SCRIPT_DIR/emit-event.sh" bypass.preserved \
    --actor "hook:sessionend" \
    --data "$(jq -cn --arg at "$BYPASS_AT" --arg runId "$RUN_ID" --arg preservedAt "$PRESERVED_AT" \
      '{at:$at, runId:$runId, preservedAt:$preservedAt}')"
  ```

- [ ] **Step 2: Smoke test + commit**

```bash
git add plugins/dev-framework/hooks/scripts/sessionend.sh
git commit -m "feat(m1): dual-write events in sessionend.sh"
```

---

## Task 9: Dual-write in `precompact.sh`

**Files:**
- Modify: `plugins/dev-framework/hooks/scripts/precompact.sh`

- [ ] **Step 1: Source lib, emit session.precompact**

Edit `plugins/dev-framework/hooks/scripts/precompact.sh`:

- Add lib source at top.
- Before any existing state-preservation logic, emit:

  ```bash
  bash "$SCRIPT_DIR/emit-event.sh" session.precompact \
    --actor "hook:precompact" \
    --data '{"reason":"context truncation imminent"}'
  ```

- [ ] **Step 2: Commit**

```bash
git add plugins/dev-framework/hooks/scripts/precompact.sh
git commit -m "feat(m1): emit session.precompact event"
```

---

## Task 10: `ensure-config.sh` opportunistic DRY

**Files:**
- Modify: `plugins/dev-framework/hooks/scripts/ensure-config.sh`

- [ ] **Step 1: Optional — source lib if it makes ensure-config smaller**

`ensure-config.sh` writes the config file, doesn't resolve session dir. It can optionally source the lib just for `iso_utc` (used in the backup filename), but it's low-value. **Skip** unless further refactor benefit is obvious. Note the skip in the plan as explicitly-decided-against.

- [ ] **Step 2: Mark task complete without changes**

No commit. Record decision in M1 review notes.

---

## Task 11: SKILL.md — emit events at key workflow transitions

**Files:**
- Modify: `plugins/dev-framework/skills/dev/SKILL.md`

**Rationale:** SKILL.md currently prints banners at phase transitions and writes to decision-log/progress-log at key points. Add `emit-event.sh` invocations alongside.

- [ ] **Step 1: Add emit instructions in Pre-Workflow**

In the Pre-Workflow section (between current steps 3 and 4), add:

```markdown
5. **Emit session start event** — `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh session.started --actor orchestrator --data "$(jq -cn --arg mode "$MODE" --arg featureSlug "$FEATURE_SLUG" --arg ticket "$TICKET" '{mode:$mode, featureSlug:$featureSlug, ticket:$ticket}')"`
```

Where `$MODE` etc. are the values the orchestrator would normally record.

- [ ] **Step 2: Add phase.started and phase.completed emits around each phase**

In each Phase N section, after the `phase-gate.sh begin N` call (and before phase work), add:

```markdown
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.started --actor orchestrator --data '{"phase":N}'`
```

And after phase work completion, before the end gate, add:

```markdown
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.completed --actor orchestrator --data "$(jq -cn --argjson phase N --argjson metrics '<metrics>' '{phase:$phase, metrics:$metrics}')"`
```

Do this for Phases 1–7 individually (so that each phase has its own event emission line, not a pattern the orchestrator has to "figure out").

- [ ] **Step 3: Add gate.approved / gate.rejected at GATE 1 and GATE 2**

In the GATE 1 approval path (both interactive and autonomous), add:

```markdown
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh gate.approved --actor orchestrator --data '{"gate":1,"approvalMode":"<interactive|autonomous>","approvedBy":"<identifier>"}'`
```

In the GATE 1 reject path:

```markdown
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh gate.rejected --actor orchestrator --data '{"gate":1,"reason":"<extracted>","returnToPhase":<N>}'`
```

Same pattern for GATE 2.

- [ ] **Step 4: Add consensus.* emits in review-loop-protocol reference**

Edit `plugins/dev-framework/skills/dev/references/autonomous/review-loop-protocol.md`:

After the `ANNOUNCE: "--- Review iteration {iteration}/{MAX_ITERATIONS} ---"` line in the pseudocode, add:

```
EMIT: bash emit-event.sh consensus.iteration.started --actor orchestrator \
      --data '{"phase":N,"iteration":iteration}'
```

Similar additions for when issues are found, fixes applied, and convergence reached. Match the event catalog in `events-schema.md`.

- [ ] **Step 5: Add bypass.created emit in Bypass Protocol**

In the Bypass Protocol section of SKILL.md, after step 1 (writing bypass.json), add step 2.5:

```markdown
2.5. Emit: `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh bypass.created --actor orchestrator --data "$(jq -cn --arg feature "$FEATURE" --arg reason "$REASON" --arg msg "$USER_MSG" '{feature:$feature,reason:$reason,userMessage:$msg}')"`
```

- [ ] **Step 6: Add session.completed emit at GATE 2 successful approval**

In the GATE 2 approval sequence (Phase 7, option 1 or 3), after the pipeline-complete.md write, add:

```markdown
5.5. Emit: `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh session.completed --actor orchestrator --data "$(jq -cn --argjson min "$TOTAL_MINUTES" '{totalMinutes:$min}')"`
```

- [ ] **Step 7: Commit**

```bash
git add plugins/dev-framework/skills/dev/SKILL.md \
        plugins/dev-framework/skills/dev/references/autonomous/review-loop-protocol.md
git commit -m "feat(m1): emit events at SKILL.md workflow transitions"
```

---

## Task 12: End-to-end dual-write integration test

**Files:**
- Create: `plugins/dev-framework/tests/m1/dual-write-integration.test.sh`

- [ ] **Step 1: Write integration verification**

Create `plugins/dev-framework/tests/m1/dual-write-integration.test.sh`:

```bash
#!/bin/bash
# M1 integration test: simulate a minimal pipeline session and verify
# that state-transition events are emitted correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

# Seed a minimal progress-log.json so hooks find state
cat > "$DEVFW_TEST_SESSION_DIR/progress-log.json" <<'JSON'
{
  "schemaVersion": 1,
  "mode": "full-cycle",
  "featureSlug": "test-feature",
  "runId": "run-test-0001",
  "startedAt": "2026-04-20T10:00:00Z",
  "status": "in-progress",
  "currentPhase": 1,
  "phases": []
}
JSON

# Emit a representative sequence manually (simulating what SKILL.md would do)
bash "$HOOKS/emit-event.sh" session.started --actor orchestrator --data '{"mode":"full-cycle","featureSlug":"test-feature"}'
bash "$HOOKS/emit-event.sh" phase.started --actor orchestrator --data '{"phase":1}'
bash "$HOOKS/emit-event.sh" phase.completed --actor orchestrator --data '{"phase":1}'
bash "$HOOKS/emit-event.sh" phase.started --actor orchestrator --data '{"phase":2}'
bash "$HOOKS/emit-event.sh" phase.completed --actor orchestrator --data '{"phase":2}'
bash "$HOOKS/emit-event.sh" gate.approved --actor orchestrator --data '{"gate":1,"approvalMode":"interactive","approvedBy":"test"}'

# Verify queries
PHASE_COUNT=$(bash "$HOOKS/get-events.sh" --type 'phase.*' --format count)
[ "$PHASE_COUNT" = "4" ] || { echo "FAIL: phase.* count != 4 (got $PHASE_COUNT)"; exit 1; }

GATE_APPROVED=$(bash "$HOOKS/get-events.sh" --type gate.approved --format count)
[ "$GATE_APPROVED" = "1" ] || { echo "FAIL: gate.approved count != 1"; exit 1; }

# Verify seq ordering
SEQS=$(jq -r '.seq' "$DEVFW_TEST_SESSION_DIR/events.jsonl" | paste -sd,)
[ "$SEQS" = "1,2,3,4,5,6" ] || { echo "FAIL: seq order wrong ($SEQS)"; exit 1; }

# Verify runId is pulled from progress-log
RUN_IDS=$(jq -r '.runId' "$DEVFW_TEST_SESSION_DIR/events.jsonl" | sort -u)
[ "$RUN_IDS" = "run-test-0001" ] || { echo "FAIL: runId not consistent ($RUN_IDS)"; exit 1; }

echo "PASS: dual-write integration"
```

- [ ] **Step 2: Run the integration test**

Run: `bash plugins/dev-framework/tests/m1/dual-write-integration.test.sh`
Expected: `PASS: dual-write integration`

- [ ] **Step 3: Run all M1 tests**

Run:
```bash
for t in plugins/dev-framework/tests/m1/*.test.sh; do
  echo "--- $t"
  bash "$t" || { echo "TEST FAILED: $t"; exit 1; }
done
echo "ALL M1 TESTS PASSED"
```

Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add plugins/dev-framework/tests/m1/dual-write-integration.test.sh
git commit -m "test(m1): end-to-end dual-write integration test"
```

---

## Task 13: Update CLAUDE.md with event log awareness

**Files:**
- Modify: `plugins/dev-framework/CLAUDE.md`

- [ ] **Step 1: Add "Event Log" section to Session State**

Edit `plugins/dev-framework/CLAUDE.md`:

In the "Session State" table, add rows:

```markdown
| `events.jsonl` | Append-only event stream (M1+); source of truth for state transitions |
| `.seq` | Atomic counter for last emitted event seq |
```

And add a new "Events" subsection under "Session State" with a brief pointer:

```markdown
### Events (M1+)

Every state transition now emits an event to `events.jsonl` alongside existing state files (dual-write). Full catalog: [skills/dev/references/autonomous/events-schema.md](./skills/dev/references/autonomous/events-schema.md). Query with `hooks/scripts/get-events.sh`.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/dev-framework/CLAUDE.md
git commit -m "docs(m1): document event log in CLAUDE.md"
```

---

## Self-Review Checklist

After all 13 tasks, verify against the spec:

**1. Spec coverage:**
- [ ] §3.1 event schema — implemented in Task 4
- [ ] §3.2 three shell primitives — emit-event + get-events done; wake.sh is M2, explicitly deferred
- [ ] §3.3 views — M2, not this plan
- [ ] §7 M1 success criteria: "Every current state transition also appears as an event in events.jsonl" — covered by Tasks 5-11

**2. Placeholder scan:**
- [ ] No TBD, no "similar to task N", no bare "handle X"
- [ ] Every code block is complete and runnable
- [ ] Every filepath is exact

**3. Type consistency:**
- [ ] Event type names match across emit-event callers and events-schema.md
- [ ] Data payload shapes match schema
- [ ] Actor strings consistent (e.g., `hook:freeze-gate` not `freeze-gate-hook`)

**4. Behavior preservation:**
- [ ] No existing exit codes changed
- [ ] No existing file writes removed or modified
- [ ] Every hook's first exit (failure path) still fires same exit code, same stderr message
- [ ] Tests covering existing hook logic still pass (spot-check by running a /dev --status manually)

**5. Dependencies:**
- [ ] jq is already assumed available (CLAUDE.md documents it)
- [ ] mkdir-based locking verified on Windows NTFS (Task 2 concurrent test)

---

## Execution Handoff

When M1 is complete and all tests pass, proceed to write the M2 plan: Views as Projections + wake.sh + replay.sh. M2 will build on the event log and introduce view reducers.
