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
FROM nousresearch/hermes-agent:latest

# Baked layout — read-only inside the container. The runtime path
# (`/opt/data/skills/`) is populated by the entrypoint on each start.
COPY hermes-skills/ /opt/baked-skills/

# Idempotent seed: no-clobber copy preserves user-edited skill files
# under the bind-mounted `/opt/data` volume.
COPY docker/hermes-entrypoint.sh /usr/local/bin/hermes-entrypoint.sh
RUN chmod +x /usr/local/bin/hermes-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/hermes-entrypoint.sh"]
CMD ["gateway", "run"]
