#!/usr/bin/env node
/**
 * LuminaVault Photon Sidecar
 *
 * Central Node.js supervisor for spectrum-ts (Photon Spectrum) connections.
 *
 * Design goals (per the Photon "free path" plan):
 * - One (or small pool) of these processes on the VPS host.
 * - Uses the official spectrum-ts SDK (the same one the Hermes photon plugin uses).
 * - For each enabled tenant/project: holds a Spectrum instance (long-lived gRPC or fusor/webhook mode).
 * - Inbound messages from Photon are normalized and POSTed to the main Lumina API's
 *   publicly-reachable webhook (e.g. https://api.luminavault.com/v1/gateways/photon/inbound).
 *   The main API then resolves the tenant and injects into the per-tenant Hermes container.
 * - Outbound (agent replies) are driven by control calls from the Swift server (or directly
 *   if we later expose a narrow send surface).
 *
 * This avoids putting Node + sidecar supervision inside every per-tenant Hermes container
 * and gives us a single public ingress surface, matching the "tenants are outbound-only"
 * constraint.
 *
 * Local / control protocol (for the Swift server over the compose network or host):
 *   POST /control/activate   { projectId, projectSecret, tenantId, options? }
 *   POST /control/deactivate { projectId }
 *   POST /control/send       { projectId, spaceId, text, attachments? }
 *   POST /control/typing     { projectId, spaceId, state: "start"|"stop" }
 *   GET  /healthz
 *
 * The sidecar itself does NOT need a public port; the webhook lives on the Hummingbird API.
 *
 * Env:
 *   LUMINA_API_INTERNAL_URL   (e.g. http://app:8080 or http://host.docker.internal:8080)
 *   LUMINA_PHOTON_WEBHOOK_PATH (default /v1/gateways/photon/inbound)
 *   LUMINA_SIDECAR_TOKEN      (shared auth for /control calls from Swift)
 *   PHOTON_SIDECAR_PORT       (default 8789, local control port)
 */

import http from "node:http";
import { once } from "node:events";

const PORT = parseInt(process.env.PHOTON_SIDECAR_PORT || "8789", 10);
const BIND = process.env.PHOTON_SIDECAR_BIND || "0.0.0.0"; // allow compose network access
const CONTROL_TOKEN = process.env.LUMINA_SIDECAR_TOKEN;
const LUMINA_API = process.env.LUMINA_API_INTERNAL_URL || "http://app:8080";
const WEBHOOK_PATH = process.env.LUMINA_PHOTON_WEBHOOK_PATH || "/v1/gateways/photon/inbound";

if (!CONTROL_TOKEN) {
  console.error("photon-sidecar: LUMINA_SIDECAR_TOKEN is required for control auth");
  process.exit(2);
}

let Spectrum, imessage;
try {
  ({ Spectrum } = await import("spectrum-ts"));
  ({ imessage } = await import("spectrum-ts/providers/imessage"));
} catch (e) {
  console.error("photon-sidecar: spectrum-ts not installed. Run npm install in this dir.");
  console.error(e);
  process.exit(3);
}

// Per-project active Spectrum instances + cleanup
const active = new Map(); // projectId -> { app, tenantId, abort }

