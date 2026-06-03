# Mnemosyne memory on BYO Hermes

On **managed** Hermes, [Mnemosyne](https://github.com/AxDSan/mnemosyne) is the
default memory layer — it ships baked into the LuminaVault Hermes image and is
wired automatically per tenant. Nothing to do.

If you run **[BYO Hermes](byo-hermes.md)** (your own box), LuminaVault cannot
modify your image, so Mnemosyne is opt-in. This guide adds it to a self-hosted
Hermes so your instance gets the same default-memory behavior.

## What you get

Mnemosyne runs as a Hermes **MCP server** (a `mnemosyne mcp` subprocess). Hermes
auto-discovers its `remember` / `recall` / `triples` tools. Memory is a single
local SQLite store + embedding cache — zero external services.

## 1. Install

Mnemosyne's `[all]` extra (fastembed, llama-cpp) targets **Python ≤ 3.12**. The
Hermes runtime is Python 3.13, so install Mnemosyne into its **own** venv and put
the `mnemosyne` console script on `PATH` — do **not** install it into Hermes'
interpreter:

```bash
python3.12 -m venv /opt/mnemosyne-venv
/opt/mnemosyne-venv/bin/pip install "mnemosyne-memory[all]==3.1.2"
# Align the MCP lib with the version Hermes ships to keep the stdio handshake happy:
/opt/mnemosyne-venv/bin/pip install "mcp==1.26.0"
ln -sf /opt/mnemosyne-venv/bin/mnemosyne /usr/local/bin/mnemosyne
mnemosyne --help   # sanity check it's on PATH
```

> PEP 668 (`externally-managed-environment`) on Ubuntu 24.04 / Debian 12 is why
> the venv is mandatory.

## 2. Configure `config.yaml`

In your Hermes config (`~/.hermes/config.yaml` or `$HERMES_HOME/config.yaml`):

```yaml
# Make Mnemosyne the sole memory layer — disable Hermes' native curated memory
# so the two don't compete. (Omit this block to keep native memory alongside.)
memory:
  memory_enabled: false
  user_profile_enabled: false

# Register Mnemosyne as an MCP server. The per-server env: is required — Hermes
# passes only these to the subprocess, so point the store at persistent storage.
mcp_servers:
  mnemosyne:
    command: mnemosyne
    args: ["mcp"]
    env:
      MNEMOSYNE_DATA_DIR: /opt/data/mnemosyne
      FASTEMBED_CACHE_PATH: /opt/data/mnemosyne/cache
```

Set `MNEMOSYNE_DATA_DIR` / `FASTEMBED_CACHE_PATH` to a path on a **persistent
volume** so the SQLite store and embedding model survive restarts. `session_search`
(conversation recall) is unrelated and can stay enabled.

## 3. Verify

```bash
hermes memory status     # should show Mnemosyne active, built-in disabled
hermes tools list        # mnemosyne remember/recall/triples present
hermes mnemosyne stats   # working + episodic memory counts
```

Store a fact in a chat, restart Hermes, recall it — persistence confirms the
volume mapping is correct.

## Upgrades

Bump the pinned version (`mnemosyne-memory[all]==3.1.2`) and reinstall into the
venv. Check Mnemosyne's [`UPDATING.md`](https://github.com/AxDSan/mnemosyne/blob/main/UPDATING.md)
for SQLite schema migrations before upgrading; your data dir is preserved.

## Docker BYO

If your Hermes runs in your own container, do the install at **build time**
(a `RUN` layer mirroring step 1) and bind-mount the data dir, rather than
installing on every start. This matches how the managed LuminaVault image bakes
Mnemosyne in `docker/hermes.Dockerfile`.
