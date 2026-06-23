# photon-sidecar (LuminaVault)

Central Node.js sidecar for the Photon (Spectrum) iMessage "free path".

## Why a central sidecar?

- Tenants / per-tenant Hermes containers are outbound-only. There is no per-tenant public ingress.
- The official spectrum-ts SDK is the only practical way to talk to Photon's iMessage (Spectrum) transport.
- We want a **single publicly-reachable webhook** on the main Lumina API (`/v1/gateways/photon/inbound` etc.) that the existing Hummingbird server can expose, validate, tenant-route, and then inject into the correct per-tenant Hermes container (so the full agent with vault/KB/skills/Mnemosyne runs).
- One (or a small pool) of Node processes on the VPS host is easy to give `node`, keep updated, monitor, and scale horizontally if needed.

This matches the directive: **Node.js sidecar + publicly-reachable webhook URL**.

## How it works (MVP)

1. When a tenant enables the Photon gateway in the app, the server drives a setup flow (device code login to `app.photon.codes`, phone bind, Spectrum project creation).
2. On success the server stores the resulting `projectId` + `projectSecret` (encrypted per-tenant via SecretBox, same as other gateways).
3. The server tells this sidecar (over the internal compose network) to `POST /control/activate` with the project creds + tenantId.
4. The sidecar creates a `Spectrum({ projectId, projectSecret, providers: [imessage.config()] })` instance and consumes `app.messages`.
5. Every inbound event is normalized and **POSTed to the main Lumina API's public webhook**.
   - The webhook handler (in Swift) resolves the tenant, rate-limits, and injects the message into that tenant's Hermes container (via the existing `ensureRunning` + a new or existing injection seam).
   - The injection produces a grounded agent reply (full skills/vault context) which is returned to the webhook handler.
6. The handler asks the sidecar (`/control/send`) to deliver the reply back on the correct `spaceId` / conversation using spectrum-ts.

Outbound media, typing indicators, etc. go through the same control surface.

## Local control API (called by the Swift server)

All control calls must include the `X-Lumina-Sidecar-Token` header (or `Authorization: Bearer ...`) matching `LUMINA_SIDECAR_TOKEN`.

- `POST /control/activate`
  Body: `{ "projectId": "...", "projectSecret": "...", "tenantId": "...", "options?": {} }`
- `POST /control/deactivate`
  Body: `{ "projectId": "..." }`
- `POST /control/send`
  Body: `{ "projectId": "...", "spaceId": "...", "text": "...", "attachments?": [...] }`
- `POST /control/typing`
  Body: `{ "projectId": "...", "spaceId": "...", "state": "start" | "stop" }`
- `GET /healthz`

Inbound from Photon is **not** served here — it is forwarded by the sidecar to the public Lumina webhook so the single ingress + tenant routing story stays in one place. Forwarded webhook calls include `X-Lumina-Sidecar-Token: $LUMINA_SIDECAR_TOKEN`; the Swift API rejects inbound Photon events without that shared token.

## Running locally (with the rest of the stack)

The sidecar will be added to `docker-compose.yml` (and the production variant) as a service, e.g.:

```yaml
  photon-sidecar:
    build:
      context: .
      dockerfile: docker/photon-sidecar/Dockerfile
    # or use a prebuilt node image + volume mount for dev
    environment:
      - LUMINA_API_INTERNAL_URL=http://app:8080
      - LUMINA_PHOTON_WEBHOOK_PATH=/v1/gateways/photon/inbound
      - LUMINA_SIDECAR_TOKEN=${LUMINA_SIDECAR_TOKEN:?}
      - PHOTON_SIDECAR_PORT=8789
    networks:
      - luminavault-hermes-net   # or the main app network
    restart: unless-stopped
```

A minimal Dockerfile can be:

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .
CMD ["node", "index.mjs"]
```

## Provisioning / setup flow (not in this sidecar)

The actual `hermes photon setup` (device login, project creation, Spectrum enable, phone registration as Spectrum user, obtaining the assigned iMessage line) is a management / dashboard flow.

In Lumina this will be driven from the iOS app + server (similar to the WhatsApp QR pairing flow):
- Device code step (open URL or show code, user approves on photon.codes).
- Collect E.164 phone for binding.
- Call into Photon APIs (or a small helper that replicates what `hermes photon setup` + `auth.py` do) to obtain the runtime `projectId` + `projectSecret`.
- Store them encrypted.
- Then `activate` in the sidecar.

The sidecar only cares about the runtime Spectrum client (projectId + secret).

See the main plan doc and the Hermes `plugins/platforms/photon/{cli.py,auth.py}` for the exact steps we need to replicate or call.

## Status & next in the spike

This skeleton demonstrates:
- Using the real `spectrum-ts` + iMessage provider.
- The stream → forward-to-Lumina-webhook pattern.
- A control surface the Swift `PhotonSidecarClient` can talk to.
- Graceful shutdown.

Immediate follow-ups in the spike / Phase 0 report:
- Confirm whether we can (or should) use the `fusor` / webhook registration APIs from spectrum-ts so the sidecar does **not** have to hold long-lived gRPC streams for every tenant (pure push to our public webhook).
- Map the real `Message` / `Space` shapes and build a small normalizer.
- Implement a real `send` path once we have stable space handles (cache them from the iterator or use SDK surface).
- Add the sidecar service to compose + the Swift client + webhook receiver.

## References

- Official usage: https://github.com/photon-hq/spectrum-ts (and docs.photon.codes)
- Hermes photon plugin (the reference implementation of the sidecar + provisioning): `plugins/platforms/photon/` in the Hermes repo (sidecar/index.mjs is the direct ancestor of the logic here).
- Lumina plan: `LuminaVaultServer/docs/superpowers/plans/2026-06-photon-imessage-free-path.md`
