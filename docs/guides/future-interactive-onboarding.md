# Idea: an interactive onboarding tour

**Status: not built. Not scheduled. Written down so it is not rediscovered.**

Guide the user through each screen in the app itself — what this is, what it
does, where the thing you are looking for lives — on both iOS and the web.

---

## Why

Three facts, each established while writing the docs in this folder:

1. **There is no in-app help.** No help route on the web, no help screen on iOS.
   Nothing in either client explains any screen.
2. **These docs live in a repo the user cannot see.** They are good for us and
   for support. They are not reachable by someone holding the app.
3. **The surfaces that most need explaining are the ones nobody stumbles into.**
   The memory review queues have no filter UI and are reachable only from an
   Analytics recommendation card. Today looks interactive and is not. The
   Hermes dashboard is a second form most people never find, and skipping it
   silently costs them cron, vault import and skill writes.

Written documentation cannot fix (3), because the person who needs it does not
know the screen exists to go and read about it.

---

## What it would be

A tour that runs **in the product**, anchored to real elements, that a user can
start, skip, leave and resume. Not a video, not a slideshow of screenshots that
drift out of date the first time a label changes.

Rough shape:

- **First visit to a screen** offers a one-line explanation of what it is for,
  and a way to see more.
- **A full tour** the user can start deliberately from Settings, walking the
  main surfaces in order.
- **Per-element hints** for the controls that are genuinely non-obvious — the
  ones this folder had to write paragraphs about.

---

## What it would have to cover

The inventory already exists. It is everything the written guides deliberately
stopped short of:

- **Settings that are not integrations** — Appearance, Chat preferences,
  Personality/SOUL, Notifications, Plan, Account, Server connection,
  Self-improvement, Diagnostics, Teams and vaults.
- **Auth** — sign-up, password reset, MFA, passkey enrolment, phone and email
  OTP.
- **Onboarding itself** — the brain choice and the SOUL quiz.
- **Deeper surfaces** — Studio authoring, Analytics panels, Dashboard panels,
  Achievements, the Health tab, Marketplace publishing.
- **iOS-only screens** — Quick Settings, Sync & Backup, Account Privacy,
  Passkeys, Update Hermes.

Plus the [guides](README.md) and [integrations](../integrations/README.md)
content, which is the same material in written form.

---

## What makes it hard

Worth knowing before anyone estimates it.

**Two clients, one set of content.** SwiftUI and Svelte. The copy should live in
one place or the two tours will drift, and a tour that describes a screen
inaccurately is worse than no tour. A shared content file — steps keyed by
screen, with per-client anchors — is the obvious shape, and it is also the part
most likely to be skipped under time pressure.

**Half the UI is conditional.** A tour that points at something the user does
not have is actively confusing. Off the top of the current behaviour:

- Auto (Smart) is hidden without OpenRouter.
- The Brain's Knowledge layer silently falls back to Memories when empty.
- Studio's authoring controls are tier-gated.
- Import's capture button is blocked by a Hermes capability probe.
- The voice button is absent where the browser cannot record.
- Spaces category chips need more than one category.
- Skills' "From your Hermes" section only exists with a Hermes connected.
- The Memories approve/reject block only renders for pending memories.

Each step needs a predicate, and the predicate has to be the same one the UI
itself uses rather than a second copy that goes stale.

**Labels are the content.** Every label quoted in this folder was read from
source because paraphrase drifts. A tour has the same problem with less
tolerance — it points *at* the element.

**Skippable, resumable, and never in the way.** It should be dismissible
permanently in one action, and it should not fire on a screen a user has
already used.

---

## What already exists to build on

**iOS** has real onboarding pieces, but they are a linear first-run sequence
rather than a tour: `ChooseYourBrainScreen`, `NotificationPrimeView`, the SOUL
quiz, and `BYOHermesOnboardingGate`. There is also
`Features/Onboarding/GatewaysSetupView.swift`, fully written and **never
mounted** — worth reading before designing the gateway step, and worth deleting
or wiring up either way.

**Web** has `src/routes/(onboarding)/welcome` and nothing screen-level after it.

**Both** already have "Setup with Lumina" — pick Claude / Codex / Hermes /
Anything and it writes a setup prompt for the agent. That is a different idea
pointed at the same problem, and it suggests a tour could hand hard steps off to
the agent rather than narrating them.

---

## Open questions

- One tour, or per-screen hints, or both?
- Where does the copy live so both clients read the same source?
- Does it replace the first-run sequence on iOS or sit alongside it?
- Does it get a route of its own on the web, or overlay the real screens?
- Is a missing or gated feature skipped silently, or explained as "you do not
  have this"?
- Does it double as the in-app help that neither client has — i.e. can a user
  re-open any single step later, on demand?

---

## Until then

[guides/](README.md) and [integrations/](../integrations/README.md) are the
written substitute. They are structured the way a tour would be — one job at a
time, web and iOS side by side — so they are usable as the script when someone
picks this up.
