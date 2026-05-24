#!/usr/bin/env python3
"""
Weekly Linear Sprint Report — StockPlan team
Calculates throughput, cycle time, aging issues, and burn-down metrics.

Output: Markdown to stdout (cron delivers to Discord/Telegram/Slack — you choose per job).
"""

import http.client, json, os, datetime, sys
from collections import defaultdict

API_KEY = "<LINEAR_API_KEY>"
TEAM_ID = "fc9cf858-9a37-4215-ba7e-bae0eae499cc"
LINEAR_URL = "api.linear.app"

now = datetime.datetime.now(datetime.timezone.utc)
week_ago = (now - datetime.timedelta(days=7)).isoformat()

def gql(query):
    conn = http.client.HTTPSConnection(LINEAR_URL, timeout=20)
    payload = json.dumps({"query": query})
    headers = {"Authorization": API_KEY, "Content-Type": "application/json"}
    conn.request("POST", "/graphql", body=payload, headers=headers)
    resp = conn.getresponse()
    body = resp.read().decode()
    conn.close()
    data = json.loads(body)
    if "errors" in data:
        raise Exception(f"GraphQL: {data['errors'][0]['message']}")
    return data["data"]

# ─── Fetch all issues (minimal fields) ───
try:
    all_issues = gql(f'''
    {{
      issues(
        first: 100,
        filter: {{ team: {{ id: {{ eq: "{TEAM_ID}" }} }} }},
        orderBy: updatedAt
      ) {{
        nodes {{
          id identifier title
          state {{ id name type }}
          priority createdAt completedAt updatedAt
        }}
      }}
    }}
    '''.replace('\n', ' '))
except Exception as e:
    print(f"❌ Error fetching Linear issues: {e}")
    sys.exit(1)

issues = all_issues["issues"]["nodes"]

# ─── Metrics ───
completed_last_week = []
in_progress = []
aged_critical = []
aged_backlog = []

for issue in issues:
    priority = issue.get("priority", 3)
    created = datetime.datetime.fromisoformat(issue["createdAt"].replace("Z","+00:00"))
    updated = datetime.datetime.fromisoformat(issue["updatedAt"].replace("Z","+00:00"))
    state = issue["state"]["name"]

    if state == "Done" and issue.get("completedAt"):
        completed = datetime.datetime.fromisoformat(issue["completedAt"].replace("Z","+00:00"))
        if completed >= datetime.datetime.fromisoformat(week_ago):
            completed_last_week.append(issue)

    if state in ("In Progress", "In Review"):
        in_progress.append(issue)

    if priority <= 2 and updated < (now - datetime.timedelta(days=14)):
        aged_critical.append(issue)

    if state in ("Todo", "Backlog") and created < (now - datetime.timedelta(days=30)):
        aged_backlog.append(issue)

throughput = len(completed_last_week)

# ─── Markdown output ───
week_end = now.strftime("%b %d, %Y")
week_start = (now - datetime.timedelta(days=7)).strftime("%b %d")
print(f"# 📈 Linear Sprint Report — {week_start} → {week_end}\n")
print(f"_StockPlan team | {len(issues)} total issues | {throughput} completed this week_\n")

# Throughput & Velocity
print("## 🏃 Velocity\n")
print(f"**{throughput}** issue(s) completed this week")
if throughput > 0:
    avg_prio = sum(i["priority"] for i in completed_last_week) / throughput
    print(f"_Average priority of completed: {avg_prio:.1f} (lower = higher priority)_")
print("")

# In-Progress & Aging
print("## 🔄 In Progress / In Review\n")
print(f"**{len(in_progress)}** active issue(s):\n")
for issue in sorted(in_progress, key=lambda x: x["priority"]):
    assignee = "unassigned"
    print(f"- [{issue['priority']}] **{issue['identifier']}** {issue['title'][:60]}")
    if assignee:
        print(f"  _{assignee} · updated {issue['updatedAt'][:10]}_")
print("")

# Aging Alerts
if aged_critical:
    print("## 🔥 Aged Critical Issues (>14 days)\n")
    for issue in aged_critical:
        print(f"- **{issue['identifier']}** [{issue['priority']}] {issue['title'][:55]}")
        print(f"  _State: {issue['state']['name']} · Last updated: {issue['updatedAt'][:10]}_")
    print("")

if aged_backlog:
    print("## 📦 Aged Backlog (>30 days)\n")
    for issue in aged_backlog[:10]:
        print(f"- **{issue['identifier']}** — {issue['title'][:55]}")
        print(f"  _Created: {issue['createdAt'][:10]}_")
    print("")

# State breakdown
print("## 📋 State Distribution\n")
state_counts = defaultdict(int)
for issue in issues:
    state_counts[issue["state"]["name"]] += 1
for state, count in sorted(state_counts.items()):
    print(f"- **{state}**: {count}")
print("")

print("---")
print(f"📬 [Open Linear → StockPlan](https://linear.app/team/STO)")
print(f"Generated: {now.isoformat()[:19]}Z")
