# PR #1 — Auto-detect test command (enhancement D)

**Target:** `jiho0215/IamJiho` — dev-framework plugin
**Affects:** `skills/dev-pipeline/SKILL.md` (Pre-Pipeline step 2), hook config defaults
**Priority:** First — smallest, highest win, no dependencies
**Backward compatible:** Yes (behavior falls back to current default if no signal found)

## Problem

`config.json` defaults to `hooks.testCapture.testCommand: "dotnet test"`. This is wrong for every non-.NET project. Users must override manually, or the test-failure-capture hook silently skips.

CLAUDE.md acknowledges this as a known issue.

## Proposed change

In `Pre-Pipeline` bootstrap (when `config.json` is missing or needs creation), scan the current working directory for project-type signals and set `hooks.testCapture.testCommand` accordingly:

| Signal file | testCommand default |
|---|---|
| `*.csproj` or `*.sln` | `dotnet test` |
| `package.json` with `scripts.test` | `npm test` |
| `package.json` with `scripts.test:ci` | `npm run test:ci` |
| `pyproject.toml` or `setup.cfg` or `pytest.ini` | `pytest` |
| `Cargo.toml` | `cargo test` |
| `go.mod` | `go test ./...` |
| `build.gradle`/`build.gradle.kts` | `./gradlew test` |
| `pom.xml` | `mvn test` |

Priority order if multiple match: first signal found wins. Generated config includes a comment (or if JSON, a sibling `_testCommand_source` key) noting how it was detected.

If NO signal found → fall back to `dotnet test` (current behavior) but emit a one-line warning: `"No project-type signal detected. Defaulting to 'dotnet test'. Override in config.json."`

## Also needed

Update `hooks/hooks.json` so the test-capture hook's `if:` matcher is configurable (reads `hooks.testCapture.testCommand` value), rather than hardcoded `Bash(dotnet test *)`. Otherwise the config change still doesn't route failures. Rough sketch:

```json
{
  "PostToolUse": [
    {
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/test-failure-capture.sh",
        "ifConfig": "hooks.testCapture.testCommand",
        "timeout": 1
      }]
    }
  ]
}
```

If `ifConfig` isn't supported, add a script-side check: `test-failure-capture.sh` reads `hooks.testCapture.testCommand` and early-returns unless the invoked bash command contains that substring.

## Test plan

- Unit test: detector function returns correct testCommand for each fixture project-type
- Integration test: create config in temp dir with `.csproj` present → verify `dotnet test` detected
- Integration test: create config in temp dir with `package.json` and `scripts.test` → verify `npm test` detected
- Integration test: empty temp dir → verify fallback + warning

## Rollout

- No migration needed; only affects NEW config creation
- Existing users with explicit `testCommand` values are untouched
- Can ship behind no flag (additive)
