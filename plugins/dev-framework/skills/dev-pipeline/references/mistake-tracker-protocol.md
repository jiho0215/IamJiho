# Mistake Tracker Protocol

Cross-session learning system. Phase 9 aggregates review findings into reusable patterns that prevent the same mistakes in future runs.

## Phase 3 vs Phase 6/8 Issue Separation

Phase 3 finds **design issues** (plan gaps). Phase 6 and 8 find **code issues** (bugs, convention violations). Phase 9 aggregates only **Phase 6 and Phase 8 issues**. Phase 3 issues are logged for audit but do NOT feed the pattern tracker.

## Pattern Matching Algorithm

Phase 9 matches specific findings to generic patterns. Matching is LLM-driven (not string comparison):

1. For each issue from Phase 6/8, compare against all Known/Chronic patterns
2. **Match criteria:** Same category AND same root cause (strip file-specific details)
3. If match found: increment that pattern's frequency
4. If no match: generalize the issue (remove file/method names), create new pattern with frequency=1
5. Log match decisions to decision-log.json (category: "pattern")

## Pattern Lifecycle

Patterns use **stable IDs** (P1, P2, P3...). Promotion is a status change, not an ID change.

```
Run 1: "Missing XML docs on public methods" found → P1, status=Known, frequency=1
Run 2: Found again → P1 frequency=2
Run 3: Found again → P1 PROMOTED to Chronic (frequency >= config.pipeline.chronicPromotionThreshold)
  → Prevention strategy written → Synced to ~/.claude/CLAUDE.md
  → Decision logged (category: "pattern")
Run 4+: Prevention active → NOT found → Does NOT count as clean run
Run N: If manually removed from prevention AND not found for config.pipeline.cleanRunsForDemotion runs → Resolved
```

## Pattern Quality Rules

- **Generic:** "Missing null check on repository return values" (not "GetUser() in UserService.cs")
- **Actionable:** Clear what to look for and how to prevent
- **Max config.pipeline.maxActivePatterns active** — hard cap enforced

## Storage Structure (in workflow_mistake_patterns.md)

```markdown
## Chronic Patterns (frequency >= threshold)
| ID | Pattern | Category | Frequency | Last Seen | Prevention Strategy |

## Known Patterns (frequency 1-2)
| ID | Pattern | Category | Frequency | Last Seen |

## Resolved Patterns
| ID | Pattern | Category | Peak Frequency | Resolved Since |

## Run Log
| Run | RunId | Date | Ticket | Issues Found | New Patterns | Chronic Triggered |
```

## CLAUDE.md Sync (Sentinels)

After updating workflow_mistake_patterns.md:

1. Read current chronic patterns table
2. If chronic patterns exist, write between sentinel markers:
   ```
   {config.sentinels.begin}
   ## Chronic Coding Patterns
   When writing or reviewing code, proactively prevent these recurring issues:
   - P3: {pattern} — {prevention}
   {config.sentinels.end}
   ```
3. If no chronic patterns: remove everything between sentinels (inclusive)
4. **Preserve all content outside the sentinels**
5. **Atomic write with safe validation:**
   a. Copy current CLAUDE.md to CLAUDE.md.backup
   b. Write new content to CLAUDE.md.tmp
   c. Validate CLAUDE.md.tmp: verify both sentinels present, content not empty
   d. If validation passes: rename .tmp → CLAUDE.md, delete .backup
   e. If validation fails: keep .backup, delete .tmp, report error
   f. If rename fails (Windows file lock): retry once after 1s

## Hard Cap Enforcement

If Known + Chronic count exceeds config.pipeline.maxActivePatterns:
1. Sort Known by frequency (ascending), then last_seen (oldest first)
2. Demote lowest-priority Known to Resolved until count <= cap
3. If all Chronic: demote oldest Chronic (by last_seen) for **at most 1** new Known per run

**Precedence for N new issues > available slots:**
- Steps 1-2 first (demote Known)
- Step 3 once (at most 1 Chronic demotion)
- Remaining new issues: logged in pipeline-issues.json but do NOT create new patterns this run

## Demotion Rules

**Clean run definition:** Pattern was NOT in prevention checklist AND NOT found in any review phase.

**Why:** If prevention is active and working, that's not evidence the pattern is resolved — it's evidence prevention works.

**Chronic demotion (two routes):**
1. **Manual:** Developer removes from prevention checklist. After config.pipeline.cleanRunsForDemotion consecutive clean runs → Resolved.
2. **Hard cap overflow:** Emergency valve when all slots are Chronic. Logged as warning.

## Idempotency

Phase 9 checks the Run Log table before aggregation:
- If current runId already appears in Run Log → skip aggregation
- Otherwise → aggregate, then append runId to Run Log after writing
