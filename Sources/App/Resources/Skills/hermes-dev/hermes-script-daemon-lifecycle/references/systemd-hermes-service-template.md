# Systemd Hermes Service — Unit File Reference

This document describes the production-ready systemd unit file template for Hermes daemons. Copy from `templates/systemd-hermes-service.service` and customize per-script.

## Why Systemd Over Wrapper Scripts

- **Supervision**: `Restart=on-failure` auto-recovers from crashes
- **Logging**: journald captures stdout/stderr with timestamps, filtering, rotation
- **Lifecycle**: Clean start/stop/restart via `systemctl --user`
- **Resource control**: CPU/memory limits, start-after-network
- **No double-loop deadlock**: systemd spawns the process once; script manages its own internal loop

## Minimal Viable Unit

```ini
[Unit]
Description=Hermes X Link Poller
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u /opt/data/home/.hermes/scripts/x_link_poller_v2.py
Restart=on-failure

[Install]
WantedBy=default.target
```

Save to: `~/.config/systemd/user/hermes-x-link-poller.service`

## Full Options Explained

### [Unit] Section

| Option | Meaning |
|--------|---------|
| `Description` | Human-readable name in `systemctl status` |
| `After=network-online.target` | Wait until network is up (prevents early start before network) |
| `Wants=network-online.target` | Pull in network-online.target if not already |

### [Service] Section

| Option | Meaning |
|--------|---------|
| `Type=simple` | Process runs in foreground; systemd considers it started after ExecStart returns |
| `User=1000` | Run as this user (omit to run as current user) |
| `WorkingDirectory` | CWD for the process (use for relative paths) |
| `EnvironmentFile` | Load env vars from file (Hermes: `/opt/data/.env`) |
| `ExecStart` | The command to run (must be absolute path) |
| `StandardOutput=journal` | Send stdout to journald |
| `StandardError=journal` | Send stderr to journald |
| `Restart=on-failure` | Restart if process exits non-zero |
| `RestartSec=10` | Wait 10s before restarting |
| `StartLimitBurst=3` | Max 3 restarts in `StartLimitIntervalSec` |

### [Install] Section

| Option | Meaning |
|--------|---------|
| `WantedBy=default.target` | Enable for user login session |
| `WantedBy=multi-user.target` | Enable system-wide at boot |

## Per-Script Customization Examples

### x_link_poller_v2.py

```bash
# Unit name: hermes-x-link-poller.service
unit_file = ~/.config/systemd/user/hermes-x-link-poller.service

contents = f'''
[Unit]
Description=Hermes X Link Poller v2
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=1000
WorkingDirectory=/opt/data/home/.hermes
EnvironmentFile=/opt/data/.env
ExecStart=/usr/bin/python3 -u /opt/data/home/.hermes/scripts/x_link_poller_v2.py
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
'''
```

### hermes-agent.py (if it has internal loop)

Same pattern — script's own `while True` + sleep handles cadence. systemd just keeps it alive.

## Common Pitfalls & Fixes

### "Failed to connect to bus: No such file or directory"

Root cause: `systemctl --user` needs XDG_RUNTIME_DIR set.

```bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
systemctl --user daemon-reload
```

If running in cron or non-interactive shell, add the export to the crontab line.

### "Unit hermes-xxx.service not found"

After creating/modifying unit file:
```bash
systemctl --user daemon-reload
# Then try again
systemctl --user status hermes-xxx.service
```

### "Permission denied" on vault or log paths

Ensure the `User=` in the unit file matches the owner of the vault/log directories.
```bash
ls -ld /opt/data/obsidian-vault /opt/data/home/.hermes/logs
# Should be owned by the User= (typically uid 1000)
```

### Environment variables not loading

Verify `.env` file format and permissions:
```bash
head -5 /opt/data/.env
# Should have lines like: DISCORD_BOT_TOKEN=xyz
ls -l /opt/data/.env  # readable by User=
```

Test with manual source:
```bash
source /opt/data/.env && python3 script.py  # Does it work?
```

If variables contain spaces or special chars, ensure they're quoted in `.env`.

### Logs not appearing in journalctl

Check `StandardOutput=` setting:
- `journal` → journald only
- `append:/path/file.log` → file only
- `journal+append:/path/file.log` → both

For debugging, temporarily set to file to tail directly:
```ini
StandardOutput=append:/tmp/hermes-debug.log
StandardError=append:/tmp/hermes-debug.log
```

Then:
```bash
tail -f /tmp/hermes-debug.log
```

### Script crashes immediately

View the actual error:
```bash
journalctl --user -u hermes-xxx.service -n 50 --no-pager
# Look for "Traceback" or "Error"
```

Common causes:
- Wrong `ExecStart` path
- Missing Python module: `pip install <module>`
- `.env` variable not set
- Vault directory not mounted/accessible

### Service starts but does nothing

Check:
1. Script has internal loop? If not, it will exit immediately after one cycle → set `Restart=always` instead of `on-failure`.
2. Network dependencies: ensure `After=network-online.target` (not just `network.target`)
3. Credentials: validate tokens via environment

### Resource exhaustion (OOM, CPU spike)

Add limits:
```ini
MemoryLimit=500M
CPUQuota=50%
```

## Managing Multiple Hermes Daemons

Use consistent naming: `hermes-<script-base>.service`

```bash
# List all Hermes services
systemctl --user list-units --type=service | grep hermes

# Start all
for svc in $(systemctl --user list-unit-files | grep hermes | awk '{print $1}'); do
  systemctl --user start $svc
done

# Check all statuses
systemctl --user status hermes-*.service
```

## Monitoring

```bash
# Tail all Hermes daemon logs
journalctl --user -f -u hermes-*.service

# Show recent restarts (crash indicator)
journalctl --user -u hermes-x-link-poller.service | grep -i 'start.*succeeded'

# Systemd failure stats
systemctl --user status hermes-x-link-poller.service
# Look for: "Loaded: loaded (...; enabled; vendor preset: enabled)"
#           "Active: active (running) since ..."
```

## Migration Checklist

When moving from wrapper script → systemd:

- [ ] Stop and kill wrapper: `pkill -f "while true.*script.py"`
- [ ] Create unit file in `~/.config/systemd/user/`
- [ ] `systemctl --user daemon-reload`
- [ ] `systemctl --user enable --now hermes-<name>.service`
- [ ] Verify single process: `ps aux | grep script.py | grep -v grep` (should be exactly 1)
- [ ] Check journal: `journalctl --user -u hermes-<name>.service -f`
- [ ] Wait one cycle; verify vault files appear
- [ ] Disable wrapper cron/systemd if it still exists

## Hermes Conventions

Follow these for all Hermes daemons:

| Convention | Value |
|------------|-------|
| Log format | `/opt/data/home/.hermes/logs/<script>_%Y%m%d.log` (if file-logging) |
| State file | `~/.hermes/state/<script>_state.json` |
| Vault root | `/opt/data/obsidian-vault/FACorreia` |
| Env file | `/opt/data/.env` (source before start) |
| User | Typically `1000` (the hermes user) |

Keep these consistent so `hermes-daemon-health.py` works universally.
