# Linked accounts — xAI, Nous, Google Calendar

Three third-party accounts you sign into rather than paste a key for.

> **All three are iOS-only.** The server emits connection rows for each, and the
> web app has no route to connect any of them — the rows render as plain
> non-clickable text on `/settings/connections`. If you use LuminaVault only in
> a browser, you cannot link these at all today.

---

## xAI / Grok

Links your **SuperGrok** subscription, unlocking Grok chat, X search, image
understanding, and text-to-speech.

### Connect

1. Tab bar → **More** → **Settings**.
2. **Manage Connections** → **Linked Accounts**.
3. Under **xAI Grok**, tap **Connect with xAI**.
4. Sign in with your X (SuperGrok) credentials in the sheet that opens.

Once linked, a **Grok Features** section appears listing *Chat with Grok*,
*X Search*, *Vision*, *Text-to-Speech*. The pane also shows **Status**, **Tier**
and **Since**.

**Disconnect** removes the xAI session from your Hermes container and reverts
your tier to trial. You can reconnect at any time.

### Tier gate

The Grok feature routes sit behind a premium guard:

- **402 Payment Required** on free and trial → the app shows the paywall.
- **409 Conflict** for a premium user with no active xAI link → connect first.

### Using it as a model provider instead

Separately from the OAuth link, xAI is one of the nine providers in
[llm-providers.md](llm-providers.md). In **Edit provider** for xAI you choose
**Authentication**: *API key*, or *Linked xAI account (SuperGrok)* — the second
uses this link and needs no key.

---

## Nous Portal

Links your personal Nous Research subscription.

1. Tab bar → **More** → **Settings**.
2. **Manage Connections** → **Connect Nous Account**.
3. Tap **Connect Nous Account**.
4. Approve the OAuth device code in the browser sheet, then return.

The pane shows **Status**, **Plan** and **Since**, plus **Manage on Nous ↗**
which opens `portal.nousresearch.com/manage-subscription`.

Nous is also available as a keyed provider in
[llm-providers.md](llm-providers.md) — the two paths are independent.

---

## Google Calendar

Lets Hermes see your schedule when you chat, find free time, and create events.
Read **and write** access.

1. Tab bar → **More** → **Settings**.
2. **Manage Connections** → **Linked Accounts**.
3. At the bottom, tap **Google Calendar**.
4. Tap **Connect Google Calendar**. A browser sheet opens for Google's consent
   screen.
5. Approve.

The pane then shows **Status**, **Account** and **Last synced**, with
**Add to Calendar** and **Disconnect**. If the row says *"Access expired —
reconnect to resume syncing"*, run the connect flow again.

**Disconnect** revokes access and removes synced events from your brain.

Note this is **Google** Calendar, over OAuth. Your **device** calendar is a
different integration, consent-gated under Data Access — see
[apple-data.md](apple-data.md). Connecting one does nothing for the other.

---

## Verifying

Settings → **Diagnostics** → **Test Connections**. The relevant row
(`linked:xai`, `nous:portal`, `calendar:google`) should read **Connected**.

---

## Known limits

- **No web click-path for any of the three.** The server emits their connection
  rows and the web has no `hrefFor` case, so they appear as dead text with no
  way to act on them. iOS-only until the web adds the routes.
- **Grok needs premium *and* a link.** Two different failure codes, and only the
  402 surfaces a paywall — a 409 just fails.
- **Disconnecting xAI reverts your tier to trial.** Expected, but worth knowing
  before you tap it.
