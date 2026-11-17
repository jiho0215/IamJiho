# Two-machine claim race (A9, manual)

Proves the create-only claim (`bin/claim`) picks exactly one winner when two real machines race over the network.
The single-machine race (A2) cannot show this. The script is `acceptance/a9-two-machine.mjs`; `acceptance/run.sh` never runs it.

## Prerequisites (both machines)
- `git`, `gh` (logged in with write access to the sandbox repos), `node`, `bash`, `jq`, and a checkout of this plugin.
- Env, same on both machines (the names are the sandbox repos, `owner/name`; they are never written into a file):
  `DEVFW_SANDBOX_CORE=<sandbox core repo>`, `DEVFW_SANDBOX_CODE=<sandbox code repo>`.
  The script refuses to write unless the core repo carries the `DEVFW_SANDBOX` marker listing the code repo.
- The code repo's `main` branch exists (the default `--base`). The script clones it fresh into a temp dir; no other path is used.
- Both machines use a checkout of the same plugin commit (the claim output carries `lostAt`; older checkouts lack it).
- The two machines have different hostnames (the winner is read from the claim's `Claim-Machine` trailer, which is the hostname).
- Clocks agree to about a second (NTP on). The start time is compared with each machine's own clock.

## Namespace (cannot collide with acceptance runs)
Acceptance runs use issue numbers from GitHub and slugs like `race`. This procedure uses issue numbers in the 9,000,000+ range
and a slug that starts with `race-<date>`, for example `race-20261201`.
A claim is per ISSUE, whatever the slug: once any `t/<issue>-*` branch exists, every later claim on that issue loses at once.
So every attempt, including a retry, needs a FRESH ISSUE RANGE that no earlier attempt used (a new `--issue` base, e.g. the last
base + 100), plus a fresh slug. A retry with only a new slug loses every round before any push.
Round k claims issue `<issue>+k-1` with branch `t/<issue+k-1>-<slug><k>`. The first attempt below uses base 9000100 (rounds 9000100..9000104);
a second attempt would use 9000200, a third 9000300.

## Procedure
1. Agree a start time in UTC about 2 minutes ahead, as `HH:MM:SS` (e.g. `14:05:00`). Check with `date -u`; sync both clocks first.
2. On both machines, from `plugins/dev-framework/tests/v6/acceptance/`, run the same command, saving the output to a file named for the machine:
   `node a9-two-machine.mjs --issue 9000100 --slug race-20261201 --at 14:05:00 --rounds 5 | tee machine-<name>.jsonl`
   It clones, sleeps until the start time, then runs one claim per round, 30 s apart (`--gap` changes it). Each round prints one JSON line with
   `startedAt` (UTC ms when the claim was launched), `result` (`claimed` = this machine won, `lost`), `lostAt`, `heldBy` (for a loser:
   the hostname on the ref it lost to), `issue`, `branch` and the hostname.
   `lostAt` is `precheck` when the loser saw the winner's branch already on origin (it ran after the winner: no race), and `push`
   when the loser's create-only push was rejected (a real collision).
3. Copy one machine's file to the other, then run on either machine:
   `node a9-two-machine.mjs --compare machine-a.jsonl machine-b.jsonl`
   It needs no network. Per round it prints the winner, the start skew in ms between the two machines, and whether the round `raced`
   (the loser lost at the push AND the ref it lost to is held by the other machine, per the loser's `heldBy`). The last line is the verdict.
   Both files must come from the same attempt: every round must name the same issue and the same branch in both, and no round may
   appear twice in one file. Otherwise the verdict is ERROR.
4. Optional: `node a9-two-machine.mjs --verify --issue 9000100 --slug race-20261201 --rounds 5` reads each round's ref from origin and prints the
   winner from the `Claim-Machine` trailer. Its winners must match the `--compare` winners.

## Verdicts
- **VERIFIED**: every round has exactly one winner AND at least 3 rounds raced at the push. This is the pass.
- **INCONCLUSIVE**: one winner every round, but fewer than 3 rounds reached the push. The loser mostly arrived after the winner had finished,
  so the atomic push was not exercised. Look at the skew numbers: a large skew (hundreds of ms or more, or seconds) means the clocks disagree;
  sync both clocks (NTP), pick a nearer start time, and rerun on a FRESH issue range (see Namespace). This is not a failure of the claim.
- **FAILED**: some round has two winners, no winner, or no clean loser (an `error` result or a missing round). Two winners is a real
  defect: keep both files and report it. No winner usually means the issue range was reused (the ref already existed): rerun on a fresh range.
- **ERROR** (exit 2): the two files carry the same hostname (the winner cannot be told apart), a round names a different issue or branch
  in the two files, or a round appears twice in one file. The files are not two halves of one attempt.
Exit codes of `--compare`: 0 VERIFIED, 4 INCONCLUSIVE, 1 FAILED, 2 ERROR.

## Record the result
Write the outcome (date, the two hostnames, the verdict, per-round winners and skews) in the design doc's section 9, Q1 (owner's private docs).
That closes Plan 1 Task 6 at the same time. Also write down the issue base used, so the next attempt picks a new one.

## Clean up
The branches stay in the sandbox code repo (its own namespace). Nothing else is created.
