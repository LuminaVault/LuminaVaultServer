# Scheduled Cron Job — Template

**Job ID:** `unique-id-here`  
**Name:** Descriptive name (e.g., `twice-daily-news-digest`)  
**Schedule:** Cron expression (e.g., `0 9,21 * * *` = 9 AM & 9 PM daily)  
**Deliver Target:** `origin` | `discord:CHANNEL_ID` | `telegram` | custom  
**Enabled:** `true` / `false`

---

## Purpose

Brief description of what this job does and why it exists.

## Script

**Path:** `/abs/path/to/script.py`  
**Args:** (if any)  
**Working Directory:** `/opt/data/home/.hermes` (usually)

## Script Contract

The script **must** adhere to this contract:

1. **Write ONLY the final digest to `stdout`** — no debug prints, no logging to stdout
2. **Write logs and errors to `stderr`** or a file
3. **Exit code 0 on success**, non-zero on failure
4. **Output format:** Markdown with clear section headings (`## Category`)

## Example Implementation

```python
#!/usr/bin/env python3
"""Job description."""

import sys

def generate_digest():
    # ... fetch/process data ...
    return "# Digest\n\n## Cat\n• item\n"

def main():
    try:
        content = generate_digest()
        print(content)  # ONLY this goes to stdout
        sys.exit(0)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
```

## Cron Job JSON Entry

```json
{
  "id": "twice-daily-news-digest",
  "name": "Twice-Daily News Digest",
  "script": "/opt/data/home/.hermes/scripts/news_digest.py",
  "workdir": "/opt/data/home/.hermes",
  "schedule": "0 9,21 * * *",
  "repeat": false,
  "enabled": true,
  "deliver": "origin",
  "skill": null,
  "model": null,
  "provider": null,
  "base_url": null,
  "context_from": null,
  "prompt": null,
  "enabled_toolsets": [],
  "state": "active",
  "last_run_at": null,
  "last_status": null,
  "last_error": null,
  "last_delivery_error": null
}
```

## Verification Checklist

- [ ] Script runs standalone: `python3 /path/to/script.py` prints digest only
- [ ] Digest length ≤ 2000 chars OR batching strategy implemented
- [ ] Exit code 0 on success, non-zero on failure
- [ ] No stdout pollution (use `stderr` for logs)
- [ ] `deliver` target correctly set (`origin` for debugging; `discord:ID` for production)
- [ ] Bot has permissions in target channel (if Discord)
- [ ] Schedule cron expression verified (next run time correct)
- [ ] Tested with `verify_cron_delivery.py` script

## Post-Deployment

```bash
# Check job status
hermes cron status <job-id>

# View recent runs
hermes cron logs <job-id> --tail 5

# Run manually (triggers delivery via deliver target)
hermes cron run <job-id>

# Test dry-run (no delivery)
python3 /opt/data/skills/cron-deployment/scheduled-delivery/scripts/verify_cron_delivery.py /path/to/script.py
```

## Common Pitfalls

See main `scheduled-delivery` skill SKILL.md for the full troubleshooting guide.

## Notes

Add job-specific notes here (special data sources, rate limits, dependencies).
