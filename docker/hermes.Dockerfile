# HER-276 — bundle LuminaVault's kb-* skills into the Hermes container so
# every deployment ships them by default, instead of relying on the host
# `~/.hermes/skills/` tree.
#
# The base image expects skills under `${HERMES_HOME}/skills/`
# (default `/opt/data/skills/`). docker-compose binds `./data/hermes`
# at `/opt/data`, which shadows the baked-in tree. To keep both:
#
#   1. Skills are baked at `/opt/baked-skills/` (an unmounted path).
#   2. `docker-entrypoint.sh` seeds them into `/opt/data/skills/` on
#      start, never clobbering user-edited files (`cp -rn`).
#
# Rebuild via `docker compose build hermes` after editing
# `hermes-skills/`.
# Pinned to the successful LuminaVaultHermesAgent build for source commit
# 24cac9200f35b261694f91dd873507c9eec9792a. Bump deliberately only after its
# API tests and GHCR image workflow pass.
FROM ghcr.io/luminavault/luminavault-hermes-agent@sha256:715a4f77305970cdf8f521eceff3de89761ab629c8f1949d0b13ef2b0fe01f39

# HER-XXX — bake Mnemosyne (Hermes Agent's native memory provider) into the
# image so every tenant gets persistent agent memory out of the box. It is
# wired via the `mcp.servers.mnemosyne` block in each tenant's config.yaml
# (HermesTenantConfigTemplate): Hermes spawns `mnemosyne mcp` as a stdio MCP
# subprocess and registers its remember/recall/triples tools.
#
# Isolation rationale:
#   * The base image's Hermes runs on Python 3.13 and has no pip (uv-managed
#     venv). Mnemosyne's `[all]` extra (fastembed, llama-cpp-python,
#     ctransformers) targets Python <=3.12, so we install it into a SEPARATE
#     uv-managed 3.12 venv and never touch Hermes's own venv.
#   * The MCP server is a subprocess, so it only needs `mnemosyne` on PATH —
#     it does not have to share Hermes's interpreter.
#   * We symlink the console script into `/usr/local/bin` (NOT
#     `/opt/data/.local/bin`, which the runtime `/opt/data` bind-mount
#     shadows — see entrypoint note).
#   * `MNEMOSYNE_DATA_DIR` + the fastembed cache live under `/opt/data` so the
#     SQLite store and the embedding model persist on the per-tenant volume
#     (Mnemosyne's `~/.hermes` default can resolve off-volume when HOME differs
#     from HERMES_HOME).
ENV UV_LINK_MODE=copy \
    MNEMOSYNE_DATA_DIR=/opt/data/mnemosyne \
    FASTEMBED_CACHE_PATH=/opt/data/mnemosyne/cache
# The base image already ships a uv-managed CPython under /root/.local/share/uv
# (mode 700). `uv venv --python 3.12` would reuse it, so the venv's python
# symlink points into /root and the unprivileged `hermes` runtime user can't
# traverse it → MCP spawn fails with EACCES (and HERMES_HOME=/opt/data is
# bind-mounted, so we can't rely on it either). So we install a *fresh* 3.12
# explicitly under /opt/uv-python, build the venv against that absolute path,
# and chmod a+rX so any uid (the base may remap HERMES_UID) can read/traverse/
# exec it. The `gosu hermes` line asserts this for real at build time — `su`
# does NOT drop privileges in this base image, so it would falsely pass.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends build-essential cmake; \
    uv python install 3.12 --install-dir /opt/uv-python; \
    PYBIN="$(ls -d /opt/uv-python/cpython-3.12*/bin/python3.12 | head -1)"; \
    uv venv --python "$PYBIN" /opt/mnemosyne-venv; \
    uv pip install --python /opt/mnemosyne-venv/bin/python "mnemosyne-memory[all]==3.1.2"; \
    # mnemosyne pins `mcp>=1.0.0`; align it to the version Hermes's own venv
    # ships (1.26.0) so the stdio initialize handshake isn't rejected.
    uv pip install --python /opt/mnemosyne-venv/bin/python "mcp==1.26.0"; \
    ln -sf /opt/mnemosyne-venv/bin/mnemosyne /usr/local/bin/mnemosyne; \
    chmod -R a+rX /opt/uv-python /opt/mnemosyne-venv; \
    gosu hermes /usr/local/bin/mnemosyne --help >/dev/null; \
    apt-get purge -y build-essential cmake; apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

# Bake the Mnemosyne MCP registration into Hermes's default config example so
# the central Hermes (and any fresh per-tenant volume) that copies the example
# on first boot gets memory wired out of the box. Per-tenant containers normally
# use the seeded config.yaml (HermesTenantConfigTemplate), which carries the
# same `mcp_servers.mnemosyne` block. The example only has a *commented*
# `mcp_servers:` sample, so appending one real top-level block is valid YAML.
RUN printf '\n# HER-XXX — Mnemosyne memory MCP server (baked default)\nmcp_servers:\n  mnemosyne:\n    command: mnemosyne\n    args: ["mcp"]\n    env:\n      MNEMOSYNE_DATA_DIR: /opt/data/mnemosyne\n      FASTEMBED_CACHE_PATH: /opt/data/mnemosyne/cache\n' >> /opt/hermes/cli-config.yaml.example

# Baked layout — read-only inside the container. The runtime path
# (`/opt/data/skills/`) is populated by the entrypoint on each start.
COPY hermes-skills/ /opt/baked-skills/

# Idempotent seed: no-clobber copy preserves user-edited skill files
# under the bind-mounted `/opt/data` volume.
COPY docker/hermes-entrypoint.sh /usr/local/bin/hermes-entrypoint.sh
RUN chmod +x /usr/local/bin/hermes-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/hermes-entrypoint.sh"]
CMD ["gateway", "run"]
