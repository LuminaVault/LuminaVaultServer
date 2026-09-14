# Messaging gateways

Talk to your assistant from Telegram, Discord, Slack, email, Matrix, ntfy,
Mattermost, WhatsApp or iMessage.

---

## How this actually works

LuminaVault does not run the gateway. **Your Hermes does.** LuminaVault stores
the config encrypted, then hands it to Hermes and restarts the container — the
"apply" step. Both clients say as much at the bottom of the list:

> Hermes runs the actual gateway processes on your host. LuminaVault stores the
> config encrypted and surfaces the CLI command to apply it.

So a gateway needs a working Hermes first. See [hermes.md](hermes.md).

Two shapes of setup:

- **Credential gateways** — you paste tokens. Telegram, Discord, Slack, Email,
  Matrix, ntfy, Mattermost.
- **Pairing gateways** — nothing to type. WhatsApp (scan a QR), iMessage
  (approve in a browser, bind a phone number). The credential save/test routes
  reject these; they have their own flows.

---

## What each one needs

Field labels come from the server catalog, so they are identical on web and iOS.

| Gateway | Fields |
|---|---|
| **Telegram** | Bot token; Your Telegram user ID(s) *(from @userinfobot)* |
| **Discord** | Bot token; Your Discord user ID(s) |
| **Slack** | Bot token (`xoxb-…`); App token (`xapp-…`); Your Slack member ID(s) |
| **Email** | Email address; Password (or app password); IMAP host; SMTP host; Allowed senders; IMAP port; SMTP port; Home address (cron delivery) |
| **Matrix** | Homeserver URL; Access token; Allowed user ID(s); Bot user ID (optional) |
| **ntfy** | Topic; Allowed topic(s); Server URL (optional); Token (optional) |
| **Mattermost** | Server URL; Bot token; Allowed user ID(s) |
| **WhatsApp** | *(nothing — QR pairing)* |
| **iMessage (Photon)** | *(nothing — device-code login, then a phone number)* |

The allowed-users field is the access control. Without it anyone who finds the
bot can talk to your assistant.

---

## Credential gateways

### On the web

1. Sidebar → **Settings** → **Messaging gateways** (group *Connections*).
2. Click the gateway's card.
3. Fill the **Configuration** fields.
4. Click **Save**, then **Test**.
5. Go back and click **Apply to Hermes** (top right), then **Start apply**.

Apply is its own page on the web, with a live step list and a stream log.

### On iOS

1. Tab bar → **More** → **Settings**.
2. **Manage Connections** → **Messaging Gateways**.
3. Tap the gateway.
4. Fill the **Configuration** fields.
5. Tap **Save & apply** — on iOS these are one action, with progress shown
   inline: *Writing your settings* → *Restarting your assistant* → *Checking it
   responds*, ending in *"Connected. Your assistant is live on this platform."*

**Disconnect** removes the stored config. Note what the confirmation says: the
gateway process already running on your Hermes host **stays up** until you stop
it yourself with `hermes gateway stop`.

---

## WhatsApp

Your phone scans a QR that LuminaVault displays — the same model as WhatsApp Web.
Pairing runs inside your Hermes container.

### On the web

1. Settings → **Messaging gateways** → the **WhatsApp** card.
2. Click **Start pairing**. The button becomes **Waiting for scan…**.
3. A QR appears. On your phone: **WhatsApp → Settings → Linked Devices → Link a
   Device**, then scan it.
4. Wait for *"Device linked successfully."*

### On iOS

1. Settings → **Messaging Gateways** → **WhatsApp**.
2. Pairing **starts automatically** — no button to press.
3. The QR renders on screen. Scan it from **another** device's WhatsApp:
   **Settings → Linked Devices → Link a Device**.
4. Wait for *"WhatsApp linked."*

You are holding the code, not scanning it. Codes expire and regenerate on their
own. Afterwards: **Re-pair (scan a new code)** or **Unlink WhatsApp**.

If the web shows *"WhatsApp pairing unavailable on this deployment"*, the server
does not have per-tenant containers enabled.

See [`../whatsapp-pairing.md`](../whatsapp-pairing.md) for the mechanics.

---

## iMessage (Photon)

> **iOS only.** There is no web click-path, and the gateway is missing from
> `openapi.yaml`, so the web app's generated types do not know it exists. Its
> card on web would route to a generic form with no fields and a Save button the
> server rejects.

Gives your assistant a real phone number people can text.

1. Settings → **Manage Connections** → **Messaging Gateways** → **iMessage (Photon)**.
2. Setup starts automatically.
3. Under **Approve in your browser**, open the link shown (or go to
   `photon.codes` and enter the code). The code expires — the screen says when.
4. Come back to the app. Under **Your phone number**, enter an E.164 number
   (`+15551234567`).
5. Tap **Submit phone & continue**.
6. Wait through *"Provisioning your iMessage line…"*.
7. On **Success!** you get the assistant's iMessage number. Text it to talk.

Requires the server to have both `PHOTON_SIDECAR_URL` and
`PHOTON_SIDECAR_TOKEN` set. Without them the routes degrade and setup cannot
complete.

---

## Verifying

- The gateway list shows counters: **Verified**, **Configured**, **Error**, **Off**.
- Send yourself a message on the platform and check you get a reply.
- Web: Settings → **Connections** → **Test all**. iOS: **Diagnostics** →
  **Test Connections**.

---

## Known limits

- **"Test" does not test the gateway.** Hermes exposes no gateway-admin HTTP
  API, so Test only probes your Hermes `/v1/health`. Status therefore **never
  advances past "configured"**, even when the gateway is working perfectly.
  A green Verified badge means "your Hermes is up", not "Telegram works".
- **iMessage (Photon) is iOS-only** and absent from the OpenAPI spec.
- **Disconnect leaves the process running** on your Hermes host. Stop it with
  `hermes gateway stop`.
- **Apply needs per-tenant containers.** Where they are disabled, apply returns
  404 and the web says *"Apply unavailable — per-tenant containers are disabled
  on this deployment."*
- **There is a dead onboarding screen** for gateways in the iOS codebase
  (`Features/Onboarding/GatewaysSetupView.swift`). It is never mounted. If you
  find it while reading the code, it is not reachable.
