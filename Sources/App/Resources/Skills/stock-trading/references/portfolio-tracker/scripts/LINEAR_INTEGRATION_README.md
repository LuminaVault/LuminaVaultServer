# Linear Integration — StockPlan

## Overview
4 automated workflows for Linear (StockPlan team, `STO`) integrated with Hermes cron system.

---

## 📁 Scripts (all in `~/.hermes/scripts/`)

| Script | Purpose | Output format |
|--------|---------|---------------|
| `linear_daily_digest.py` | Issues updated in last 24h — new, moved, closed | Markdown digest |
| `linear_weekly_sprint.py` | Velocity, throughput, aging, state breakdown | Markdown report |
| `linear_export.py` | Full issue dump → JSON + CSV | Files in `~/.cache/hermes/linear_exports/` |
| `linear_webhook_listener.py` | HTTP daemon — create issues from external events | Runs on port 8080 |

**Daemon launcher**: `linear_webhook_daemon.py` — start/stop/restart/status helper.

---

## 🕐 Cron Jobs (per-platform duplication)

| Schedule | Job | Platforms | Description |
|----------|-----|-----------|-------------|
| **Daily 9:00 AM** | `linear-daily-digest-*` | Discord, Telegram, Slack | Yesterday's issue activity |
| **Weekly Sun 11:00 PM** | `linear-weekly-sprint-*` | Discord, Telegram, Slack | Sprint metrics + burn-down |
| **Weekly Sat 10:00 AM** | `linear-weekly-export-*` | Discord, Telegram, Slack | JSON/CSV backup (notification only) |

Job IDs (for reference):
- Daily digest: `689f5e2508e0` (Discord), `5b7d642db67b` (Telegram), `7e5375b896ae` (Slack)
- Weekly sprint: `dd442303dc87` (Discord), `3ba54b65a28d` (Telegram), `f77e0304d439` (Slack)
- Weekly export: `70f69ae2de8b` (Discord), `8ea736f2564c` (Telegram), `00ba213d1717` (Slack)

---

## 🔌 Webhook Listener (Event-driven ticket creation)

**Start the daemon**:
```bash
python3 ~/.hermes/scripts/linear_webhook_daemon.py start
```

**Endpoint**: `POST http://localhost:8080/webhooks/linear`

**Payload** (application/json):
```json
{
  "title": "Brief summary of the issue",
  "description": "Detailed description — markdown supported",
  "priority": 1,
  "labels": ["Bug", "MVP"],
  "project": "StockPlan MVP",
  "assignee": "Fernando Correia"
}
```

**Response** (JSON):
```json
{
  "status": "created",
  "identifier": "STO-68",
  "url": "https://linear.app/team/STO/issue/..."
}
```

**Supported label names**: `MVP`, `Post-MVP`, `Bug`, `Improvement`, `Feature`

**Priority**: 1=high, 2=medium, 3=low, 4=none (default: 2)

Default project is "StockPlan MVP" if omitted. Assignee resolves by current viewer (Fernando) unless a team member name is given.

---

## 🔐 Auth Details
- **API key**: `<LINEAR_API_KEY>`
- **Auth header**: Raw key (no "Bearer " prefix) — this is critical, Linear rejects Bearer.
- **Team**: StockPlan (`STO`) — ID `fc9cf858-9a37-4215-ba7e-bae0eae499cc`
- **Base URL**: `https://api.linear.app/graphql`

---

## 📂 Export Location
Weekly backups: `~/.cache/hermes/linear_exports/2026-W17/` (ISO week-based)

Files:
- `issues.json` — full GraphQL payload
- `issues.csv` — flattened for spreadsheets (identifier, title, state, priority, project, assignee, dates)

---

## 🚨 Troubleshooting

**Cron job not firing?**
- Check workdir: `/opt/data/home/.hermes/scripts` (not `~/.hermes/scripts` — tilde expands differently in cron)
- All scripts are executable (`chmod +x` already set)

**Webhook returns 400/500?**
- Check port 8080 not in use (`lsof -i :8080`)
- Review logs: `tail -f /tmp/linear_webhook.log`
- Payload must have `title` + `description`; `labels` must match team labels exactly

**API limit/rate limit?**
Linear allows ~150 requests/minute per token — our schedule is minimal (~4 queries daily). Safe.

**Want to add Notion export?**
The export script can be extended with the Notion skill to push issues into a StockPlan issues DB.

---

## 🧩 Integration Ideas

- GitHub → Linear sync: on PR opened, create linked Linear issue (use `github-issues` skill + PR webhook → your Linear webhook)
- Stock price spike alerts: From your StockPlan backend, POST to `/webhooks/linear` when a watched ticker moves >5%
- Daily standup bot: Combine Linear daily digest + your calendar + recent git commits into one morning briefing
- Notion portfolio tracker: Export weekly → Notion table → automated weekly report PDF

---

_Generated 2026-04-27 — Hermes Agent v3_
