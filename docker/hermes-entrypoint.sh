#!/bin/sh
# HER-276 — seed baked kb-* skills into the mounted HERMES_HOME tree on
# container start. `cp -rn` is the no-clobber variant: existing skill
# files under the volume (host-edited or persisted runtime state) are
# preserved. New skills baked into the image since the volume was last
# populated land on next start.
set -eu

HERMES_HOME="${HERMES_HOME:-/opt/data}"
BAKED="/opt/baked-skills"
TARGET="${HERMES_HOME}/skills"

if [ -d "${BAKED}" ]; then
    mkdir -p "${TARGET}"
    # `-n` no-clobber: never overwrite an existing file. Lets the dev
    # edit a skill in `data/hermes/skills/` for fast iteration without
    # losing the change on next image rebuild.
    cp -Rn "${BAKED}/." "${TARGET}/" 2>/dev/null || true
fi

# Hand off to the base image's documented entrypoint, which bootstraps the
# runtime env and launches the `hermes` CLI. CMD (`gateway run`) flows through
# as "$@". We do NOT call `hermes` directly — it is not on the default PATH
# (the base startup is what makes it runnable, and the `/opt/data` bind mount
# shadows `/opt/data/.local/bin`). tini is preserved for PID-1 signal handling
# and zombie reaping of hermes' subprocesses.
exec /usr/bin/tini -g -- /opt/hermes/docker/entrypoint.sh "$@"
