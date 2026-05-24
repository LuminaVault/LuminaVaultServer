#!/usr/bin/env python3
"""
Fandemic Data Export — Weekly backup of all issues (Backend + iOS teams)
Exports to JSON + CSV in ~/.cache/hermes/linear_exports/fandemic-WW/
"""

import http.client, json, os, sys, datetime, csv

API_KEY = "<LINEAR_API_KEY>"
TEAM_IDS = {
    "BACK": "c6fbde7e-4792-40ec-a9a1-73b7942d7351",
    "IOS":  "532cb4dd-8a4d-48d8-9db5-c199fb4c5dd3",
}
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

# Fetch all issues for both teams (up to 100 each)
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
              id identifier title description
              state {{ id name type }}
              priority createdAt updatedAt completedAt
              assignee {{ name }}
              project {{ name }}
            }}
          }}
        }}
        '''.replace('\n',' '))
        for issue in data["issues"]["nodes"]:
            issue["_team"] = team_key
            all_issues.append(issue)
    except Exception as e:
        print(f"⚠️  Error fetching {team_key}: {e}", file=sys.stderr)

now = datetime.datetime.now()
week_tag = now.strftime("%Y-W%U")
export_dir = os.path.expanduser(f"~/.cache/hermes/linear_exports/fandemic-{week_tag}")
os.makedirs(export_dir, exist_ok=True)

# ─── JSON ───
json_path = os.path.join(export_dir, "issues.json")
with open(json_path, "w") as f:
    json.dump({"generatedAt": now.isoformat(), "workspace": "Fandemic", "issues": all_issues},
              f, indent=2)
print(f"✅ JSON: {json_path}  ({len(all_issues)} issues)")

# ─── CSV ───
csv_path = os.path.join(export_dir, "issues.csv")
fieldnames = ["identifier", "title", "state", "priority", "team", "project",
              "assignee", "createdAt", "updatedAt", "completedAt"]
with open(csv_path, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    for issue in all_issues:
        writer.writerow({
            "identifier": issue["identifier"],
            "title": issue["title"].replace("\n", " ")[:255],
            "state": issue["state"]["name"],
            "priority": issue.get("priority", ""),
            "team": issue["_team"],
            "project": issue["project"]["name"] if issue.get("project") else "",
            "assignee": issue["assignee"]["name"] if issue.get("assignee") else "",
            "createdAt": issue["createdAt"],
            "updatedAt": issue["updatedAt"],
            "completedAt": issue.get("completedAt") or "",
        })
print(f"✅ CSV: {csv_path}")

# ─── One-line summary ───
summary = (
    f"📦 Fandemic export — {len(all_issues)} issues (BACK+IOS) — "
    f"JSON+CSV → ~/.cache/hermes/linear_exports/fandemic-{week_tag}/"
)
print(f"\n{summary}")
