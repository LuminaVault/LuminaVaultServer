# HER-XXX — Photon iMessage "Free Path" for Tenants (Node Sidecar + Public Webhook)

**Context**: @NousResearch + @photon_hq announcement (2026-06-08): Hermes agents now reachable via iMessage with one command (`hermes gateway setup` → Photon). Photon free tier = shared-line pool, no cost to start, 5k msgs/day/server + 50 new-convo inits/line/day (paid Business tier for dedicated lines).

LuminaVault already runs a **full per-tenant Hermes agent** (api_server + skills + Mnemosyne + vault grounding) in an isolated Docker container per user. The goal is to expose that agent on iMessage for free with minimal friction, using Photon as the transport.

**User constraint (the "why this shape")**:
> plan Photon (the new free path) = Node.js sidecar + publicly-reachable webhook URL. Our tenants are outbound-only → neither hosts without per-tenant inbound ingress.

Current reality (confirmed):
- Main API has single public ingress (Caddy → api.luminavault.com).
- Per-tenant Hermes containers (`hermes-tenant-<uuid>`) are spawned by `HermesContainerManager` on a localhost port range (9000-9500), published only for the Swift server to reach the `api_server`. No per-tenant public DNS/ports/ingress.
- Containers (and the host for certain paths) are effectively outbound-only for new messaging channels.
- Existing gateways (Telegram, Discord, Slack, WhatsApp, Email, Matrix, ntfy, Mattermost) are activated by seeding token env-vars into the tenant's `/opt/data/.env`; the container's `gateway run` process picks them up. WhatsApp is the special interactive-QR case (see `whatsapp-pairing.md`).

Photon's *native* Hermes integration (per https://hermes-agent.nousresearch.com/docs/user-guide/messaging/photon):
- Persistent-connection (gRPC via `spectrum-ts` SDK), **no webhook, no public URL, no signing secret** required on the agent side.
- Because the SDK is TS-only, Hermes spawns a **supervised Node sidecar** (default loopback :8789). Python adapter <-> sidecar is local NDJSON/POST; sidecar holds the long-lived gRPC to `spectrum.photon.codes`.
- Setup: device-code login to `app.photon.codes`, phone number bind, Spectrum project + secret, `npm install` for sidecar, `PHOTON_PROJECT_ID`/`PHOTON_PROJECT_SECRET` in `~/.hermes/.env`.
- Run: `hermes gateway start --platform photon` (or integrated in `gateway run` when creds present).
- Same auth model as other platforms (DM pairing codes or `PHOTON_ALLOWED_USERS` / `PHOTON_REQUIRE_MENTION`).

We **cannot** (and per the directive **will not**) simply "turn on" the native platform inside every per-tenant container without addressing the Node requirement + the user's explicit central sidecar + public webhook preference.

## Goals
- Every tenant can enable a **free iMessage line** for their Lumina agent ("text your brain").
- The assigned number is stable per conversation (shared pool on free tier).
- Full agent behavior on inbound: vault files, KB, memories (Mnemosyne), skills, cron spaces, etc.
- Setup friction comparable to (or better than) WhatsApp QR: browser device approval + phone entry, live status via SSE.
- Centralize Photon connectivity (provisioning, gRPC or webhook translation, send) in one (or small number of) Node.js sidecar process(es) on the VPS host.
- Public webhook lives on the single ingress; delivery is fanned out internally to the correct tenant container.
- Reuse/extend the existing `HermesGateways` machinery (catalog, `UserHermesGateway` rows + SecretBox, apply jobs + SSE, `HermesContainerManager`, `HermesTenantConfigTemplate`).
- Keep per-tenant containers lean (Node not required in the Hermes image for the common case).

## Non-Goals (MVP)
- Native BlueBubbles / self-hosted Mac relay.
- Paid Photon Business dedicated lines (later, as a upsell or separate gateway entry).
- Full attachment byte passthrough on inbound (metadata-only is acceptable per upstream limits today; outbound attachments already supported in the SDK).
- Multi-device or "home channel" cron delivery over iMessage in v1 (can route through existing `PHOTON_HOME_CHANNEL` if the sidecar supports it).
- Per-tenant dedicated sidecar processes (central is the point).

