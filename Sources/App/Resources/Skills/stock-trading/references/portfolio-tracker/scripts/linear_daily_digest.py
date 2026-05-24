#!/usr/bin/env python3
"""
Daily Linear Issue Digest — StockPlan team
Fetches issues updated in the last 24 hours and formats a Markdown report.

Output: Markdown to stdout (cron delivers to Discord/Telegram/Slack).
"""

import http.client, json, os, datetime, sys

# ─── Config ───
API_KEY = "<LINEAR_API_KEY>"
TEAM_ID = "fc9cf858-9a37-4215-ba7e-bae0eae499cc"
LINEAR_URL = "api.linear.app"
DAY_AGO = (datetime.datetime.now(datetime.timezone.utc) -
           datetime.timedelta(days=1)).isoformat()

# ─── GraphQL client ───
def gql(query):
    conn = http.client.HTTPSConnection(LINEAR_URL, timeout=15)
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

# ─── Fetch issues updated since yesterday ───
try:
    issues_data = gql(f'''
    {{
      issues(
        first: 50,
        filter: {{
          team: {{ id: {{ eq: "{TEAM_ID}" }} }},
          updatedAt: {{ gt: "{DAY_AGO}" }}
        }},
        orderBy: updatedAt
      ) {{
        nodes {{
          id identifier title description
          state {{ id name type }}
          priority createdAt updatedAt
          assignee {{ name }}
          project {{ name }}
        }}
      }}
    }}
    '''.replace('\n', ' '))
except Exception as e:
    print(f"❌ Error fetching Linear issues: {e}")
    sys.exit(1)

issues = issues_data["issues"]["nodes"]

# ─── Markdown output ───
today = datetime.datetime.now().strftime("%A, %b %d, %Y")
print(f"# 📊 Linear Daily Digest — {today}\n")
print(f"_StockPlan team — {len(issues)} issue(s) updated in the last 24h_\n")

if not issues:
    print("🎉 No activity. All quiet on the Linear front.\n")
    sys.exit(0)

# Group by state
by_state = {}
for issue in issues:
    state = issue["state"]["name"]
    by_state.setdefault(state, []).append(issue)

for state, group in by_state.items():
    state_icon = {
        "Todo": "📋", "Backlog": "📦", "In Progress": "🔵",
        "In Review": "🔍", "Done": "✅", "Canceled": "❌", "Duplicate": "🔁"
    }.get(state, "•")
    print(f"## {state_icon} {state}\n")
    for issue in group:
        priority_icon = "🔥" if issue.get("priority", 0) <= 1 else "•"
        assignee = issue["assignee"]["name"] if issue.get("assignee") else "unassigned"
        print(f"**{issue['identifier']}** [{issue['priority']}] — {issue['title']}\n")
        if issue.get("description"):
            print(f"> {issue['description'][:200].strip()}{'…' if len(issue['description']) > 200 else ''}\n")
        project_name = issue['project']['name'] if issue.get('project') else 'none'
        print(f"_Project: {project_name} · Assignee: {assignee} · Updated: {issue['updatedAt'][:10]}_")
    print("")

print("---")
print(f"📬 [Open Linear → StockPlan](https://linear.app/team/STO)")
print(f"Generated: {datetime.datetime.now().isoformat()[:19]}Z")
