# Agent connections (MCP)

Give Claude Code, Codex, another Hermes, or any MCP client a revocable key so it
can search your vault.

---

## What this is

LuminaVault exposes an **MCP server** at `/v1/mcp` over Streamable HTTP. An
agent connection is a token (`lv_…`) that authorises one client to use it. The
server also hands back a paste-ready config snippet for the client you pick.

This is the *inbound* direction — an outside agent grounding on your vault. It
is unrelated to [BYO Hermes](hermes.md), which is LuminaVault reaching *out*.

Client kinds: **Claude Code**, **Codex**, **Hermes**, **Other MCP client**.

---

## On the web

1. Sidebar → **Settings** → **Agent connections** (group *Connections*).
2. Under **New connection**, type a **Name** — name it after the machine the key
   will live on, e.g. `laptop`, `work desktop`. You will be glad later when
   deciding which one to revoke.
3. Pick a **Client**.
4. Click **Create connection**.
5. The **Your key — shown once** panel appears. Use **Copy key**, and
   **Copy \<client\>** for the ready-made config command. **Copy prompt** gives
   you a setup instruction you can paste into the agent itself.
6. Click **Done**.

Before creating anything you can pick a client and read **Setup preview** to see
the shape of the config, with a placeholder key.

Existing keys are listed under **Active keys** with their client, token prefix
and last-used time. **Revoke** removes one.

## On iOS

1. Tab bar → **More** → **Settings**.
2. **Manage Connections** → **Agent connections**.
3. Under **New connection**, fill **Name (laptop, work desktop)** and pick a
   **Client**.
4. Tap **Create connection**.
5. In **Your key — shown once**, copy the key, or tap **Copy setup prompt**.
6. Tap **Done**.

**Active keys** lists them; swipe a row to **Revoke**.

---

## The key is shown once

Both clients say so and both mean it. LuminaVault stores a hash — there is no
screen, endpoint or support process that can show you the key again. If you lose
it, revoke the connection and create another.

---

## Health, Calendar & Reminders

A key can also reach your synced Apple Health, Apple and Google calendars and
Apple Reminders. It is **off for every key** until you turn it on:

- **Web:** Settings → Agent connections → the **Health, Calendar & Reminders**
  switch, either when creating the key or on its row under **Active keys**.
- **API:** `PATCH /v1/me/agent-connections/{id}` with `{"allowPersonalData": true}`,
  or `allowPersonalData` on the create request.

It adds five MCP tools:

| Tool | Does |
|---|---|
| `health_query` | Daily totals/averages of synced HealthKit data, one metric or all |
| `calendar_query` | Upcoming events, Apple + Google, up to 90 days ahead |
| `reminders_list` | Open reminders, soonest due first |
| `calendar_create` | Adds an event on your iPhone |
| `reminder_create` | Adds a reminder on your iPhone |

Two gates apply, in order. The key needs the switch above. Then each kind of
data needs your consent under **Apple data**, the same consent the in-app agent
uses; the create tools also need **allow changes** for that kind. A refused call
comes back as a tool error that says which one to turn on.

These tools always act on **your own** data. They ignore `X-Vault-ID`, so a key
used on a shared vault never reaches another member's health or calendar.

The create tools talk to the phone live: the LuminaVault app must be connected,
or the call fails with *device did not respond*.

### Hermes

Hermes takes the key through the config LuminaVault generates for the
**Hermes** client:

```bash
hermes mcp add luminavault --url https://<your-server>/v1/mcp --auth header
# Authorization: Bearer lv_…
```

Restart the gateway for that profile afterwards. On a machine with several
profiles, run it once per profile (`HERMES_HOME=~/.hermes/profiles/<name>`),
with a separate key for each, so you can revoke one without the others.

---

## Verifying

Point the client at LuminaVault using the copied config, then ask it something
that can only come from your vault. In LuminaVault, the connection's
**Last used** should stop saying *Never used*.

---

## Known limits

- **Any client that sends an `Origin` header is rejected with 403.**
  `MCPOriginGuard` is constructed with an empty allowlist
  (`App+build.swift:2210` passes only a logger; the default is `allowedOrigins: []`),
  and it rejects every request carrying an `Origin`. CLI clients — Claude Code,
  Codex — send none and work. **Browser-based MCP clients cannot connect at
  all**, and the failure looks like an auth problem rather than a policy one.
  This is a defect, not a deliberate restriction.
- **There is no rename.** To change a name, revoke and recreate.
- **The base URL in the generated config comes from server config**
  (`MCP_PUBLIC_BASE_URL`, falling back to `INGESTION_PUBLIC_BASE_URL`, then a
  hardcoded default). On a deployment where none is set correctly the snippet
  will point somewhere wrong, and it will look like the key is broken.
