# Ask your vault

Chat pulls from everything you have saved and cites where the answer came from.

---

## Start a conversation

**Web** — Sidebar → **Chat**. Type in **"Ask Lumina anything…"** and press
**Enter** (Shift+Enter for a newline), or click **Send**.

**iOS** — the **AI** tab. It opens on your chat list, not a chat. Tap **+**
(**"New chat"**) or tap an existing thread. Type in **"Ask Hermie anything…"**
and tap send.

An empty thread offers **Quick actions** — suggested questions. Tap one and it
sends immediately. They are hidden if the server has no suggestions.

While an answer is streaming, Send becomes **Stop**.

---

## Following the answer

Answers cite their sources. Click a citation chip and it opens the file in the
vault at the cited line — and switches to the **Source** view automatically,
because rendered markdown has no line numbers to check a "lines 40-58" claim
against.

**Web** — assistant messages have a **Listen** button that reads the answer
aloud.

**iOS** — the newest answer has **Copy answer**, **Regenerate answer** and
**Edit and resend**. Long-press any message for more: **Save as memory** on an
answer, **Edit and resend** on your own message, or **Rewind to here**, which
discards everything after that point.

---

## Attachments

**iOS only.** The web composer has no attachment control at all — save the file
first via [capture](capture.md) or Import, then ask about it.

In an iOS chat, tap **+** (**"Add context"**):

| | |
|---|---|
| **Attach a file** | txt, md or PDF. Text is read out and the file goes to your vault. |
| **Reference a note** | Search your existing notes and attach one. Hidden if no vault client is wired. |
| **Add a photo** | From your library. |
| **Add a link** | *"The link is added as context for your next message."* |
| **Run a workflow** | Kick off a Studio workflow from the chat. |
| **Run as agent** | Hand the task to your own Hermes — see [automate](automate.md#agent-runs). |

Attachments appear as chips above the field. Remove one by tapping its ×.

---

## Multi-model

Ask several models and combine the answers.

**Web** — tick **Multi-Model** in the composer, then pick a **Strategy**.
**iOS** — the **Multi-Model** toggle in the top bar, then **Strategy: …**.

Strategies on both: **Auto**, **Best of N**, **Debate**, **Consensus**,
**Specialists**. Both controls are disabled while an answer is streaming.

---

## Managing conversations

**Web** — the list is on the left (a sheet on mobile, via the hamburger). Hover
a row and click the trash icon. **There is no confirmation** — it deletes
immediately, though it comes back if the server rejects it.

**iOS** — the **AI** tab list. Swipe a row left → **Delete**.

Untitled threads show as **"Untitled chat"** on both.

---

## Things chat will not do

**No slash commands.** Neither client parses `/`-prefixed input. Every action is
a button or a menu item.

**No attachments on web.** As above.

---

## iOS asks you things back

Two cards can appear mid-conversation:

- **"Make this a Job?"** — **Not now** or **Create Job**. Creating one gives
  *"Job created — find it in the Jobs tab."*
- **"Set a reminder?"** — **Not now** or **Remind me**.

---

## When it does not work

The error shows the server's own message, plus recovery buttons that depend on
what went wrong:

| Button | When |
|---|---|
| **Add API key** | You are in BYOK mode with no working key → [connect-your-brain](connect-your-brain.md#byok-your-own-api-key) |
| **Use managed brain** | Switches you back to the managed model |
| **Upgrade** | iOS only — the web has no billing route, so it never offers this |

*"Resets in N h."* means you have spent an allowance and it will come back.

If you changed your model settings in another tab, the web thread quietly resets
before your next message rather than sending with stale configuration.

Voice errors on iOS (**"Didn't catch that. Try again."**,
**"Speech recognition is unavailable right now."**) clear themselves after a few
seconds.
