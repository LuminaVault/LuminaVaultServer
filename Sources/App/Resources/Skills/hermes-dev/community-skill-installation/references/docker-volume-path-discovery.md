# Docker Volume Path Discovery — Quick Reference

## Problem

Hermes runs inside Docker with bind mounts. The host's Hermes directory (`~/.hermes/`) may **not** be at `/root/.hermes/` on the host — it could be anywhere depending on `docker-compose.yml`.

## Discovery Commands

```bash
# 1. Find docker-compose.yml on the host
find / -name "docker-compose.yml" -path "*hermes*" 2>/dev/null

# Common locations:
#   /root/.hermes/docker-compose.yml
#   /opt/data/hermes/docker-compose.yml
#   /srv/hermes/docker-compose.yml

# 2. Check volumes section
grep -A5 "volumes:" /path/to/docker-compose.yml

# Example output:
#   services:
#     hermes:
#       volumes:
#         - /opt/data/home/.hermes:/root/.hermes   <── HOST PATH is /opt/data/home/.hermes
#         - /opt/data/obsidian-vault:/root/obsidian
```

## Path Mapping Table

| Container Path | Possible Host Paths |
|---|---|
| `/root/.hermes/` | `/opt/data/home/.hermes/`, `/srv/hermes/`, `/opt/data/.hermes/` |
| `/root/.hermes/skills/` | `<host-path>/skills/` |
| `/root/.hermes/scripts/` | `<host-path>/scripts/` |

## Verification

```bash
# Check which path ACTUALLY exists on the host (run on VPS as root)
if [ -d /opt/data/home/.hermes/skills/ ]; then
    echo "HOST SKILLS PATH: /opt/data/home/.hermes/skills/"
    cp -r /tmp/my-skill /opt/data/home/.hermes/skills/
elif [ -d /root/.hermes/skills/ ]; then
    echo "HOST SKILLS PATH: /root/.hermes/skills/"
    cp -r /tmp/my-skill /root/.hermes/skills/
else
    echo "❌ Cannot find Hermes skills directory"
    find / -type d -name "skills" -path "*hermes*" 2>/dev/null | head -5
fi
```

## Quick Copy Pattern

```bash
# Determine host path automatically
HOST_HERMES=$(find /opt/data /srv /root -type d -name ".hermes" 2>/dev/null | head -1)
if [ -n "$HOST_HERMES" ]; then
    echo "Found Hermes at: $HOST_HERMES"
    cp -r /tmp/community-skill "$HOST_HERMES/skills/"
else
    echo "Error: locate Hermes home directory first"
    exit 1
fi
```

## Related

- `community-skill-installation` — main skill for installing community skills
- Session: 2026-05-02 — installed 5 community skills from GitTrend X article; discovered path mismatch between `/opt/data/.hermes/` and `/opt/data/home/.hermes/`
