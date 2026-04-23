# Review: `FriendRequestServiceTests.cs`

This file violates multiple rules in the testbuilder **HYGIENE** standard (`references/standards/HYGIENE.md`). Every one of the three `[Skip]`-gated tests is an empty shell, and the two non-skipped tests have their own problems. The net effect is **false coverage inflation**: five `[Fact]` entries suggest `FriendRequestService` has meaningful test coverage, but only one test actually exercises a behavior — and even that one is unverifiable as written.

Below, each problem is mapped to the specific HYGIENE rule it breaks, with the required fix.

---

## Issue 1 — `SendFriendRequest_Exactly48HoursAfterReject_Succeeds` (empty skipped shell + false claim)

```csharp
[Fact(Skip = "DateTime comparison issue with InMemory DB - verified in integration tests")]
public async Task SendFriendRequest_Exactly48HoursAfterReject_Succeeds()
{
    // This test requires real DB for accurate DateTime comparison
    // In-Memory DB doesn't handle DateTime.UtcNow.AddHours(-48) correctly
}
```

**Rules violated:**

- **Rule 1 (No empty test shells)** — body is comments only. No arrange/act/assert.
- **Rule 2 (Skip contract)** — no tracking link, no exit criterion.
- **Rule 3 (Skip message truthfulness — grep test)** — the message claims "verified in integration tests", but the user has already run `grep -rn "SendFriendRequest_Exactly48HoursAfterReject" Buckit.Services.IntegrationTests/` and found **zero matches**. The claim is a lie. This is the canonical coverage-inflation pattern HYGIENE Rule 3 exists to catch.
- **Rule 4 (Tier escalation before skip)** — the reason given ("In-Memory DB doesn't handle DateTime correctly") is precisely the "real DB needed" case that Rule 4 requires be **escalated to the integration tier, not skipped at the unit tier**.

**Fix:** Delete this test from the unit project and write it in `Buckit.Services.IntegrationTests` against a real SQL Server (Docker/Testcontainers), with explicit arrange (seed a rejected friend request with `RejectedAt = UtcNow.AddHours(-48)`), act (call `SendFriendRequestAsync`), assert (result is success). Until that integration test actually exists, **do not leave the skipped stub behind** — a missing test is more honest than a lying skip.

---

## Issue 2 — `SendFriendRequest_ToBlockedUser_ReturnsError` (empty skipped shell, no contract)

```csharp
[Fact(Skip = "TODO: fix later")]
public async Task SendFriendRequest_ToBlockedUser_ReturnsError() { }
```

**Rules violated:**

- **Rule 1** — empty body.
- **Rule 2** — `"TODO: fix later"` is explicitly listed in the HYGIENE forbidden-patterns table ("No tracking, no exit criterion"). This is a textbook violation.

**Fix:** This is a blocked-user authorization case — critical security behavior. Write it now as a real unit test. All dependencies (repo + any external checks) can be mocked, so it belongs in the unit tier. Example shape:

```csharp
[Fact]
[Trait("Category", "Unit")]
public async Task SendFriendRequest_ToBlockedUser_ReturnsError()
{
    var repo = Substitute.For<IFriendRepository>();
    repo.IsBlockedAsync(userA, userB).Returns(true);
    var service = new FriendRequestService(repo, Substitute.For<IClock>());

    var result = await service.SendFriendRequestAsync(userA, userB);

    Assert.False(result.IsSuccess);
    Assert.Equal(FriendRequestError.Blocked, result.Error);
}
```

---

## Issue 3 — `SendFriendRequest_Concurrent_HandlesCorrectly` (flake-quarantined without contract)

```csharp
[Fact(Skip = "flaky")]
public async Task SendFriendRequest_Concurrent_HandlesCorrectly() { }
```

**Rules violated:**

- **Rule 1** — empty body.
- **Rule 2** — `"flaky"` with no tracking link is explicitly forbidden ("No SLA, no owner, no plan").
- **Rule 8 (Deterministic or explicitly quarantined)** — quarantining without a tracking entry is forbidden because "retries mask regressions".
- **Rule 4** — concurrency behavior (advisory locks, DB-level race conditions) cannot be meaningfully tested in the unit tier. It must be **escalated to integration** with a real SQL Server so the row-level locking semantics actually run.

