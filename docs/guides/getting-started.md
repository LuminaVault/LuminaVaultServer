# Getting started

Signup to a vault that answers questions, in five steps. Fifteen minutes, less
if you keep the defaults.

Do this on whichever client you have. Where they differ, both are given.

---

## 1. Sign in

**Web** — go to `app.luminavault.fyi`.
**iOS** — open the app.

Ways in: **Sign in with Apple**, **Sign in with Google**, **Sign in with X**,
**Sign in with a passkey**, **Continue with phone**, **Continue with email**, or
a password.

Not every button is always there. Apple is always shown; Google and X appear
only when the build was configured with their client IDs. If one is missing, it
was not built in — nothing is wrong with your account.

**Already signed in on your phone?** You can sign the browser in by scanning a
code rather than typing anything: on the web sign-in screen pick the QR tab, then
on iOS go to Settings → **System & Advanced** → **Approve Web Sign-In**, scan it,
and type the six digits shown next to the QR.

---

## 2. Pick a brain

You can skip this — the managed brain works immediately and you can change your
mind later.

If you want your own key or your own server, do it now so everything afterwards
runs on it: **[connect-your-brain.md](connect-your-brain.md)**.

Short version: Settings → **Intelligence** → set **Brain mode** →
**Keys & models** → add a key → **Test connection** → save.

If you are unsure which provider, use **OpenRouter**. One key reaches many
models and it is the only one that unlocks **Auto (Smart)** routing.

---

## 3. Save something

**Web** — Sidebar → **Home**. Type in the box, press **Enter**.
**iOS** — **Home** tab. Type, tap the **Save** arrow.

Then try the others, because they behave differently and it is worth seeing
once:

- **Paste a URL on its own.** A chip says **"Saved as a link"** — that is a
  preview of what will happen. Press Save and the page gets fetched.
- **Attach a file.** Web: the paperclip. iOS: **"Add a file"**.
- **Speak.** Web: the **Speak** button, which appends a transcript to the box.
  iOS in chat: **press and hold** the mic and release to send.

Everything lands in **Recently saved** under the box.

More: **[capture.md](capture.md)**.

---

## 4. Ask about it

Give it a minute — captures have to be processed before they are searchable.

**Web** — Sidebar → **Chat**. **iOS** — the **AI** tab → **+**.

Ask something only your note would answer. The reply cites its sources; click a
citation and it opens the file at the cited line.

If chat refuses, it is almost always BYOK mode without a working key. The error
carries an **Add API key** button that takes you to the right screen.

More: **[chat-and-ask.md](chat-and-ask.md)**.

---

## 5. Make it yours

In rough order of payoff:

| | |
|---|---|
| **Capture without opening the app** | iOS share sheet, Siri, and a widget — [capture](capture.md#without-opening-the-app) |
| **Organise into Spaces** | Folders you can file captures into — [organise](organise.md#spaces) |
| **Bring in what you already have** | Bulk import of PDFs, audio, web pages — [import-and-export](import-and-export.md#import) |
| **Talk to it from Telegram or WhatsApp** | [integrations/messaging-gateways.md](../integrations/messaging-gateways.md) |
| **Use it from Claude Code or Codex** | [connect-an-agent.md](connect-an-agent.md) |
| **Let it think on its own** | Reflect, memos, insights — [think](think.md) |
| **Run things on a schedule** | [automate](automate.md) |

---

## Worth knowing early

**Everything is a file.** Your vault is markdown and the assets you uploaded.
Export it whenever you like — Web: **Vault** → **Export vault**. iOS: Settings →
**Account & Data** → **Privacy & Data** → **Export my data**. Nothing is locked in.

**The clients are not identical.** iOS has the share sheet, Shortcuts, the
widget, Apple Health and linked accounts like Grok. The web has the Hermes
dashboard form, workflow authoring and chat attachments. Each guide says which
is which rather than pretending they match.

**Nothing here is permanent except deletion.** Switching brains, disconnecting a
Hermes, unlinking a gateway — all reversible. Deleting a memory, a vault file,
or your account is not.

---

## If something is wrong

1. **Web:** Settings → **Connections** → **Test all**.
   **iOS:** Settings → **Diagnostics** → **Test Connections**.
2. Read the row that is not green.
3. Most first-run failures are one of two things: BYOK mode with no working key,
   or a BYO Hermes that is not reachable from the server.

If a whole settings screen is blank and everything 404s, that is a server
configuration problem rather than yours —
[the master key](../integrations/README.md#the-one-switch-that-turns-all-of-this-off).
