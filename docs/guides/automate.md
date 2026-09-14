# Make it run without you

Five different things share the word "job" across the two clients. This page
sorts them out first, then covers each.

| | What it is | Where |
|---|---|---|
| **Skills** | Capabilities your agent has, some on a schedule | Both |
| **Workflows (Studio)** | Multi-model pipelines you author on the web | Both |
| **Agent runs** | One-off tasks handed to your own Hermes | iOS |
| **Hermes jobs** | Cron on your own Hermes, mirrored here | iOS |
| **Hermes cron** | The same cron, created in plain English | iOS |

The ones that say "your own Hermes" need [BYO Hermes](connect-your-brain.md#byo-hermes-your-own-server).

---

## Skills

**Web** — Sidebar → **Skills**. **iOS** — Dashboard → **Skills**, or Settings →
**Automation & Alerts** → **Skills**.

Each skill shows what it does, when it runs, and how often it is allowed to.
Click one for detail.

**There is no Run button here on the web.** Skills run on a schedule, or you run
one from [Reflect](think.md#reflect). iOS skill detail does let you change the
**Cadence** and the **Notification channel** (Digest / Nudge / Chat).

**Pin a skill** to protect it: **"Pinned skills are never consolidated, marked
stale, or archived."** On iOS this control only appears when you arrive from
Settings, not from the Dashboard.

**Skills from your Hermes** appear in their own section on the web with a switch
each. The switch is a mirror only — *"Runs and schedules stay on Hermes;
LuminaVault only mirrors the switch."*

### Automations (iOS)

Settings → **Automation & Alerts** → **Automations** is the same skills, framed
as *when does this run*. Each row has a toggle and a cadence menu:
**Manifest default**, **Daily 7am**, **Daily 8am**, **Daily 9am**,
**Weekly Sun 6pm**.

---

## Workflows (Studio)

Multi-step, multi-model pipelines with approval gates and a spend cap.

**Author them on the web.** Sidebar → **Studio** → **New workflow**, or
**Customize** a curated template.

**Run and watch them anywhere.** iOS: **More** → **Studio** (titled
**Cerberus Studio**). Tap a template to run it, or swipe a workflow → **Run**.
The empty state says it plainly: *"Build workflows on the web, then trigger and
monitor them here."*

Dashboard row **Jobs (04)** on iOS opens this same screen.

### Approvals

A workflow can pause for you. Both clients show a **Waiting for you** section.

**Web** — **Approve** or **Reject**.
**iOS** — **Review** (which opens a sheet where you can attach memories to the
gate before approving) or **Reject**.

### Plan limits

Studio is tier-gated. On a plan without authoring you can browse and read
history but not build or run:

> Your plan can browse templates and history. Pro or Ultimate unlocks authoring
> and execution.

The limits strip shows active runs, per-run cost cap, today's spend against the
daily limit, and whether the managed pool is ready or paused.

---

## Agent runs (iOS)

Hand a task to your own Hermes and watch it work.

1. In a chat, tap **+** → **Run as agent**.
2. The sheet explains: *"Hermes runs this on your own machine, with your tools.
   It asks before anything risky."*
3. Edit the task, tap **Run on my Hermes**.

Watch progress under Settings → **Automation & Alerts** → **Agent Runs**, with
an **ANSWER** and a **TRAIL**.

**When it needs permission** you get **"Hermes needs approval"** with the exact
command and whichever choices the server allows: **Allow once**,
**Allow this run**, **Always allow**, **Deny**. *"Always allow" is withheld for
some commands* — the choices are server-driven, not a fixed set.

A push notification about a run opens it directly, wherever you are in the app.

---

## Hermes jobs and cron (iOS)

Two screens onto the scheduled work running on your own box.

**Hermes Jobs** — Settings → **Manage Connections** → **Hermes Jobs**. Full
control: **New job**, edit, delete, **Run now**, and the collected output of
past runs. Fields are **NAME**, **SCHEDULE** (*"A cron expression, an interval
like 'every 2h', or a one-shot time."*), **PROMPT**, **DELIVER**, **SKILLS**.

**Hermes Cron** — Settings → **Manage Connections** → **Hermes Cron**. Creates
jobs from plain English: type *"every weekday 9am, AI news digest to Telegram"*,
tap **Preview**, check the **Will create** summary, tap **Create job**.

If your box is unreachable you get the last synced copy with a banner:

> Your Hermes is unreachable — showing the last synced copy. Changes will fail
> until it's back.

Deleting a job stops it running; output already collected stays in your vault.

### Known limits

- **Cron pause, resume and delete are web-only.** iOS lists and creates but
  declares no endpoint for the other three.
- **Both screens need the Hermes dashboard linked**, which iOS cannot do. Set it
  up on the web first — see [integrations/hermes.md](../integrations/hermes.md#2-the-dashboard-web-only).
- **Dashboard row "Ask Lumina" (01) does nothing.** It is an unwired stub.
- There is a **Jobs** screen in the iOS codebase that nothing navigates to. If
  you find it while reading code, it is unreachable.
