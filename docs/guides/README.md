# Guides

How to actually use LuminaVault, on the web and on iPhone, task by task.

These are the "how do I…" pages. For reference detail on a particular connector
— every field, every error code, every known defect — see
[`../integrations/`](../integrations/README.md) instead.

Web means `app.luminavault.fyi`. iOS means the LuminaVault iPhone app. Where the
two differ, both are given; where something only exists on one, it says so.

---

## Start here

| | |
|---|---|
| **[getting-started.md](getting-started.md)** | Signup to a working vault, in order. Read this one first. |
| **[connect-your-brain.md](connect-your-brain.md)** | Managed, your own API key, your own Hermes, or a local model. |
| **[connect-an-agent.md](connect-an-agent.md)** | Let Claude Code, Codex or Hermes search your vault over MCP. |

## Day to day

| | |
|---|---|
| **[capture.md](capture.md)** | Save a note, a link, a file, a voice note — from anywhere. |
| **[chat-and-ask.md](chat-and-ask.md)** | Ask questions, follow sources, use multi-model. |
| **[find-things.md](find-things.md)** | Search memories, search by picture, browse the vault. |
| **[organise.md](organise.md)** | Spaces, memories, review queues, the knowledge graph. |
| **[think.md](think.md)** | Reflect, memos, insights, and what Today shows you. |
| **[automate.md](automate.md)** | Skills, scheduled jobs, agent runs, workflows. |
| **[import-and-export.md](import-and-export.md)** | Bulk import, and getting everything back out. |

---

## "I want to…"

| I want to | Go to |
|---|---|
| Save a thought before I lose it | [capture](capture.md#a-note) |
| Save a link to read later | [capture](capture.md#a-link) |
| Save a PDF, photo, or recording | [capture](capture.md#a-file) |
| Capture without opening the app | [capture](capture.md#without-opening-the-app) |
| Ask what I said about something | [chat-and-ask](chat-and-ask.md) |
| Find a note when I forget the words | [find-things](find-things.md#search-by-picture) |
| Read a file I saved | [find-things](find-things.md#browse-the-vault) |
| Organise notes into folders | [organise](organise.md#spaces) |
| Fix or delete something Lumina remembered | [organise](organise.md#memories) |
| See what Lumina noticed on its own | [think](think.md#insights) |
| Have Lumina look across everything | [think](think.md#reflect) |
| Get a written-up answer I can keep | [think](think.md#notebook) |
| Run something on a schedule | [automate](automate.md) |
| Bring in a pile of existing files | [import-and-export](import-and-export.md#import) |
| Take my data and leave | [import-and-export](import-and-export.md#export) |
| Use my own model or API key | [connect-your-brain](connect-your-brain.md) |
| Use my vault from Claude Code | [connect-an-agent](connect-an-agent.md) |
| Talk to Lumina from Telegram or WhatsApp | [../integrations/messaging-gateways.md](../integrations/messaging-gateways.md) |

---

## Not covered here

These pages stop at the core workflows and the connectors. Settings that are not
integrations, the auth flows, onboarding itself, and the deeper Studio /
Analytics / Dashboard panels are deliberately not written up.

The better answer for those is a guided tour inside the app rather than more
prose in a repo the user cannot see — see
[future-interactive-onboarding.md](future-interactive-onboarding.md), which
records the idea, the inventory it would need to cover, and what makes it hard.

---

## Things worth knowing before you start

**Your phone and the browser see the same vault.** Capture on one, it shows up
on the other. The web polls every 30 seconds while the tab is open.

**Nothing is only in the app.** Everything you save is a file in your vault, and
you can take all of it with you — see [import-and-export](import-and-export.md#export).

**The two clients are not identical.** iOS has the share sheet, Shortcuts, a
widget, Apple Health and the linked accounts. The web has the Hermes dashboard
form, the gateway apply page and the publisher dashboard. Each page says which
is which.

**"Notebook" in the sidebar opens `/memos`.** There is no `/notebook` route. Not
a problem, just a surprise if you are reading URLs.

---

## When something does not work

1. **Web:** Settings → **Connections** → **Test all**.
   **iOS:** Settings → **Diagnostics** → **Test Connections**.
2. Read the row that is not green. Most failures are a missing model key or an
   unreachable Hermes.
3. If a whole settings screen is empty and every call 404s, the server is
   missing `LV_SECRET_MASTER_KEY` — see
   [`../integrations/README.md`](../integrations/README.md#the-one-switch-that-turns-all-of-this-off).