## Architecture (Central Node Sidecar + Public Webhook)

```
iMessage (user or contact)
    │
    ▼ (Photon shared pool / Spectrum)
Photon cloud (spectrum.photon.codes gRPC or registered webhook delivery)
    │
    ▼
Lumina public ingress (Caddy)
    │
    ▼
Swift API (new /v1/gateways/photon/webhook or /v1/me/hermes-gateways/photon/inbound)
    │  (auth by project secret or tenant-scoped delivery token)
    │
    ▼
PhotonDeliveryService / Webhook handler
    │  resolve tenant + project
    │  validate
    │  rate-limit per tenant
    ▼
Injection into tenant's Hermes container
    (ensureRunning via HermesContainerManager)
    (feed message as external utterance / platform turn)
    (capture reply text + attachments)
    │
    ▼ (reply)
Central Node.js Photon Sidecar  (outbound send via spectrum-ts)
    │
    ▼
Photon → iMessage (stable conversation)
```

**Node.js sidecar responsibilities** (new `photon-sidecar` service in compose):
- Speaks `spectrum-ts` (or the extracted client from Hermes' photon plugin) for:
  - Provisioning flows that the `hermes photon setup` CLI performs (device login, create/find "Hermes Agent" Spectrum project, rotate secret, register phone as Spectrum user, obtain assigned line).
  - Sending replies/attachments on behalf of a tenant's project/space.
  - (If using gRPC delivery model) maintaining long-lived streams for active projects and translating inbound messages to HTTP callbacks into the Swift server.
- Does **not** persist secrets long-term (Swift owns encrypted `UserHermesGateway` rows or a new `UserPhotonProject` row; sidecar receives transient creds or short-lived tokens for active work).
- Exposes a small internal control surface (HTTP or docker-exec friendly) for the Swift server to drive setup and sends.
- One (or autoscaled small pool) process — easy to give Node 20+, keep updated, monitor connection health.
- Can be the thing that *registers* a per-project webhook URL (pointing at the public Lumina endpoint + a tenant/project discriminator + MAC or the project secret) if Photon supports callback registration. This is ideal: sidecar only does setup + send; delivery is pure webhook push.

**Why central sidecar + webhook (vs. pure native inside every tenant container)**:
- Matches the explicit directive ("Node.js sidecar + publicly-reachable webhook URL").
- Avoids baking Node + sidecar supervision + npm into the per-tenant Hermes image for 100% of users (image bloat, build time, sec surface).
- Single public surface (the existing API ingress) instead of trying to give per-tenant listeners.
- Central place to implement multi-tenant Photon concerns (project lifecycle, quotas, send routing, health of the gRPC fleet).
- The per-tenant containers stay focused on `api_server` + skills + Mnemosyne + vault. We inject at the "user message" boundary so the agent runs with full context.
- Reuses the "exec / SSE / apply" patterns we already have for WhatsApp without forcing every container to be a full gateway host for Photon.

**Injection options (to be prototyped in spike)**:
- Preferred if Hermes exposes or we can add a narrow "external platform message ingest" on the `api_server` (or a second internal port): POST the raw-ish Photon event (or normalized `{text, sender, conversation_id, attachments_meta}`) with a server-only auth; the container's agent loop produces a reply that is returned synchronously or streamed back.
- Fallback: `docker exec` a small driver (Python one-liner or `hermes` subcommand if one exists for headless turns) that feeds the message and captures stdout/reply. Less clean for streaming.
- Stretch: also seed minimal `PHOTON_*` (or a generic `EXTERNAL_WEBHOOK_TOKEN`) into the tenant `.env` and have a tiny "http_callback" or generic inbound platform inside the container that the central sidecar / main API can POST to directly on the tenant's published localhost port. This would let the native Hermes platform machinery (pairing, allowed_users, mention gating, spaces) do more work.

The injection layer must preserve tenant isolation and give the turn the same memory/session scoping as a native gateway message (`X-Hermes-Session-Key` etc. are already used on the server→Hermes hop).

## Data Model & Secrets
- Reuse `UserHermesGateway` (tenant_id + gateway_id="photon" + sealed config JSON) for the post-setup artifacts: `project_id`, `project_secret`, `assigned_line`, `my_bound_phone`, `dashboard_project_id` (if useful), `require_mention`, `mention_patterns`, `allowed_users`, etc.
- The sealed blob is exactly what other gateways use; `HermesGatewayCatalog.envVars` can emit the `PHOTON_*` names (even if the central sidecar is the primary consumer, seeding them is harmless or useful for a hybrid path).
- New or extended rows for setup sessions (like WhatsApp's ephemeral pairing sessions) if we need durable progress across restarts/SSE reconnects.
- The sidecar never sees the master `SecretBox` key.

## Catalog Entry (sketch)
```swift
.photon: Entry(
    displayName: "iMessage (Photon)",
    iconSlug: "photon", // or "imessage"
    description: "Free iMessage access via Photon shared lines. Text your Lumina agent directly — no app needed.",
    requiredFields: [], // special flow
    pairingKind: .photonSetup, // new case
),
```
`envVars` will map the stored fields to `PHOTON_PROJECT_ID`, `PHOTON_PROJECT_SECRET`, `PHOTON_ALLOWED_USERS`, `PHOTON_REQUIRE_MENTION`, `PHOTON_MENTION_PATTERNS`, etc. (for compatibility if a future path runs the platform inside the container too).

Add the case to `HermesGatewayID` in Shared (and `allCases` order), client enums, tests, snapshots, etc. Non-breaking for existing gateways.

## Setup Flow (iOS + Server + Sidecar)
Similar skeleton to WhatsApp QR but driven by the TS SDK in the sidecar:

1. Tenant opens Photon gateway in app → client calls `POST /v1/me/hermes-gateways/photon/setup` (or reuse/extend the generic start + special id handling).
2. Server asks sidecar to begin device-code login (`client_id=photon-cli` equivalent). Sidecar (or a helper) returns `verification_uri`, `user_code`, `device_code`, `expires_in`, `interval`.
3. App shows the URL (or `ASWebAuthenticationSession` / Safari VC) + code. User approves on photon.codes (can be the same phone).
4. App prompts for binding phone number (E.164, must be able to receive iMessage; this becomes the "my number" Spectrum user).
5. Client subscribes to SSE (`/v1/me/hermes-gateways/photon/setup/{session}/stream` or the apply stream pattern).
6. Server polls sidecar (or sidecar pushes) for device approval; once approved, sidecar performs the rest of provisioning (find/create project, enable Spectrum, register phone, obtain assigned line, sidecar npm if the SDK path needs it locally).
7. On success: sidecar returns the assigned line + project creds. Server seals them into a `UserHermesGateway` row (or dedicated), marks configured.
8. Optional "apply" step tells the sidecar "activate streaming / register webhook for this project" (or the mere presence of the sealed row + a background reconciler is enough).
9. User is shown the number to give people ("Text +1-628-... to reach your Lumina").

Unlink / disable: delete the gateway row (and tell sidecar to drop the project/stream if it was holding state), container restart not strictly required since photon won't be in the per-tenant env for the central path.

Pairing / allowed users: after enable, support the same `PHOTON_ALLOWED_USERS` + mention gating that the native platform uses (stored in the config blob, enforced either in the sidecar on receive or passed through on injection).

## Inbound / Webhook Contract (to be pinned with Photon)
- Path: `POST /v1/gateways/photon/webhook` (or `/v1/me/hermes-gateways/photon/inbound` for symmetry).
- Auth: `Authorization: Bearer <project_secret>` or a body field + MAC, or a short tenant-scoped token we generated at setup time and registered with Photon as the callback secret. Never leak the master secret.
- Payload shape: whatever Spectrum delivers for `app.messages` (text, sender stable id or E.164, conversation/space id, timestamp, attachment metadata list). Normalize in the handler.
- Idempotency: use message id or (conversation, ts, hash) to dedupe (the native adapter does dedupe too).
- Response: quick 200 to ack; actual agent work is async.

The handler:
- Looks up the project → tenant mapping (we'll store a reverse index or just scan/seal the project_id with the tenant row).
- Calls `PhotonDeliveryService.ingest(tenantID: ..., event: ...)`.
- `ingest` ensures the container, performs the injection, waits for (or streams) the reply, then asks the sidecar to send the reply back on the same conversation/space.
- On any failure: log, increment per-tenant counter, surface via existing error paths (don't leak to sender beyond a generic "assistant unavailable" if desired).

## Outbound (Agent → iMessage)
- When the injected turn produces a final assistant message (text + optional attachments), the injection path returns it (or we hook the generation finish).
- The delivery service asks the sidecar: "send this content as Lumina on project X, conversation Y, to the original sender".
- Sidecar uses the SDK `space.send(...)` / attachment builders (the same ones the Hermes photon plugin uses).
- Captions for media arrive as follow-up bubbles (upstream behavior).

If we later run a stub photon platform inside some containers, the send path can be dual (sidecar or direct from container).

## Files & Components (high-level map)

**Shared (LuminaVaultShared)**:
- `HermesGatewayID` — add `case photon`.
- Any new DTOs for setup events, `PhotonSetupSession`, assigned line, etc. (mirror `HermesWhatsAppPairEvent` style if we stream progress).
- Update OpenAPI / generator config.

**Server — new or extended**:
- `Sources/App/HermesGateways/PhotonSetupService.swift` (or `PhotonGatewayService`) — actor, drives sidecar calls, owns setup sessions + SSE fanout (like `WhatsAppPairingService`).
- `Sources/App/HermesGateways/PhotonSidecarClient.swift` (protocol + live impl) — thin HTTP/gRPC client to the sidecar for `beginDeviceLogin`, `pollDevice`, `completeSetup(phone:)`, `activateProject`, `send(tenant:project:message:)`, `status(project:)`.
- `Sources/App/HermesGateways/PhotonWebhookController.swift` (or methods in `HermesGatewaysController`) + route registration. Public (or lightly authed) inbound.
- `Sources/App/HermesGateways/PhotonDeliveryService.swift` — injection + reply capture + round-trip to sidecar for send.
- Extend `HermesGatewayCatalog.swift` (entry + `envVars` mapping + validate if any).
- Extend `HermesGatewaysController.swift` (special-case photon for setup routes, reject normal PUT for pairing-kind gateways, etc.).
- Possibly a small addition to `HermesTenantConfigTemplate` (or no-op for photon if we don't rely on per-tenant env for it).
- `HermesContainerManager` changes? Minimal — we already call `ensureRunning` from many places; the new delivery path will too.
- Models: reuse `UserHermesGateway`; add `UserPhotonSetupSession` or similar if needed for durable SSE across restarts.
- Tests: controller tests, service tests with stub sidecar, parser tests if we have any payload shaping.
- Docker: new service `photon-sidecar` (or `messaging-sidecar`) in `docker-compose.yml` + production variant. Volume for its own state if any. Healthcheck. Depends on nothing special.
- Env wiring: new vars for sidecar image, internal URL, ports, etc. Document in `production-env-wiring.md` and the root deployment guide.
- `HermesGatewayApplyService` / apply jobs: photon may participate in the generic "apply" (for the sealed row + status stamp) even if the container restart is a no-op for the central path. Or we special-case it.

**Sidecar (new dir or `docker/photon-sidecar/`)**:
- Minimal Node 20+ image + the spectrum-ts package (or a vendored/extracted client that matches what Hermes uses).
- Small server (Express/Fastify or just http) exposing the control API the Swift client calls.
- Or run as a CLI that the compose command keeps alive, talking over a unix socket or localhost HTTP that the Swift sidecar client reaches (the containers share the `luminavault-hermes-net` or a new one, or use host networking for the control plane).
- Graceful reconnects, per-project connection lifecycle, send queueing.
- Structured logs (OTel if easy).

**Client (LuminaVaultClient)**:
- Add `photon` to gateway ID handling (enums, icons in `HermesGatewaysPaneView`, `GatewaysSetupView`, detail views).
- New or extended `PhotonSetupView` + ViewModel (device approval step, phone entry form, live status/assigned number, success "share this number", allowed users / mention toggle if exposed).
- SSE handling for setup progress (reuse patterns from WhatsApp pairing or the apply SSE).
- HermesGateways endpoints client already generic over ID — mostly works; may need a couple of setup-specific calls (`startPhotonSetup`, `submitPhone`, `getAssignedLine`, etc.).
- Snapshots / tests.
- Onboarding promotion? (optional).

**Docs & Ops**:
- New or updated `LuminaVaultServer/docs/photon-gateway.md` (or extend `whatsapp-pairing.md` style).
- Update `production-env-wiring.md` (it already explains the "just add to catalog + Shared ID" pattern; note that photon is the first that also needs the sidecar).
- Root `LUMINAVAULT_DEPLOYMENT_CONFIG_GUIDE.md` — new service, any new env groups (sidecar image, internal control URL, webhook secret if we mint one).
- Compose files, CI (build the sidecar image? or use a public node + runtime install; prefer a small baked image for reproducibility).
- Runbook entries for sidecar logs, "no lines left in pool", quota warnings.
- Client `docs/` or `Config/README.md` updates if any build-time strings.

**CI / Deploy**:
- The existing backend CI (GHCR, SSH deploy) will pick up compose changes.
- Add a sidecar build step or bake it into the main server image build context if tiny.
- Secret for any sidecar auth to the Swift API (if the sidecar ever calls back authenticated).

## Risks & Open Questions (to resolve in discuss / spike)
1. **Delivery model**: Does Photon/Spectrum support registering an HTTP callback (webhook) per project in addition to / instead of a long-lived gRPC client? If yes, the sidecar becomes "setup + send only" — much simpler. If only gRPC client model, the sidecar must hold the streams (still fine; one process).
2. **Injection fidelity**: What is the minimal surface to feed an external message into a running per-tenant `gateway run` process so that it goes through the *exact* same agent loop, memory, skill dispatch, and reply formatting as a native platform message? (Preferred over faking a chat/completions call, which would lose gateway-specific behaviors.)
3. **Hermes image Node requirement**: Even in the central model, do we ever want the option for a tenant to run the *native* photon platform inside their container (for BYO or advanced use)? If so, we still need a Node-capable variant or to document "use a custom Hermes image with node".
4. **Setup non-interactivity**: The device-code flow is browser-based by design. Can the sidecar fully automate the post-approval steps once the code is approved, or do we need a small headless browser / token exchange? (Upstream `hermes photon setup` does it; replicate the calls.)
5. **Phone binding semantics**: The `--phone` in setup is "a phone number that can receive iMessage (used to bind your account)". Clarify whether this is the user's personal number (for identity) or just a verification number, and what the free-tier shared-line behavior looks like for recipients.
6. **Quotas & abuse**: Free tier has per-server daily caps. Central sidecar makes "server" = our VPS (good for pooling quota across tenants, or bad if one noisy tenant starves others). Decide on internal metering / per-tenant daily soft caps + graceful degradation ("iMessage link temporarily rate-limited").
7. **Attachment bytes inbound**: Upstream limitation today. Plan to consume the metadata and (later) call `content.read()` in the sidecar when the SDK supports it.
8. **Multiple active gateways + "which channel did this come from?"**: The agent may need to know the reply should go back on the photon channel vs. the in-app chat or another gateway. Existing Hermes platforms already solve this (the turn carries the platform context); our injection must do the same.
9. **Sidecar <-> Swift trust boundary**: If the sidecar runs on the same host/docker net, localhost HTTP with a shared secret or unix socket is fine. Document the posture.

## Implementation Phases (suggested order)

**Phase 0 — Spike & Decision** (small, 1-2 days)
- Stand up a toy Node process with spectrum-ts (or copy the relevant bits from Hermes photon plugin).
- Exercise device login + project creation + phone register + send.
- Determine exact inbound delivery shape (gRPC stream vs. webhook registration) and the minimal payload we need for injection.
- Prototype one injection path into a running tenant container and confirm the agent produces a grounded reply using vault/KB.
- Write a short spike report + recommended injection contract. Update this plan with the chosen approach.

**Phase 1 — Shared + Catalog Surface** (no runtime behavior yet)
- Add `case photon` to `HermesGatewayID` (Shared), regenerate/openapi touch-ups, client enums.
- Add catalog entry (display, description, `pairingKind: .photonSetup`).
- Add `envVars` mapping for the photon keys (even if not used for per-tenant .env seeding yet).
- Update all enumeration sites, tests, snapshots (they are numerous but mechanical).
- Add the ID to `HermesGatewayID.allCases` order (decide UX order — probably near the top as the "free iMessage" win).

**Phase 2 — Sidecar Skeleton + Compose**
- `docker/photon-sidecar/Dockerfile` (node:20-alpine + the SDK + a small server).
- Add `photon-sidecar` service to `docker-compose.yml` and production variant (volumes, env, network, restart, health).
- Define the internal control API (OpenAPI snippet or just a small TS types + Swift client).
- Stub `PhotonSidecarClient` protocol + fake impl for tests.
- Wire a (disabled) instance in `ServiceContainer` / App+build.

**Phase 3 — Setup Flow (Server + Controller)**
- New `PhotonSetupService` (actor) + session model + SSE response type (modeled on WhatsApp).
- Routes in `HermesGatewaysController` (or a dedicated group): start setup, submit phone / complete, status, stream.
- Implement the happy path calling the (stub) sidecar client; persist sealed project creds on success.
- Reject normal credential PUT for the photon ID (like whatsapp).
- Update list/get to surface the special entry + status (hasConfig true after setup, plus `assignedLine` in metadata if we add a small extension field).

**Phase 4 — Webhook + Delivery + Roundtrip**
- Public webhook route + validation.
- `PhotonDeliveryService` (ensure container, inject, capture reply, ask sidecar to send).
- Define + implement the injection seam (the key integration point from Phase 0).
- Basic error handling, per-tenant rate limit hook (reuse existing middleware if possible).
- Wire the sidecar "send" call.

**Phase 5 — Client UI**
- Generic gateway list will light up once the ID is present; add icon mapping.
- Dedicated `PhotonSetupView` / ViewModel for the device + phone + success + number display + controls.
- SSE subscription for live setup (assigned line appears when ready).
- "Test" button (sends a canned message via the sidecar and shows the reply path).
- Update panes, onboarding, snapshots.

**Phase 6 — Apply / Status / Lifecycle Polish**
- Make photon participate in the generic apply job (or a photon-specific apply that activates the project in the sidecar + stamps verified).
- `GET /.../photon/status` that asks the sidecar for gRPC health / last-seen for the project (surfaces in the app).
- Unlink / delete: drop the row, tell sidecar to release, clear any cached streams.
- Reconciler (on boot or periodic) that tells the sidecar about all currently-enabled photon projects so streams are restored after sidecar restart.
- Idle eviction interaction: photon enablement should probably keep the container "warm" or at least not evict while the gateway is the reason the user is active (similar to xai/nous connected markers? or a new `photonConnectedAt`).

**Phase 7 — Hardening, Docs, Release**
- Quota awareness / graceful "over quota" replies.
- Security review of the webhook (no SSRF, no cross-tenant via forged project id, timing-safe compares).
- Add to deployment guide + production env wiring + a short operator runbook.
- Client + server version bump (Shared package).
- End-to-end on staging with a real iMessage device.
- Announcement text / in-app prompt for the "free path".
- Update any ASO or marketing materials if relevant.

## Success Criteria
- A new user can go from "no gateways" → enable Photon → approve device in browser → enter phone → see an assigned number → text that number from iMessage → receive a grounded reply from their Lumina agent (mentioning vault content or running a skill) within the free tier.
- The number remains stable for the conversation.
- Disabling the gateway stops delivery; re-enabling restores it.
- Existing gateways and per-tenant container lifecycle are unaffected.
- Sidecar can be restarted independently without losing tenant Hermes state.
- All new code has tests; the plan's spike results are captured.

## References
- Upstream: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/photon (and the linked Hermes repo).
- X announcement: https://x.com/NousResearch/status/2064102412076364207
- Existing patterns: `whatsapp-pairing.md`, `HermesGatewayCatalog.swift`, `HermesContainerManager.swift`, `HermesGatewayApplyService.swift`, `UserHermesGateway.swift`, `HermesGatewaysController.swift`.
- Deployment source of truth: `LUMINAVAULT_DEPLOYMENT_CONFIG_GUIDE.md` (update when adding the sidecar service or new env keys).
- Scale note: central sidecar adds one more always-on process but removes per-tenant port + container overhead for the messaging path (the container is still needed for the agent brain).

This plan is intentionally concrete on the "why central sidecar + webhook" shape while leaving the exact injection contract and Photon callback vs. gRPC details to a short spike (Phase 0). Once the spike lands, the subsequent phases are mostly additive extensions of machinery we already ship and test for WhatsApp and the token gateways.

## Spike Status (first "Start" session)

**Artifacts landed in this session:**
- `LuminaVaultServer/docker/photon-sidecar/`
  - `package.json` + generated `package-lock.json` (spectrum-ts ^2 pulled cleanly, 0 vulns).
  - `index.mjs` — working skeleton using the real `Spectrum` + iMessage provider from spectrum-ts. Consumes the message stream and forwards normalized events to the main Lumina API webhook (the "publicly-reachable" piece). Exposes `/control/activate|deactivate|send|...` for the future Swift `PhotonSidecarClient`.
  - `Dockerfile` (alpine + node 20, healthcheck on /healthz).
  - `README.md` — explains the contract, relation to the Hermes reference sidecar (`plugins/platforms/photon/sidecar/index.mjs` + adapter.py), and why this is central.
- `docker-compose.yml` — draft `photon-sidecar` service added (builds from the new Dockerfile, wired to the dev `hummingbird` on the default network, env for internal webhook target + control token).

**Key research from the spike (Hermes + photon-hq/spectrum-ts clones):**
- The canonical small Node sidecar lives at `hermes-agent/plugins/platforms/photon/sidecar/index.mjs`. It is spawned/supervised by the Python adapter, speaks a trivial local HTTP/NDJSON protocol (`GET /inbound` NDJSON, `POST /send`, token auth), and is ~the shape we replicated/adapted.
- Provisioning (device code, project creation, Spectrum enable, phone→Spectrum user, assigned line) lives in `cli.py` + `auth.py` — separate from the runtime sidecar. We will replicate the management surface from the server (or call Photon APIs directly) during the "photon setup" flow.
- spectrum-ts high-level API is exactly `await Spectrum({projectId, projectSecret, providers: [imessage.config()]})` then `for await (const [space, message] of app.messages)`. It also has `fusor` / webhook test surface (`fusor/webhook.test.ts` etc.) — promising for preferring pure push delivery to our public webhook instead of the sidecar holding every gRPC stream.
- No public HTTP message API on Photon; the SDK (gRPC under the hood) + this sidecar pattern is the supported way.

**Immediate next (after this "Start")**:
- Phase 0 remaining: prototype the injection seam into a tenant Hermes (or the shared one in compose), decide webhook registration vs. sidecar-held streams, and write the short spike report + recommended injection contract.
- Phase 1: Add `case photon` to `HermesGatewayID` in LuminaVaultShared (mechanical but touches client + tests + OpenAPI).
- Then the Swift `PhotonSidecarClient` + controller routes + webhook receiver.

The sidecar is now real, installable, and Docker-integrated. We have a concrete Node.js piece + the public webhook target story started.

Ready for the rest of the spike or to move to the Shared enum + first server wiring. (User said "Start" — this session delivered the foundation artifact + research.)

---

Ready for discuss → refine → enter the execute phase. (spike foundation complete)