async function activateProject({ projectId, projectSecret, tenantId, options = {} }) {
  if (active.has(projectId)) {
    return { ok: true, alreadyActive: true };
  }

  const app = await Spectrum({
    projectId,
    projectSecret,
    providers: [imessage.config()],
    options: { flattenGroups: true, ...options },
  });

  // Start consuming the message stream and forward to Lumina's public webhook.
  // The webhook on the main API is the "publicly-reachable" surface.
  const controller = new AbortController();

  (async () => {
    try {
      for await (const [space, message] of app.messages) {
        if (controller.signal.aborted) break;

        // Normalize a minimal event for the Lumina webhook.
        // Extract simple text for injection; full content for future rich handling.
        const content = message.content || {};
        const text = typeof content === 'string' ? content
            : (content.text || content.content || (content.parts ? content.parts.map(p => p.text || '').join(' ') : ''));
        const event = {
          projectId,
          tenantId,
          spaceId: space.id,
          spaceName: space.name || null,
          messageId: message.id,
          sender: message.sender || null,
          text: text || '',
          content: content,
          timestamp: message.timestamp || Date.now(),
        };

        // Fire-and-forget POST to the main API's webhook.
        // In production use a small queue + backoff + circuit breaker.
        try {
          await fetch(`${LUMINA_API}${WEBHOOK_PATH}`, {
            method: "POST",
            headers: {
              "content-type": "application/json",
              // The main API will validate using the project secret or a tenant-scoped token
              // we can also put in the body or a short-lived token we issued at setup time.
              "x-photon-project-id": projectId,
            },
            body: JSON.stringify(event),
          });
        } catch (err) {
          console.error("photon-sidecar: failed to forward to Lumina webhook", err);
        }
      }
    } catch (err) {
      if (!controller.signal.aborted) {
        console.error("photon-sidecar: message stream error for project", projectId, err);
      }
    }
  })();

  active.set(projectId, { app, tenantId, abort: () => controller.abort() });
  console.log(`[photon-sidecar] activated project ${projectId} for tenant ${tenantId}`);
  return { ok: true };
}

async function deactivateProject(projectId) {
  const entry = active.get(projectId);
  if (!entry) return { ok: true, wasActive: false };

  entry.abort();
  try {
    await entry.app.stop?.();
  } catch {}
  active.delete(projectId);
  console.log(`[photon-sidecar] deactivated project ${projectId}`);
  return { ok: true, wasActive: true };
}

async function sendMessage({ projectId, spaceId, text, attachments = [] }) {
  const entry = active.get(projectId);
  if (!entry) {
    return { ok: false, error: "project_not_active" };
  }
  const { app } = entry;

  // Find the space (in a real impl we would cache spaces or use app.getSpace)
  // For the spike we assume the caller has a valid spaceId from a prior inbound event.
  // spectrum-ts spaces are obtained from the iterator; for direct send we may need
  // a space handle or use a higher-level API if available.

  // Placeholder: in a full impl we keep a map of spaceId -> space handle from the iterator,
  // or use the fusor / other APIs. For now just acknowledge.
  console.log(`[photon-sidecar] send requested for ${projectId}/${spaceId}:`, text?.slice(0, 80));

  // TODO: implement real send using the space handle or Spectrum APIs
  // Example (once we have the handle):
  // await space.send(text(text));

  return { ok: true, messageId: "spike-" + Date.now() };
}

// --- Tiny HTTP control server ---
const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/healthz") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, activeProjects: active.size }));
    return;
  }

  if (!req.url.startsWith("/control/")) {
    res.writeHead(404);
    res.end();
    return;
  }

  // Simple token auth for control plane (called by the Swift server)
  const auth = req.headers["x-lumina-sidecar-token"] || req.headers["authorization"];
  if (auth !== CONTROL_TOKEN && auth !== `Bearer ${CONTROL_TOKEN}`) {
    res.writeHead(401);
    res.end("unauthorized");
    return;
  }

  let body = "";
  for await (const chunk of req) body += chunk;
  let payload = {};
  try { payload = body ? JSON.parse(body) : {}; } catch {}

  try {
    if (req.method === "POST" && req.url === "/control/activate") {
      const result = await activateProject(payload);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(result));
      return;
    }
    if (req.method === "POST" && req.url === "/control/deactivate") {
      const result = await deactivateProject(payload.projectId);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(result));
      return;
    }
    if (req.method === "POST" && req.url === "/control/send") {
      const result = await sendMessage(payload);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(result));
      return;
    }

    res.writeHead(404);
    res.end();
  } catch (err) {
    console.error("photon-sidecar control error", err);
    res.writeHead(500, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: false, error: String(err) }));
  }
});

server.listen(PORT, BIND, () => {
  console.log(`[photon-sidecar] listening on ${BIND}:${PORT}`);
  console.log(`[photon-sidecar] will forward inbound to ${LUMINA_API}${WEBHOOK_PATH}`);
});

process.on("SIGINT", async () => {
  console.log("[photon-sidecar] shutting down...");
  for (const [pid, entry] of active) {
    entry.abort();
    try { await entry.app.stop?.(); } catch {}
  }
  server.close();
  process.exit(0);
});
