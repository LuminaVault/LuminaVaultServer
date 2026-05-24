#!/usr/bin/env python3
"""
Linear Webhook Listener — Auto-create issues from external events
HTTP server on port 8080 (configurable). Endpoint: POST /webhooks/linear

Event sources it can ingest:
  - GitHub (issue/PR opened, review requested, CI failed)
  - Stock price alerts (from your StockPlan backend)
  - Sentry/error reports
  - Custom JSON payloads

Payload format (application/json):
  {
    "title": "short summary",
    "description": "detailed body (markdown ok)",
    "priority": 1-4 (1=highest, 4=lowest),
    "labels": ["Bug", "Feature", "Improvement", "MVP", "Post-MVP"],
    "project": "StockPlan MVP",
    "assignee": "Fernando Correia"  // optional
  }

Response: 200 OK + issue identifier, or error 400/500.
"""

import http.server, json, sys, os, datetime, http.client

API_KEY = "<LINEAR_API_KEY>"
TEAM_ID = "fc9cf858-9a37-4215-ba7e-bae0eae499cc"
LINEAR_URL = "api.linear.app"
PORT = int(os.environ.get("LINEAR_WEBHOOK_PORT", "8080"))

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

# ─── Resolve project + labels + assignee from names ───
def resolve_ids(payload):
    """Resolve project key, label IDs, and assignee ID from string names."""
    errors = []

    # Project → ID
    project_name = payload.get("project", "StockPlan MVP")
    projects = gql("{ projects(first: 10) { nodes { id name } } }")
    project_id = None
    for p in projects["projects"]["nodes"]:
        if p["name"].lower() == project_name.lower():
            project_id = p["id"]
            break
    if not project_id:
        errors.append(f"Project '{project_name}' not found")

    # Labels → IDs
    label_ids = []
    if payload.get("labels"):
        team = gql(f'{{ team(id: "{TEAM_ID}") {{ labels {{ nodes {{ id name }} }} }} }}')
        label_map = {lbl["name"].lower(): lbl["id"] for lbl in team["team"]["labels"]["nodes"]}
        for label_name in payload["labels"]:
            lid = label_map.get(label_name.lower())
            if lid:
                label_ids.append(lid)
            else:
                errors.append(f"Label '{label_name}' not found")

    # Assignee → ID
    assignee_id = None
    if payload.get("assignee"):
        viewer = gql("{ viewer { id name } }")
        if viewer["viewer"]["name"].lower() == payload["assignee"].lower():
            assignee_id = viewer["viewer"]["id"]
        else:
            # Search team members
            team = gql(f'{{ team(id: "{TEAM_ID}") {{ members {{ nodes {{ user {{ id name }} }} }} }} }}')
            for m in team["team"]["members"]["nodes"]:
                if m["user"]["name"].lower() == payload["assignee"].lower():
                    assignee_id = m["user"]["id"]
                    break
            if not assignee_id:
                errors.append(f"Assignee '{payload['assignee']}' not found in team")

    return project_id, label_ids, assignee_id, errors

# ─── Issue creation mutation ───
def create_issue(title, description, priority, project_id, label_ids, assignee_id):
    # Linear expects int 1-4 (1=high, 4=lowest)
    labels_edges = [{"nodeId": lid} for lid in label_ids]

    mutation = '''
    mutation($input: IssueCreateInput!) {
      issueCreate(input: $input) {
        issue {
          id identifier title
        }
      }
    }
    '''
    variables = {
        "input": {
            "title": title,
            "description": description,
            "priority": priority,
            "projectId": project_id,
            "teamId": TEAM_ID,
        }
    }
    if label_ids:
        variables["input"]["labelIds"] = label_ids
    if assignee_id:
        variables["input"]["assigneeId"] = assignee_id

    result = gql(mutation, variables)
    return result["issueCreate"]["issue"]

# ─── HTTP handler ───
class LinearHandler(http.server.BaseHTTPRequestHandler):
    def _json(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_POST(self):
        if self.path != "/webhooks/linear":
            return self._json(404, {"error": "Not found"})

        content_len = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_len)
        try:
            payload = json.loads(body)
        except Exception:
            return self._json(400, {"error": "Invalid JSON"})

        # Validate required fields
        for field in ("title", "description"):
            if not payload.get(field):
                return self._json(400, {"error": f"Missing required field: {field}"})

        # Resolve IDs
        project_id, label_ids, assignee_id, errors = resolve_ids(payload)
        if errors:
            return self._json(400, {"errors": errors})

        # Create issue
        try:
            issue = create_issue(
                title=payload["title"][:255],  # Linear title limit
                description=payload["description"],
                priority=payload.get("priority", 2),
                project_id=project_id,
                label_ids=label_ids,
                assignee_id=assignee_id,
            )
            timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
            print(f"[{timestamp}] ✅ Created {issue['identifier']}: {issue['title'][:60]}")
            return self._json(200, {
                "status": "created",
                "identifier": issue["identifier"],
                "url": f"https://linear.app/team/STO/issue/{issue['id']}"
            })
        except Exception as e:
            print(f"[ERROR] Issue creation failed: {e}")
            return self._json(500, {"error": str(e)})

    def log_message(self, format, *args):
        # Suppress default logging, use our own
        pass

# ─── Main ───
if __name__ == "__main__":
    from http.server import HTTPServer
    server = HTTPServer(("0.0.0.0", PORT), LinearHandler)
    print(f"🚀 Linear webhook listener running on :{PORT} — endpoint POST /webhooks/linear")
    print(f"   Expecting JSON payload with: title, description, [priority], [labels], [project], [assignee]")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Listener stopped.")
        sys.exit(0)
