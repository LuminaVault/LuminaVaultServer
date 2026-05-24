#!/usr/bin/env python3
"""
Fandemic Webhook Listener — HTTP daemon for event-driven ticket creation
Runs on port 8081 (separate from StockPlan's 8080).

Endpoint: POST /webhooks/fandemic

Payload (application/json):
  {
    "title": "Issue summary",
    "description": "Full details (markdown ok)",
    "priority": 1-4,
    "labels": ["Bug","Feature","Improvement","backend"],
    "team": "BACK" | "IOS",        # required — choose team
    "project": "Post Release Sprint" | "Project Smart Sheets" | "1.2.1",
    "assignee": "fernando" | "ajmal" | "shubham@lightningleapanalytics.com"
  }
"""

import http.server, json, sys, os, datetime, http.client

API_KEY = "<LINEAR_API_KEY>"
TEAM_IDS = {
    "BACK": "c6fbde7e-4792-40ec-a9a1-73b7942d7351",
    "IOS":  "532cb4dd-8a4d-48d8-9db5-c199fb4c5dd3",
}
LINEAR_URL = "api.linear.app"
PORT = int(os.environ.get("FEMNIC_WEBHOOK_PORT", "8081"))

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

# ─── Resolve IDs ───
def resolve_ids(payload):
    errors = []

    # Team (required)
    team_key = payload.get("team", "").upper()
    if team_key not in TEAM_IDS:
        errors.append(f"Invalid team '{team_key}'. Must be BACK or IOS.")
        return None, None, None, errors
    team_id = TEAM_IDS[team_key]

    # Project → ID (optional, Linear infers from team if omitted)
    project_id = None
    if payload.get("project"):
        projects = gql("{ projects(first: 10) { nodes { id name } } }")
        for p in projects["projects"]["nodes"]:
            if p["name"].lower() == payload["project"].lower():
                project_id = p["id"]
                break
        if not project_id:
            errors.append(f"Project '{payload['project']}' not found")

    # Labels → IDs
    label_ids = []
    if payload.get("labels"):
        team_data = gql(f'{{ team(id: "{team_id}") {{ labels {{ nodes {{ id name }} }} }} }}')
        label_map = {lbl["name"].lower(): lbl["id"] for lbl in team_data["team"]["labels"]["nodes"]}
        for label_name in payload["labels"]:
            lid = label_map.get(label_name.lower())
            if lid:
                label_ids.append(lid)
            else:
                errors.append(f"Label '{label_name}' not valid for {team_key}")

    # Assignee → ID (search across both Fandemic teams' members)
    assignee_id = None
    if payload.get("assignee"):
        # Check if it's the current viewer (fernando)
        if payload["assignee"].lower() in ["fernando", "fernando@fandemicapp.com"]:
            viewer = gql("{ viewer { id name email } }")
            assignee_id = viewer["viewer"]["id"]
        else:
            # Search both teams
            found = False
            for tk, tid in TEAM_IDS.items():
                members = gql(f'{{ team(id: "{tid}") {{ members {{ nodes {{ user {{ id name email }} }} }} }} }}')
                for m in members["team"]["members"]["nodes"]:
                    u = m["user"]
                    if payload["assignee"].lower() in [u["name"].lower(), u.get("email","").lower()]:
                        assignee_id = u["id"]
                        found = True
                        break
                if found:
                    break
            if not assignee_id:
                errors.append(f"Assignee '{payload['assignee']}' not found in Fandemic teams")

    return team_id, project_id, label_ids, assignee_id, errors

# ─── Issue creation ───
def create_issue(title, description, priority, team_id, project_id, label_ids, assignee_id):
    mutation = '''
    mutation($input: IssueCreateInput!) {
      issueCreate(input: $input) {
        issue { id identifier title }
      }
    }
    '''
    variables = {
        "input": {
            "title": title[:255],
            "description": description,
            "priority": priority,
            "teamId": team_id,
        }
    }
    if project_id:
        variables["input"]["projectId"] = project_id
    if label_ids:
        variables["input"]["labelIds"] = label_ids
    if assignee_id:
        variables["input"]["assigneeId"] = assignee_id

    result = gql(mutation, variables)
    return result["issueCreate"]["issue"]

# ─── HTTP handler ───
class FandemicHandler(http.server.BaseHTTPRequestHandler):
    def _json(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_POST(self):
        if self.path != "/webhooks/fandemic":
            return self._json(404, {"error": "Not found"})

        content_len = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_len)
        try:
            payload = json.loads(body)
        except Exception:
            return self._json(400, {"error": "Invalid JSON"})

        # Validation
        for field in ("title", "description", "team"):
            if not payload.get(field):
                return self._json(400, {"error": f"Missing required field: {field}"})

        # Resolve IDs
        team_id, project_id, label_ids, assignee_id, errors = resolve_ids(payload)
        if errors:
            return self._json(400, {"errors": errors})

        # Create
        try:
            issue = create_issue(
                title=payload["title"],
                description=payload["description"],
                priority=payload.get("priority", 2),
                team_id=team_id,
                project_id=project_id,
                label_ids=label_ids,
                assignee_id=assignee_id,
            )
            timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
            print(f"[{timestamp}] ✅ Created {issue['identifier']}: {issue['title'][:60]}")
            return self._json(200, {
                "status": "created",
                "identifier": issue["identifier"],
                "url": f"https://linear.app/team/{payload['team'].upper()}/issue/{issue['id']}"
            })
        except Exception as e:
            print(f"[ERROR] Issue creation failed: {e}")
            return self._json(500, {"error": str(e)})

    def log_message(self, format, *args):
        pass

# ─── Main ───
if __name__ == "__main__":
    from http.server import HTTPServer
    server = HTTPServer(("0.0.0.0", PORT), FandemicHandler)
    print(f"🚀 Fandemic webhook listener running on :{PORT} — endpoint POST /webhooks/fandemic")
    print(f"   Required payload: title, description, team (BACK|IOS)")
    print(f"   Optional: priority (1-4), labels, project, assignee")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Listener stopped.")
        sys.exit(0)
