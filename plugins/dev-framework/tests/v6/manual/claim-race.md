# Two-machine claim race (A9, manual)

Proves the create-only claim (`bin/claim`) picks exactly one winner when two real machines race over the network.
The single-machine race (A2) cannot show this. The script is `acceptance/a9-two-machine.mjs`; `acceptance/run.sh` never runs it.

## Prerequisites (both machines)
- `git`, `gh` (logged in with write access to the sandbox repos), `node`, `bash`, `jq`, and a checkout of this plugin.
- Env, same on both machines (the names are the sandbox repos, `owner/name`; they are never written into a file):
  `DEVFW_SANDBOX_CORE=<sandbox core repo>`, `DEVFW_SANDBOX_CODE=<sandbox code repo>`.
  The script refuses to write unless the core repo carries the `DEVFW_SANDBOX` marker listing the code repo.
- The code repo's `main` branch exists (the default `--base`). The script clones it fresh into a temp dir; no other path is used.
- The two machines have different hostnames (the winner is read from the claim's `Claim-Machine` trailer, which is the hostname).
- Clocks agree to about a second (NTP on). The start time is compared with each machine's own clock.

## Namespace (cannot collide with acceptance runs)
Acceptance runs use issue numbers from GitHub and slugs like `race`. This procedure uses issue numbers in the 9,000,000+ range
and a slug that starts with `race-<date>`, for example `race-20261201`. Use a new slug for every attempt: a claim is permanent,
so a reused slug makes every round "lost" on both machines.
Round k claims issue `<issue>+k-1` with branch `t/<issue+k-1>-<slug><k>`: one issue allows one claim whatever the slug,
so each round needs its own issue number.

## Procedure
1. Agree a start time in UTC about 2 minutes ahead, as `HH:MM:SS` (e.g. `14:05:00`). Check with `date -u`.
2. On both machines, from `plugins/dev-framework/tests/v6/acceptance/`, run the same command:
   `node a9-two-machine.mjs --issue 9000100 --slug race-20261201 --at 14:05:00 --rounds 5`
   It clones, sleeps until the start time, then runs one claim per round, 30 s apart (`--gap` changes it). Each round prints one JSON line:
   `result` is `claimed` (this machine won) or `lost` (the other did), with the exit code.
3. When both have finished, run on either machine (or both):
   `node a9-two-machine.mjs --verify --issue 9000100 --slug race-20261201 --rounds 5`
   It reads each round's ref and prints the winning machine from the `Claim-Machine` trailer, then a final `verified` line.

## Pass
- In every one of the 5 rounds exactly one machine printed `claimed` and the other `lost` (no `error`, no both-claimed, no both-lost).
- `--verify` prints `"verified":true` and a winner for all 5 rounds, and each round's winner is the machine that printed `claimed`.
- Seeing the same machine win all 5 rounds is not a failure; seeing no round where the machines collided in the same second is a weak run, so repeat with a nearer start time.

## Record the result
Write the outcome (date, the two hostnames, per-round winners, pass/fail) in the design doc's section 9, Q1 (owner's private docs).
That closes Plan 1 Task 6 at the same time.

## Clean up
The branches stay in the sandbox code repo (its own namespace). Nothing else is created.
