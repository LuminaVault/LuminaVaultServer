# Fandemic Linear Integration

## Overview
Automated workflows for the Fandemic Linear workspace (2 teams: Backend + iOS).

**User**: fernando (fernando@fandemicapp.com)  
**API Key**: `<LINEAR_API_KEY>`

---

## 📁 Scripts (`~/.hermes/scripts/`)

| Script | Purpose |
|--------|---------|
| `fandemic_daily_digest.py` | Issues updated in last 24h (both teams combined) |
| `fandemic_weekly_sprint.py` | Velocity, throughput, aging issues, state distribution |
| `fandemic_weekly_export.py` | Weekly JSON + CSV backup of all issues |
| `fandemic_webhook_listener.py` | HTTP daemon — create issues via POST |
| `fandemic_webhook_daemon.py` | Start/stop/restart helper |

---

## 🕐 Cron Jobs (12 total — 3 platforms × 4 workflows)

| Schedule | Job | Delivery |
|----------|-----|----------|
| Daily 9:00 AM | `fandemic-daily-digest-{discord,telegram,slack}` | origin / telegram / slack |
| Weekly Sun 11:00 PM | `fandemic-weekly-sprint-{discord,telegram,slack}` | origin / telegram / slack |
| Weekly Sat 10:00 AM | `fandemic-weekly-export-{discord,telegram,slack}` | origin / telegram / slack |

Job IDs:
- Daily digest: `1a2ba7c90c1d` (Discord), `c15240d9ab04` (Telegram), `b980ba4f8ebd` (Slack)
- Weekly sprint: `ee982633560e` (Discord), `45b56af9bd5b` (Telegram), `50757ffa0067` (Slack)
- Weekly export: `c890844914df` (Discord), `51d2c5686bc8` (Telegram), `f42a86e75c2f` (Slack)

---

## 🔌 Webhook Listener (Port 8081)

**Start daemon:**
```bash
python3 ~/.hermes/scripts/fandemic_webhook_daemon.py start
```

**Endpoint:** `POST http://localhost:8081/webhooks/fandemic`

**Payload (JSON):**
```json
{
  "title": "Short summary",
  "description": "Detailed body — markdown supported",
  "priority": 1,
  "labels": ["Bug", "Feature"],
  "team": "BACK",                    // required: "BACK" or "IOS"
  "project": "Post Release Sprint",  // optional (one of: Post Release Sprint, Project Smart Sheets, 1.2.1)
  "assignee": "fernando"             // optional (fernando, ajmal, or shubham@...)
}
```

**Response:**
```json
{
  "status": "created",
  "identifier": "BACK-144",
  "url": "https://linear.app/team/BACK/issue/..."
}
```

**Notes:**
- Priority: 1=high, 2=medium, 3=low, 4=none/default
- Labels are team-specific:
  - **Backend**: `Feature`, `Bug`, `Improvement`
  - **iOS**: `backend`, `Feature`, `Bug`, `Improvement`
- If `team` is omitted, you get a 400 error. Only BACK and IOS are valid.

---

## 🔐 Auth & Team IDs

| Team | Key | ID |
|------|-----|----|
| Backend | `BACK` | `c6fbde7e-4792-40ec-a9a1-73b7942d7351` |
| iOS | `IOS` | `532cb4dd-8a4d-48d8-9db5-c199fb4c5dd3` |

API auth: **raw key** (no `Bearer ` prefix).

---

## 📂 Export Location

Weekly backups: `~/.cache/hermes/linear_exports/fandemic-2026-W17/`

Files:
- `issues.json` — full GraphQL response
- `issues.csv` — flattened (identifier, title, state, priority, team, project, assignee, dates)

---

## 🧩 Integration Notes

- Fandemic has **2 Linear teams** (Backend + iOS). Reports combine both by default.
- No projects are currently assigned to most issues — `project` field often `null`.
- Webhook listener on **port 8081** does not conflict with StockPlan's port 8080.
- All scripts use `http.client` (stdlib) — no external dependencies.

---

**Generated 2026-04-27 — Hermes Agent**  
_Workspace: Fandemic (fernando@fandemicapp.com)_
