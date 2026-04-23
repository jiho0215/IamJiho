# Review: `FriendRequestServiceTests.cs`

## Summary

This file claims to cover `FriendRequestService`, but in practice it exercises almost nothing. Three of the five tests are skipped, one is a trivial constructor smoke test, and the only substantive test (`SendFriendRequest_HappyPath_Succeeds`) references undefined symbols and will not compile. Combined with the fact that the referenced "integration tests" do not actually exist (grep returns zero matches for `SendFriendRequest_Exactly48HoursAfterReject` in `Buckit.Services.IntegrationTests`), this file gives a false sense of test coverage.

---

## Critical issues

### 1. Skip reasons are misleading or non-actionable

All three `Skip` attributes fail basic skip-hygiene standards. A skip reason must be (a) truthful, (b) specific, and (c) point to something actionable (tracking issue, linked test elsewhere, concrete follow-up).

#### 1a. `SendFriendRequest_Exactly48HoursAfterReject_Succeeds`

```csharp
[Fact(Skip = "DateTime comparison issue with InMemory DB - verified in integration tests")]
```

- **The claim is false.** Grep across `Buckit.Services.IntegrationTests` returns zero matches for `SendFriendRequest_Exactly48HoursAfterReject`. The referenced integration coverage does not exist.
- **The technical justification is also wrong.** EF Core InMemory handles `DateTime.UtcNow.AddHours(-48)` perfectly well — it is in-process CLR arithmetic, not a provider feature. If the real problem is provider-specific date truncation or time-zone handling, the test should use SQL Server / `MsSqlContainer` (the repo already has whitebox integration tests in `buckitApi/`), not be silently disabled.
- **Fix:** Either
  1. Move this test into `buckitApi/` integration tests using `MsSqlContainer` and delete the skip, or
  2. Keep it as a unit test with `FakeTimeProvider` / an injected `IClock` so the 48-hour boundary is deterministic without any DB, or
  3. If it must stay skipped, the skip reason must link to the *actual* integration test by fully-qualified name (`Buckit.Services.IntegrationTests.FriendRequestTests.Send_Exactly48HoursAfterReject`) so the claim is verifiable.

#### 1b. `SendFriendRequest_ToBlockedUser_ReturnsError`

```csharp
[Fact(Skip = "TODO: fix later")]
```

- **"TODO: fix later" is not a skip reason.** It has no owner, no ticket, no date, no description of what is broken. In practice this becomes permanent dead code.
- **Blocked-user behavior is security-adjacent** (authorization boundary). Leaving it unverified is a real risk, not a cosmetic one.
- **Fix:** Either implement it now (the test body is empty — writing it is less work than the skip comment), or replace the skip with `[Fact(Skip = "Tracked in BUCK-####: implement block-list check in FriendRequestService")]` so it shows up in sprint triage.

#### 1c. `SendFriendRequest_Concurrent_HandlesCorrectly`

```csharp
[Fact(Skip = "flaky")]
```

- **"flaky" is a symptom, not a reason.** It tells future maintainers nothing about *why* it is flaky (race condition in the test, race in production code, shared state between tests, DB isolation level, etc.).
- **A flaky concurrency test may be revealing a real concurrency bug in `FriendRequestService`.** Silently skipping it hides a potentially shipping defect. The repo uses advisory locking (per `CLAUDE.md`), so concurrent friend-request handling is exactly the kind of thing that needs test coverage.
- **Fix:** Reproduce the flake, root-cause it, and either (a) fix the production code if the race is real, or (b) rewrite the test to be deterministic (e.g., use `TaskCompletionSource` handoffs instead of `Task.WhenAll` with sleeps). Do not merge a `Skip = "flaky"` — that is how races reach production.

### 2. `Service_CanBeConstructed` is a worthless test

```csharp
var service = new FriendRequestService(null!, null!);
Assert.NotNull(service);
```

- Passing `null!` to the constructor proves only that the constructor does not null-check its arguments, which is itself a code smell worth flagging.
- `Assert.NotNull(service)` on a just-constructed reference is tautological — `new T(...)` cannot return null.
- It is `async Task` but contains no `await`, which will produce a CS1998 warning and signals the author copy-pasted without thinking.
- **Fix:** Delete this test. If you want a wiring test, write one that actually resolves `FriendRequestService` from the DI container and asserts its dependencies are satisfied.

### 3. `SendFriendRequest_HappyPath_Succeeds` will not compile

```csharp
var service = BuildService();
var result = await service.SendFriendRequestAsync(userA, userB);
```

- `BuildService()`, `userA`, and `userB` are never declared in the file. Either this file has never been compiled, or code was deleted without running the test project.
- **Fix:** Add the missing test infrastructure:

  ```csharp
  private static readonly Guid UserA = Guid.NewGuid();
  private static readonly Guid UserB = Guid.NewGuid();

  private static FriendRequestService BuildService(/* fakes */) { ... }
  ```

  And actually assert something meaningful beyond `IsSuccess` — e.g., that a `FriendRequest` row was persisted, that a notification was enqueued, and that calling it twice does not produce duplicates.

### 4. Every test method is `async Task` but several never `await`

`Service_CanBeConstructed` and all three skipped tests are `async Task` with no `await`. This produces CS1998 warnings and is misleading. Empty/synchronous tests should be plain `void` / `Task.CompletedTask`-returning, or have real async bodies.

### 5. The test class violates AAA structure in the only real test

`SendFriendRequest_HappyPath_Succeeds` has AAA comments but one line per section — there is no arrangement (no fakes set up, no inputs configured), no meaningful act (inputs are undefined), and no real assertion (only `IsSuccess`, not the resulting state). A happy-path test should prove the *effect*, not just a boolean return.

---

## What the coverage actually is

| Behavior                              | Covered? |
| ------------------------------------- | -------- |
| Constructor doesn't throw on nulls    | Yes (but meaningless) |
| Happy-path send                       | No — test doesn't compile |
| 48-hour cooldown boundary             | **No** — skipped, claimed integration test does not exist |
| Blocked-user rejection                | **No** — skipped with "TODO" |
| Concurrent send handling              | **No** — skipped as "flaky" |

Effective coverage of `FriendRequestService`: **zero**.

---

## Recommended actions (in order)

1. **Delete `Service_CanBeConstructed`** — tautological.
2. **Make `SendFriendRequest_HappyPath_Succeeds` compile and actually assert persisted state.**
3. **Verify the integration-test claim.** Since grep shows it does not exist, either (a) write the integration test in `buckitApi/` and link it by FQN in the skip reason, or (b) un-skip the unit test and make it deterministic with an injected clock.
4. **Replace `"TODO: fix later"` with a tracked ticket or implement the test** — blocked-user logic is authorization-critical.
5. **Investigate the "flaky" concurrency test before shipping any more friend-request changes** — given advisory locking is used elsewhere in the codebase, a flaky concurrency test likely indicates a real race.
6. **Add a skip-hygiene lint rule or analyzer** so `Skip = "flaky"` / `Skip = "TODO"` / `Skip = "..."` without a ticket reference fails CI. Skip reasons must cite a ticket ID or the FQN of a replacement test.
