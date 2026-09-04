# Runbook — verify the lock-screen approval round trip

**Status: unproven.** The Phase 1 client is built and unit-tested, but nobody has yet watched an approval push render its buttons on a real device and seen the answer reach Hermes. This runbook is what closes that gap.

Do not describe "approve from your lock screen" in any public copy until step 6 passes. Everything before it proves the parts, not the whole.

## Why the simulator cannot answer this

Tried and failed on iPhone 16 Pro (26.4.1):

- `xcrun simctl push` with a hand-written payload (`aps.category: "approval"`, `choices: "once,session,deny"`) delivered nothing, because the app had never been granted notification authorization — it asks after the SOUL quiz, which needs a signed-in account.
- `simctl privacy` has no notifications service, so the grant cannot be forced.

Actionable notifications need a real device, a real APNS round trip, and a signed build. There is no shortcut.

## Preconditions

1. **Server ≥ commit `aae3bdc`** (`fix(apns): set aps.category…`). Before that commit `aps.category` was nil on every push ever sent, so iOS could not match the category and **the buttons could not render at all**. If you are testing against a deployment older than this, you are testing the bug.
2. **Shared ≥ 5.6.0** tagged, and the client pin bumped to match — otherwise the client will not build.
3. A **real device**, signed, with notifications authorized for LuminaVault. Authorization is requested after the SOUL quiz, so sign in and complete onboarding first.
4. APNS configured for the environment you are testing (`APNS_KEY_ID`, `APNS_TEAM_ID`, the `.p8`, and the right sandbox/production topic). A TestFlight build uses production APNS; a Debug build from Xcode uses sandbox. Mixing them is the most common reason a push silently never arrives.
5. A **Hermes reachable from the server** whose `/v1/capabilities` reports `approval_events` and `run_events_sse`. Without both, `POST /v1/hermes/runs` answers `501 hermes_runs_unsupported` and no run starts.

## The test

1. **Register the device.** Launch the app, sign in, confirm the notification permission prompt was accepted. `POST /v1/devices` should have stored the token — check `devices` for a row on your tenant.

2. **Confirm the category is not opted out.** `GET /v1/me/apns-categories` must show `approvalEnabled: true`. (Before Shared 5.6.0 this field did not exist; the column defaulted to on and could only be changed in the database.)

3. **Start a run that will need permission.** From the chat composer's `+` menu choose **Run as agent**, with a prompt whose tool call Hermes will gate — something touching the shell or the filesystem. Anything that runs without asking proves nothing.

4. **Lock the phone** and wait for the push. Expected: a notification titled for the approval carrying **Approve once** and **Deny** (the buttons are built from the payload's comma-separated `choices`, so the exact set follows what Hermes offered).

   If the banner arrives with **no buttons**, `aps.category` is missing — you are on a build older than `aae3bdc`, or the category name in the payload does not match one registered on the client.

5. **Answer from the lock screen without unlocking, and without opening the app.** Deny is answerable while locked; the permissive answers require an unlocked device by design (`authenticationRequired`), so use **Deny** for the strictest version of this test, then repeat with **Approve once** after a Face ID unlock.

6. **Confirm the answer landed.** Three things must all be true:
   - `POST /v1/hermes/runs/{id}/approval` shows in the server log for your tenant.
   - `GET /v1/hermes/runs/{id}` no longer has a `pendingApproval`, and the status moved off `waiting_for_approval`.
   - The run continues on Hermes and reaches a terminal status — and a `runCompleted` push follows if that category is on.

   **Step 6 is the whole test.** Buttons that render but whose answer never reaches Hermes is the failure mode worth catching, and it looks like success on the phone.

## Known limits, by design

- **Answering happens in a background task.** If the POST cannot finish inside the window iOS grants, the answer is lost — the run stays waiting and the user must answer in the app. Watch for this on a bad network; it is the most likely intermittent failure.
- **Only API-originated runs surface.** An approval raised inside a Telegram or Discord session stays on that platform. Do not test through those and conclude it is broken.
- **A run Hermes has forgotten cannot be answered.** The gateway keeps runs in memory for 300 s. Past that, LuminaVault still has the history but the approval is gone; expect `hermes_run_expired` (410) or `hermes_approval_not_pending` (409).
- **Buttons are static per category, not per push.** The registered category declares every choice Hermes can offer; a choice the run did not offer is refused client-side. Making buttons truly per-push needs a `UNNotificationServiceExtension`, which needs `mutable-content: 1` and a new signed target — deliberately not built.

## If it fails

| Symptom | First thing to check |
|---|---|
| No notification at all | Authorization granted? Device row exists? Sandbox vs production APNS matching the build? |
| Banner, no buttons | Server older than `aae3bdc`; `aps.category` nil |
| Buttons, tapping opens the app | An action was registered `.foreground` — a unit test asserts against this, so suspect a merge |
| Tap does nothing visible, run still waiting | Background task window; check for the POST in server logs |
| `501 hermes_runs_unsupported` | The Hermes is too old — needs `approval_events` and `run_events_sse` |

## What to record

Note the build, the server commit, the device and iOS version, and which of steps 4/5/6 passed. Until all three pass on one run, the honest status stays "client half built and tested, round trip unproven" — say that internally rather than something warmer.
