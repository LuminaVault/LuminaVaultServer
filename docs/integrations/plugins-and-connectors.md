# Plugins and connectors

Install reviewed skills, sandboxed tools, and content connectors that pull
Readwise highlights, Raindrop bookmarks or RSS feeds into your vault.

---

## Two different things share the word "plugin"

- **Marketplace plugins** — installed into LuminaVault. Declarative or
  WebAssembly, sandboxed, with an explicit permission grant. This includes the
  content connectors.
- **Hermes Hub skills** — installed onto **your Hermes**, by skill id or URL.
  iOS only.

---

## Content connectors

Three ship in the catalog:

| Connector | What you supply |
|---|---|
| **Readwise** | An access token |
| **Raindrop.io** | An access token |
| **RSS / Atom** | A feed URL |

Two other catalog entries are not connectors: **BYOK embeddings** (an embedding
API key — **Pro and above**) and **reading time** (a local computation).

---

## On the web

Installing happens in **Marketplace**, not in Settings.

1. Sidebar → **Marketplace** (group *Workspace*).
2. Search by name or purpose, or filter by category: **All**, **Skills**,
   **Connectors**, **Capture**, **Memory**, **Export**.
3. Click a plugin card.
4. In the right-hand **Install** rail, read **Requested permissions** and tick
   every one. Options are plain-language: *Read memories*, *Create memories*,
   *Read vault files*, *Create or update vault files*, *Contact the listed
   websites*, *Return structured output*.
5. Fill any configuration fields — for a connector this is where the access
   token or feed URL goes.
6. Click **Install**.

The Install button stays disabled until **every** requested permission is
ticked. That is deliberate: an install is a capability grant, not a download.

On an upgrade that asks for more than the installed version had, a warning
appears — *"This upgrade adds N permission(s)"* — and you re-approve.

**Uninstall** appears on the plugin's page once installed.

### Settings → Plugins is read-only

Sidebar → **Settings** → **Plugins** shows the catalog, an install count and an
enabled count. Despite its description ("manage what you have installed") the
page has exactly one control: **Refresh**. Everything actionable is in
Marketplace.

---

## On iOS

1. Tab bar → **More** → **Settings**.
2. **Manage Connections** → **Plugins**.
3. Browse **Marketplace**, **Featured**, or a category section.
4. Tap a plugin to install it and grant its permissions.

Premium entries carry a **PRO** badge.

### Hermes Hub (iOS only)

On the same screen, scroll to **Hermes Hub**:

1. Enter a **skill id or URL** from the Hermes Skills Hub.
2. Tap **Install**.
3. Swipe a listed skill to uninstall it.

This installs onto **your Hermes**, so it needs a working BYO Hermes
([hermes.md](hermes.md)). Where no Hermes is connected the list comes back empty
rather than erroring — an empty Hermes Hub usually means "no Hermes", not "no
skills".

---

## Publishing

Web only. Marketplace → footer → **Publisher dashboard** → **Submit a package**.
Fields: slug, name, summary, description, category, version, and runtime
(**Declarative** or **WebAssembly**; WebAssembly adds a tool name, description
and a `.wasm` upload), then the permissions you are requesting.

Metadata and permissions become **immutable once a version is approved**.

You must be an approved publisher; until then the tab shows **Not approved yet**
with an **Apply to publish** link.

---

## Verifying

- The plugin shows an **Installed** pill in the catalog.
- For a connector, check that items appear in your vault after its first sync.
- Web: Settings → **Connections** → **Test all** lists plugin rows.

---

## Known limits

- **`/settings/plugins` on web installs nothing** despite saying it manages
  installs. Use Marketplace.
- **Hermes Hub is iOS-only**, and returns an empty list rather than an error
  when no Hermes is connected.
- **Plugin tool execution needs a runner.** Where `PLUGIN_RUNNER_URL` and
  `PLUGIN_RUNNER_TOKEN` are unset the server wires a disabled runner client, so
  a plugin can install and then do nothing at run time.
- **BYOK embeddings is Pro-gated** — install is refused on free and trial.
