# Test flakiness — what is known, and what to fix

**Status: open.** Written 2026-09-08 after landing the billing/provider work
(Phases A–E) and agent turn traces through CI.

## The problem

CI cannot currently distinguish a real regression from noise, in either repo.
A red run is not evidence that your change broke something, and a green run is
not proof that it did not. Two large branches were landed through that this
week, which is the wrong way round: the gate should be trustworthy *before* it
is leaned on.

Every failure below was verified as pre-existing by re-running, and by checking
out the pre-change commit in a `git worktree` and reproducing the identical
result. That verification took real time on three separate occasions and will
keep costing it until this is fixed.

## 1. Server integration tests are order-dependent

They share one Postgres instance. Two consecutive full runs on an **unchanged
tree** produced *different* failing sets:

```
run 1: MemoryPruningServiceTests, RoutedLLMTransportStreamingTests,
       MemoryCompileSpaceCountersTests, InsightTests, TenantIsolationTests
run 2: BYOKConsistencyTests, ConversationTests, KanbanServiceTests,
       RoutedLLMTransportStreamingTests, SkillRunnerTests
```

Same commit, same machine, minutes apart. The rotation is the tell: these are
not five broken suites, they are suites contending over shared database state.

`withTestFluent` and `.integrationDatabase` already exist and per-suite clones
are mentioned in `ci.yml`, so the isolation mechanism is partly there — the
question is which suites are not using it, or are using it against a database
another suite is mutating.

**Note:** CI's Integration Tests job passes on Linux. The rotation above is
local (macOS). That divergence is itself worth understanding — it may mean the
CI job is not running what a developer runs.

### One genuine, consistent failure

`RoutedLLMTransportStreamingTests` — "BYOK uses native provider streaming when
selected adapter supports it". Fails every run, on `main`, and reproduced at
`c06c427` (pre-session) in a worktree. `payload["stream"]` arrives nil where
`true` is expected. Not flaky; simply broken, and has been for some time.

## 2. An iOS snapshot test does real network work

`RedesignChromeSnapshotTests.testThinkEmptyHero` failed once on CI against
unchanged code (run `34206926492`), then passed on re-run with no change.

The log shows `NSURLErrorDomain Code=-1004 "Could not connect to the server"`
against `http://localhost:8080/v1/apple/consent` immediately before the
comparison. A snapshot test is making live HTTP calls, so its rendered output
depends on how fast a connection fails on that particular runner.

Snapshot precision is 0.98 / perceptual 0.96, so a transient banner or spinner
is enough to break it.

## What to fix, in order

1. **Isolate the server integration DB per suite.** The rotation is the whole
   problem; everything else in that suite list is a symptom.
2. **Stub the network in snapshot tests.** `testThinkEmptyHero` builds a
   `ChatViewModel` with stub clients but something still reaches the network —
   most likely `AppState()`, which the snapshot helper constructs directly.
3. **Fix or quarantine the BYOK streaming test.** It is a consistent failure
   pretending to be part of the noise, which is the worst kind: it trains
   everyone to ignore a red suite.
4. **Reconcile local and CI integration runs**, so that green on CI means the
   same thing as green locally.

## Why it matters

A flaky gate does not stay neutral. It teaches people to re-run until green,
and the first genuinely broken thing to arrive wearing the same colours goes
straight through.
