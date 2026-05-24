#!/usr/bin/env python3
"""
Weekly Sprint Report — Fandemic (Backend + iOS teams)
Velocity, cycle time, aging, state breakdown across both teams.
"""

import http.client, json, os, datetime, sys
from collections import defaultdict

API_KEY = "<LINEAR_API_KEY>"
TEAM_IDS = {
    "BACK": "c6fbde7e-4792-40ec-a9a1-73b7942d7351",
    "IOS":  "532cb4dd-8a4d-48d8-9db5-c199fb4c5dd3",
}
LINEAR_URL = "api.linear.app"

now = datetime.datetime.now(datetime.timezone.utc)
week_ago = (now - datetime.timedelta(days=7)).isoformat()

def gql(query, variables=None):
    conn = http.client.HTTPSConnection(LINEAR_URL, timeout=20)
    payload = {"query": query}
    if variables:
        payload["variables"] = variables
    conn.request("POST", "/graphql",
                 body=json.dumps(payload),
                 headers={"Authorization": API_KEY, "Content-Type": "application/json"})
    resp = conn.getresponse()
    body = resp.read().decode()
    conn.close()
    data = json.loads(body)
    if "errors" in data:
        raise Exception(f"GraphQL: {data['errors'][0]['message']}")
    return data["data"]

# Fetch all issues for both teams
all_issues = []
for team_key, team_id in TEAM_IDS.items():
    try:
        data = gql(f'''
        {{
          issues(
            first: 100,
            filter: {{ team: {{ id: {{ eq: "{team_id}" }} }} }},
            orderBy: updatedAt
          ) {{
            nodes {{
              id identifier title
              state {{ id name type }}
              priority createdAt completedAt updatedAt
            }}
          }}
        }}
        '''.replace('\n',' '))
        for issue in data["issues"]["nodes"]:
            issue["_team_key"] = team_key
            all_issues.append(issue)
    except Exception as e:
        print(f"⚠️  Error fetching {team_key}: {e}", file=sys.stderr)

# ─── Metrics ───
completed_last_week = []
in_progress = []
aged_p0_p1 = []
aged_backlog = []

for issue in all_issues:
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

    if priority <= 1 and updated < (now - datetime.timedelta(days=14)):
        aged_p0_p1.append(issue)

    if state in ("Todo", "Backlog") and created < (now - datetime.timedelta(days=30)):
        aged_backlog.append(issue)

throughput = len(completed_last_week)

# ─── Report ───
week_end = now.strftime("%b %d, %Y")
week_start = (now - datetime.timedelta(days=7)).strftime("%b %d")
print(f"# 📈 Fandemic Sprint Report — {week_start} → {week_end}\n")
print(f"_Backend + iOS teams | {len(all_issues)} total issues | {throughput} completed this week_\n")

# Velocity
print("## 🏃 Velocity\n")
print(f"**{throughput}** issue(s) completed this week")
if throughput > 0:
    avg_prio = sum(i["priority"] for i in completed_last_week) / throughput
    print(f"_Avg priority of completed: {avg_prio:.1f} (lower = higher priority)_")
print("")

# Active work
print("## 🔄 In Progress / In Review\n")
print(f"**{len(in_progress)}** active issue(s):\n")
by_team_active = defaultdict(list)
for issue in in_progress:
    by_team_active[issue["_team_key"]].append(issue)
for team_key in ["BACK", "IOS"]:
    team_issues = by_team_active[team_key]
    if team_issues:
        icon = "🔧" if team_key == "BACK" else "📱"
        print(f"### {icon} {team_key}\n")
        for issue in sorted(team_issues, key=lambda x: x["priority"]):
            print(f"- [{issue['priority']}] **{issue['identifier']}** {issue['title'][:60]}")
        print("")
print("")

# Aging alerts
if aged_p0_p1:
    print("## 🔥 Aged Critical (P0/P1, >14 days)\n")
    for issue in aged_p0_p1:
        print(f"- **{issue['identifier']}** [{issue['priority']}] {issue['title'][:55]}")
        print(f"  _{issue['state']['name']} · Last updated: {issue['updatedAt'][:10]}_")
    print("")

if aged_backlog:
    print("## 📦 Aged Backlog (>30 days)\n")
    for issue in aged_backlog[:10]:
        print(f"- **{issue['identifier']}** — {issue['title'][:55]}")
        print(f"  _Created: {issue['createdAt'][:10]}_")
    print("")

# State breakdown (combined)
print("## 📋 State Distribution (across both teams)\n")
state_counts = defaultdict(int)
for issue in all_issues:
    state_counts[issue["state"]["name"]] += 1
for state, count in sorted(state_counts.items()):
    print(f"- **{state}**: {count}")
print("")

print("---")
print(f"📬 [Backend Linear](https://linear.app/team/BACK) · [iOS Linear](https://linear.app/team/IOS)")
print(f"Generated: {now.isoformat()[:19]}Z")