**Fix:** Delete the skipped shell. Write the concurrent test in the integration project using Docker SQL Server, spawning parallel `SendFriendRequestAsync` calls and asserting exactly one succeeds. If genuinely flaky after that, open a tracking issue and record it in `TESTING.md` Known Gaps per HYGIENE Rule 6 with tier/tracking/exit-criterion/last-reviewed fields — not as a bare `Skip = "flaky"`.

---

## Issue 4 — `Service_CanBeConstructed` (coverage-inflating non-test)

```csharp
[Fact]
public async Task Service_CanBeConstructed()
{
    var service = new FriendRequestService(null!, null!);
    Assert.NotNull(service);
}
```

**Rules violated:**

- **Rule 7 (No false coverage inflation)** — explicitly lists "Tests that only assert the constructor didn't throw" as forbidden.
- Passing `null!` for both dependencies also makes this actively misleading: if the constructor ever adds a null-guard, the test breaks for a reason unrelated to real behavior.
- It is also marked `async Task` with no `await`, so it would raise a compiler warning (CS1998).

**Fix:** Delete it. Constructor-no-throw is not a behavior users care about; real tests exercise the service's methods, which implicitly prove construction works.

---

## Issue 5 — `SendFriendRequest_HappyPath_Succeeds` (the only real test, but unverifiable)

```csharp
[Fact]
public async Task SendFriendRequest_HappyPath_Succeeds()
{
    var service = BuildService();
    var result = await service.SendFriendRequestAsync(userA, userB);
    Assert.True(result.IsSuccess);
}
```

Problems:

- `BuildService()`, `userA`, and `userB` are undefined in the file as shown — the code will not compile. Either these come from a missing base class / shared helper (not visible here), or the test is broken.
- **Rule 8 (Deterministic)** — with no visible arrange (what state is the mocked repo in? what does `userA` look like?), the happy-path assertion is not reproducible by a reader. A reviewer cannot tell whether the test would still pass if the repo accidentally returned a rejection.
- No `[Trait("Category", "Unit")]`, breaking the tier-filter consistency required in Phase 3 / Phase 6 CI wiring.

**Fix:** Make the arrange explicit in the test body (or in a clearly-named helper whose setup is obvious), assert on more than just `IsSuccess` (e.g., the repo received a `Create` call with the expected payload), and add the `[Trait("Category", "Unit")]` attribute.

---

## Summary of required changes

| Test | Action |
|---|---|
| `SendFriendRequest_Exactly48HoursAfterReject_Succeeds` | **Delete** from unit project; **write** as integration test against Docker SQL. Remove the false "verified in integration tests" claim. |
| `SendFriendRequest_ToBlockedUser_ReturnsError` | **Write** as a real unit test with mocked repo. Drop the `"TODO: fix later"` skip. |
| `SendFriendRequest_Concurrent_HandlesCorrectly` | **Delete** unit-tier shell; **write** as integration test with real concurrent execution. If later flaky, record in `TESTING.md` Known Gaps with tracking link + SLA. |
| `Service_CanBeConstructed` | **Delete**. Constructor-only tests are explicitly forbidden (Rule 7). |
| `SendFriendRequest_HappyPath_Succeeds` | **Rewrite** with explicit, readable arrange; assert on observable behavior beyond `IsSuccess`; add `[Trait("Category", "Unit")]`. |

## Headline finding

The file currently **lies about coverage**. The claim "verified in integration tests" in the 48-hour skip is demonstrably false — the user's grep confirmed zero matches in `Buckit.Services.IntegrationTests`. Per HYGIENE Rule 3, that is a coverage lie and the skip is invalid. Combined with three empty shells and a no-op constructor test, `FriendRequestService` has effectively **one** real test (the happy path) dressed up as five. Until the three escalated integration tests actually exist in `Buckit.Services.IntegrationTests`, the honest state of this suite is "one happy-path unit test" — and the file should say so.
