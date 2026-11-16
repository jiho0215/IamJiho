# Task 6 report: merge-gate + pr-size --files

Built: lib/gate.js (checkCi, checkCites, checkEvidence, checkSize, checkCoverage, evaluate, run, evidenceBlock, linkedIssue, currentPlanHashes), thin bin/merge-gate, pr-size --files (planned shape or GitHub pulls/<n>/files shape; limit = full budget; renamed 0/0 scores nothing), tests (14 node cases in merge-gate.test.mjs; 4 new pr-size cases).

Design: each check returns a reasons array; evaluate gives {pass, checks:{ci,cites,evidence,size,coverage}, reasons}; coverage is null when not enforced. checkCites judges against a Map (evaluate fetches origin/<plan.branch> first, O6). Ack check passes the CURRENT hash to ackCovers (the ack's sha must hash the item to it). Statuses count as attached CI; combined-state "pending" with zero statuses is not read as pending. Never writes (every test asserts no non-GET call). Exit 0/6/2.

TDD: RED (pr-size): `FAIL: files-gh: .seconds = , want 395` / "unknown argument: --files". RED (gate): `Error: Cannot find module '../../../lib/gate.js'` (gate.js was moved aside to record it; I had written it before the test file, so RED was reproduced by removal, not observed first). GREEN: 14/14 pass; pr-size.test.sh ok.
Mutation: zero runs on ci:required returns [] -> `✖ Review Focus 4 ...` is the only failure (13 pass, 1 fail). Restored; green. Full run.sh: all PASS.

Concerns: merge-gate tests are slow (~100s; each planHashes spawns bash on Windows). A ci:none repo with an empty tests list passes zero-run CI vacuously. Evidence block detection requires a line starting with `Evidence:` (optionally bullet/heading/bold).

## Fix round 1 (gate fails closed)
Command (each RED and GREEN): `cd plugins/dev-framework/tests/v6/node && node --test --test-name-pattern="fix[123]" merge-gate.test.mjs`
- fix1 fetch failure: test points origin at a non-existent path with matching cites. RED: `✖ fix1 ...` (AssertionError). Fix: currentPlanHashes returns null when `git fetch` fails; checkCites returns `cites: plan fetch failed`. GREEN.
- fix2 ci:none with empty/missing tests: RED `✖ fix2 ...`. Fix: zero-run ci:none refuses with `ci: no test commands configured for ci:none repo`. GREEN.
- fix3 malformed cite (`P-0-4@abc`, non-hex 12 chars, `P-0-4`): RED `✖ fix3 ... P-0-4@abc`. Fix: new `parseCitesStrict` in ticket-body.js returning {cites, malformed}; gate refuses `cites: malformed entry <raw>`. `parseCites` untouched (test asserts its lenient output). GREEN.
Regression: merge-gate + ticket-sync + reconcile node tests 41 pass / 0 fail; full `bash plugins/dev-framework/tests/v6/run.sh` all PASS.
Not mutation-verified individually beyond RED-then-GREEN on new tests.
