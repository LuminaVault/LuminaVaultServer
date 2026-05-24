#!/usr/bin/env python3
"""
Daily Linear Digest — Fandemic workspace
Covers both Backend (BACK) and iOS (IOS) teams in one report.

Output: Markdown to stdout.
"""

import http.client, json, os, datetime, sys

API_KEY = "<LINEAR_API_KEY>"
TEAM_IDS = {
    "BACK": "c6fbde7e-4792-40ec-a9a1-73b7942d7351",
    "IOS":  "532cb4dd-8a4d-48d8-9db5-c199fb4c5dd3",
}
LINEAR_URL = "api.linear.app"

DAY_AGO = (datetime.datetime.now(datetime.timezone.utc) -
           datetime.timedelta(days=1)).isoformat()

def gql(query, variables=None):
    conn = http.client.HTTPSConnection(LINEAR_URL, timeout=15)
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

# ─── Fetch issues for both teams ───
all_issues = []
for team_key, team_id in TEAM_IDS.items():
    try:
        data = gql(f'''
        {{
          issues(
            first: 50,
            filter: {{
              team: {{ id: {{ eq: "{team_id}" }} }},
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
              team {{ id name }}
            }}
          }}
        }}
        '''.replace('\n',' '))
        for issue in data["issues"]["nodes"]:
            issue["_team_key"] = team_key
            all_issues.append(issue)
    except Exception as e:
        print(f"⚠️  Error fetching {team_key}: {e}", file=sys.stderr)

# ─── Output ───
today = datetime.datetime.now().strftime("%A, %b %d, %Y")
print(f"# 📊 Fandemic Linear Daily Digest — {today}\n")
print(f"_Backend + iOS teams — {len(all_issues)} issue(s) updated in the last 24h_\n")

if not all_issues:
    print("🎉 No activity across either team.\n")
    sys.exit(0)

# Group by team then state
by_team = {"BACK": [], "IOS": []}
for issue in all_issues:
    by_team[issue["_team_key"]].append(issue)

for team_key in ["BACK", "IOS"]:
    issues = by_team[team_key]
    if not issues:
        continue
    print(f"## {'🔧' if team_key == 'BACK' else '📱'} {team_key} Team\n")
    # Group by state within team
    by_state = {}
    for issue in issues:
        by_state.setdefault(issue["state"]["name"], []).append(issue)

    for state, group in by_state.items():
        state_icon = {"Todo":"📋","Backlog":"📦","In Progress":"🔵",
                      "In Review":"🔍","Done":"✅","Canceled":"❌","Duplicate":"🔁"}.get(state, "•")
        print(f"### {state_icon} {state}\n")
        for issue in sorted(group, key=lambda x: -x.get("priority", 99)):
            priority_icon = "🔥" if issue.get("priority", 0) <= 1 else "•"
            assignee = issue["assignee"]["name"] if issue.get("assignee") else "unassigned"
            project_name = issue["project"]["name"] if issue.get("project") else "none"
            print(f"**{issue['identifier']}** [{issue['priority']}] — {issue['title']}\n")
            if issue.get("description"):
                print(f"> {issue['description'][:180].strip()}{'…' if len(issue['description']) > 180 else ''}\n")
            print(f"_Project: {project_name} · Assignee: {assignee} · Updated: {issue['updatedAt'][:10]}_\n")
        print("")

print("---")
print(f"📬 [Open Linear → Fandemic](https://linear.app/team/BACK) | [iOS](https://linear.app/team/IOS)")
print(f"Generated: {datetime.datetime.now().isoformat()[:19]}Z")
