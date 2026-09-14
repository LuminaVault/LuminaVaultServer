# Let Claude Code, Codex or Hermes read your vault

Give a coding agent a key so it can search everything you have saved, from its
own terminal.

This is the opposite direction to [connecting a brain](connect-your-brain.md).
There, LuminaVault reaches out to a model. Here, an outside tool reaches **in**
to your vault over MCP.

---

## What you get

The agent can search your notes, files and memories as a tool call — so "what
did I decide about the rate limiter" works in Claude Code without you pasting
anything.

Supported clients: **Claude Code**, **Codex**, **Hermes**, and **Other MCP
client** for anything else that speaks MCP.

---

## Make a key

### Web

1. Sidebar → **Settings** → **Agent connections**.
2. Under **New connection**, type a **Name**. Name it after the machine, not the
   project — `laptop`, `work desktop`. You are naming the thing you may later
   want to revoke.
3. Pick your **Client**.
4. Click **Create connection**.
5. **Your key — shown once** appears. Click **Copy \<client\>** to get the
   ready-made setup command, or **Copy key** for the raw token.
6. Click **Done**.

### iOS

1. **More** → **Settings** → **Manage Connections** → **Agent connections**.
2. Fill **Name (laptop, work desktop)** and pick a **Client**.
3. Tap **Create connection**.
4. Tap **Copy setup prompt**, or copy the key itself.
5. Tap **Done**.

Creating the key on the phone and pasting it into a terminal is awkward. If the
agent runs on a laptop, make the key on the web.

## Point the agent at it

Paste the copied command into the client. If you took **Copy prompt** instead,
paste that into the agent itself and let it configure its own MCP settings —
that is what the prompt is for.

Then ask it something only your vault knows.

---

## The key is shown once

Both clients say so and both mean it. Only a hash is stored — there is no
screen, no endpoint and no support process that can recover it. Lose it and you
revoke the connection and make another.

---

## Revoking

**Web** — Settings → **Agent connections** → **Active keys** → **Revoke**.
**iOS** — same screen, swipe the row → **Revoke**.

Revoke immediately if a machine is lost or a key lands somewhere shared. Each
row shows **Last used**, which is how you tell a dead key from a live one.

---

## If it will not connect

- **A browser-based MCP client cannot connect at all.** Anything sending an
  `Origin` header is rejected with 403 — a known defect, not a setting. CLI
  clients like Claude Code and Codex send no `Origin` and work.
- **Check the URL in the generated snippet.** It comes from server config, and
  on a misconfigured deployment it can point somewhere wrong, which looks
  exactly like a bad key.
- **Still says never used?** The agent is not reaching the server. Check the
  snippet went into the right config file and the client was restarted.

Full reference: [integrations/agent-connections.md](../integrations/agent-connections.md).

---

## Setup with Lumina

If you would rather not do any of this by hand, both clients have a shortcut
that writes the instructions for you.

**Web** — Settings → **Setup with Lumina**.
**iOS** — Settings → the **Setup with Lumina** card at the top.

Pick **Claude**, **Codex**, **Hermes** or **Anything**, review the generated
prompt, and send it to Lumina. It does not run on its own — you see the prompt
before anything happens.
