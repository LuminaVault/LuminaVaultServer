# Hermes WebUI State Directory Configuration Issue

## Symptom
Hermes WebUI container enters a restart loop, showing "Restarting" status in `docker-compose ps`. The WebUI URL returns a 502 Bad Gateway error.

## Root Cause
Missing environment variable `HERMES_WEBUI_STATE_DIR` required by the WebUI initialization script.

## Error Log Analysis
The logs show a repeating pattern:
```
== Checking required environment variables for hermes-webui
-- HERMES_WEBUI_VERSION: Where to store sessions, workspaces, and other state (default: ~/.hermes/webui-mvp)
!! ERROR: HERMES_WEBUI_STATE_DIR not set
!! Exiting script (ID: 44/45)
```

This causes the container to exit, Docker Compose restarts it, and the cycle repeats.

## Configuration Fix

### Step 1: Add Missing Environment Variable
Edit `~/.hermes/.env` and add:
```
HERMES_WEBUI_STATE_DIR=/home/hermeswebui/.hermes/webui-mvp
```

This should be added near other `HERMES_WEBUI_*` variables (typically around line 420).

### Step 2: Restart WebUI Service
```bash
docker-compose down && docker-compose up -d
```

### Step 3: Verify Container Status
```bash
docker-compose ps hermes-webui
```
Should show "Up" status and eventually become healthy.

### Step 4: Check Logs for Confirmation
```bash
docker-compose logs hermes-webui --tail 20
```
Should show successful startup without the "HERMES_WEBUI_STATE_DIR not set" error.

## Prevention
Always ensure all required `HERMES_WEBUI_*` environment variables are set when configuring the WebUI. The minimal set includes:
- `HERMES_WEBUI_HOST`
- `HERMES_WEBUI_PORT`
- `HERMES_WEBUI_PASSWORD`
- `HERMES_WEBUI_STATE_DIR`

## Additional Notes
- The state directory path should be within the volume mounted into the container (typically `${HOME}/.hermes:/home/hermeswebui/.hermes`).
- The default value referenced in the code is `~/.hermes/webui-mvp`.
- If using a reverse proxy (like nginx-proxy-manager), ensure it forwards to the correct internal port (default: 8787).