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
# Pinned by digest (was `:latest`) — `:latest` drift moved the hermes binary
# layout on 2026-05-29 and broke startup (exit 127). Digest maps to the
# `:latest` tag as of that date. Bump deliberately after verifying startup.
FROM nousresearch/hermes-agent:latest@sha256:b6e41c155d6bfce5ad83c5d0fec670086db8a43250e4511c9474134be5482d33

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
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends build-essential cmake; \
    uv venv --python 3.12 /opt/mnemosyne-venv; \
    uv pip install --python /opt/mnemosyne-venv/bin/python "mnemosyne-memory[all]==3.1.2"; \
    ln -sf /opt/mnemosyne-venv/bin/mnemosyne /usr/local/bin/mnemosyne; \
    /usr/local/bin/mnemosyne --help >/dev/null; \
    apt-get purge -y build-essential cmake; apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

# Baked layout — read-only inside the container. The runtime path
# (`/opt/data/skills/`) is populated by the entrypoint on each start.
COPY hermes-skills/ /opt/baked-skills/

# Idempotent seed: no-clobber copy preserves user-edited skill files
# under the bind-mounted `/opt/data` volume.
COPY docker/hermes-entrypoint.sh /usr/local/bin/hermes-entrypoint.sh
RUN chmod +x /usr/local/bin/hermes-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/hermes-entrypoint.sh"]
CMD ["gateway", "run"]
