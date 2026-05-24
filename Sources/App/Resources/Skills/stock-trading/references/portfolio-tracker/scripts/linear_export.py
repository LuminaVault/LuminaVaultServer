#!/usr/bin/env python3
"""
Linear Data Export — Weekly backup of StockPlan team issues
Exports all issues to JSON + CSV, optionally syncs to Notion.

Output: Writes to ~/.cache/hermes/linear_exports/YYYY-WW/
Also prints a one-line summary to stdout for cron notification.
"""

import http.client, json, os, sys, datetime, csv, re

API_KEY = "<LINEAR_API_KEY>"
TEAM_ID = "fc9cf858-9a37-4215-ba7e-bae0eae499cc"
LINEAR_URL = "api.linear.app"

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

# ─── Fetch all issues ───
try:
    issues_data = gql(f'''
    {{
      issues(
        first: 100,
        filter: {{ team: {{ id: {{ eq: "{TEAM_ID}" }} }} }},
        orderBy: updatedAt
      ) {{
        nodes {{
          id identifier title description
          state {{ id name type }}
          priority createdAt updatedAt completedAt
          assignee {{ name }}
          project {{ name }}
        }}
      }}
    }}
    '''.replace('\n', ' '))
except Exception as e:
    print(f"❌ Export failed — GraphQL error: {e}")
    sys.exit(1)

issues = issues_data["issues"]["nodes"]
now = datetime.datetime.now()
week_tag = now.strftime("%Y-W%U")
export_dir = os.path.expanduser(f"~/.cache/hermes/linear_exports/{week_tag}")
os.makedirs(export_dir, exist_ok=True)

# ─── JSON export ───
json_path = os.path.join(export_dir, "issues.json")
with open(json_path, "w") as f:
    json.dump({"generatedAt": now.isoformat(), "team": "StockPlan", "issues": issues},
              f, indent=2)
print(f"✅ JSON: {json_path}  ({len(issues)} issues)")

# ─── CSV export (flattened) ───
csv_path = os.path.join(export_dir, "issues.csv")
fieldnames = ["identifier", "title", "state", "priority", "project",
              "assignee", "createdAt", "updatedAt", "completedAt"]
with open(csv_path, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    for issue in issues:
        writer.writerow({
            "identifier": issue["identifier"],
            "title": issue["title"].replace("\n", " ")[:255],
            "state": issue["state"]["name"],
            "priority": issue.get("priority", ""),
            "project": issue["project"]["name"] if issue.get("project") else "",
            "assignee": issue["assignee"]["name"] if issue["assignee"] else "",
            "createdAt": issue["createdAt"],
            "updatedAt": issue["updatedAt"],
            "completedAt": issue.get("completedAt") or "",
        })
print(f"✅ CSV: {csv_path}")

# ─── Summary line for cron notification ───
summary = (
    f"📦 Linear export complete — {len(issues)} issues — "
    f"JSON: {os.path.basename(json_path)}, CSV: {os.path.basename(csv_path)} — "
    f"~/.cache/hermes/linear_exports/{week_tag}/"
)
print(f"\n{summary}")
