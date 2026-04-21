# Worktree Orchestration (M4+)

How to use multi-brain parallelism safely with the M1-M3 event infrastructure.

## Three levels of parallelism

1. **Intra-phase agent fan-out** (since M0) — `multi-agent-consensus` dispatches 3 agents in parallel via the Task tool. Each agent is a separate Claude instance. Shared context comes from the orchestrator's turn.
2. **Intra-phase parallel invocations** (M4 advisory) — a phase YAML's `invokes[]` may mark steps `parallel: true`. The orchestrator dispatches them concurrently; each emits `tool.call.*` events. `execute.sh` does not enforce ordering; it's an orchestrator-level advisory.
3. **Inter-session fan-out** (M4 new) — `fan-out.sh` spawns a child session dir, optionally sharing `events.jsonl`. The orchestrator (or a scheduled task) can launch a side workflow without polluting the main pipeline.

## Safety guarantees

- **Seq atomicity.** `emit-event.sh` uses mkdir-based locking. 50+ parallel writers validated in `tests/m4/concurrency-stress.test.sh`. No duplicate or missing seqs observed. Lock budget tunable via `DEVFW_EMIT_LOCK_MAX_TRIES` (default 600 = 30s at 50ms polling).
- **Total order within a session.** seq is strictly monotonic. Cross-actor ordering is total but not deterministic — don't encode "agent A emits before agent B" as a dependency; use event content instead.
- **Cattle-not-pets children.** A child session folder can be deleted at any time without affecting the parent. When `--share-events` creates a real link, child emits appear in the parent log tagged with the child's actor name.

## Platform caveat: Windows symlinks

`fan-out.sh --share-events` on Windows git-bash requires Developer Mode (or admin elevation) to create real symlinks. Without it, `ln -s` silently creates a copy — fan-out.sh detects this via `[ -L ]` and falls back to hardlink, then to a one-way copy with a WARNING. Cross-volume links always fall back. If true sharing is critical, run on Linux/Mac or enable Developer Mode.

## When to fan out

Use **inter-session fan-out** when:
- You need an isolated workspace (scratch diffs, alternate exploration) that shouldn't pollute the main session.
- You want to branch-at-point (`replay.sh` to a past seq, then emit alternative paths) without disturbing the live session.

Use **intra-phase parallel invocations** when:
- Multiple independent skills/protocols are needed and their outputs don't interact (Phase 2's exploration + architecture, for example).
- Latency matters more than simplicity.

Do **not** fan out when:
- Steps have data dependencies (output of A is input to B).
- Concurrent brains would race on the same `src/**` paths (freeze-gate serializes mutations at the file level, but racing brains can still produce logically-conflicting diffs).
- The orchestrator can't reason about N outputs in its own context (rare, but cap at 3-5 parallel branches for human-reviewable fan-out).

## fan-out.sh reference

```bash
hooks/scripts/fan-out.sh --name NAME [--target-dir DIR] [--share-events]
```

Output (stdout): absolute path to child session dir.

Parent-side event: `fan-out.spawned {childDir, name, shared}`.

Child progress-log inherits parent's `runId` (for correlation) and sets `mode: fan-out-child`.

## Fan-in pattern

```bash
# Parent creates a shared-event child
CHILD=$(bash hooks/scripts/fan-out.sh --name exploration --share-events)

# Orchestrator dispatches a Task subagent with working_dir=$CHILD.
# The subagent uses emit-event.sh in its execution; emits append to the
# shared log (symlinked), so the parent sees them.

# After subagent returns:
bash hooks/scripts/get-events.sh --actor 'agent:exploration-*' --since-seq $PARENT_LAST_SEQ
```

## Phase YAML `parallel` support (advisory)

A phase YAML may mark individual `invokes[]` entries:

```yaml
invokes:
  - kind: skill
    config: pipeline.skills.exploration
    parallel: true
  - kind: skill
    config: pipeline.skills.architect
    parallel: true
```

The orchestrator interprets consecutive `parallel: true` entries as a group and dispatches them concurrently, waits for all, continues. `execute.sh` does not enforce this — compliant orchestrators emit `tool.call.started` events with a `groupId` in `data` so the events can be traced as a batch.

## Limits

- **Git worktree cap.** Git supports many worktrees but each creates a working directory — disk pressure matters for very large repos. Prefer fan-out *without* worktree when git isolation isn't needed (session-folder-only fan-out).
- **Claude rate limits.** Multi-brain means more API calls concurrently. Respect your plan's parallel call limit.
- **No cross-session message bus.** Children and parent communicate only through shared events (when `--share-events`). No RPC, no direct messaging. This is intentional: event log is the single communication channel.
- **Lock contention at scale.** Mkdir-based locks scale to ~50 concurrent writers on Windows git-bash in our testing. For 100+, consider batching emits (one parent per subagent, not one per subagent-action).

## Failure modes

| Failure | Detection | Recovery |
|---|---|---|
| Child session corrupted | `wake.sh` against child returns `status: "unknown"` | Delete child dir, re-run `fan-out.sh` |
| Symlink silently became copy (Windows) | fan-out.sh WARNING to stderr | Accept copy-mode or enable Developer Mode |
| Lock starvation (>600 tries) | `emit-event.sh` exits 1 with lock error | Increase `DEVFW_EMIT_LOCK_MAX_TRIES` or reduce parallelism |
| Parent deleted while child active | Child emits fail (parent events.jsonl gone in share mode) | No recovery — fan-out assumes parent is stable during child lifetime |

## Design note: why mkdir-lock?

`mkdir` is atomic on every major filesystem (POSIX and NTFS) and doesn't require an `flock`-compatible FS. That makes it a portable primitive where Windows git-bash, Linux ext4, macOS APFS all behave identically. The trade-off is polling overhead (50ms sleep per retry), capped at 30 seconds. For the event rates our workflow generates (<1 event/second per brain), this is more than adequate.
