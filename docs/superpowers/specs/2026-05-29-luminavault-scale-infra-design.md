# LuminaVault — Scale & K8s Infrastructure Design

Date: 2026-05-29
Status: Approved design (pre-implementation)
Scope: Server refactor (stateless API + Redis) + per-tenant Hermes lifecycle on
Kubernetes + GitOps platform (K3s / Terraform / ArgoCD / KEDA). Pre-launch.

---

## 1. Context & problem

LuminaVault works functionally but cannot scale past one host or one API replica:

- **Per-tenant Hermes = one Docker container per user**, bound to a host port from
  range 9000–9500 (`M41_HermesTenantContainers`, `App+build.swift:183-186`), launched by
  shelling `docker` on the same host (`ProcessDockerExec`). → ~500-tenant hard cap per
  host; no orchestration; API and all tenant containers share one VPS.
- **API holds shared state in memory** (rate-limit, `PreAuthChallengeStore`,
  `MeTodayCache`, achievement cache). → API is effectively single-replica; a second
  replica splits rate-limit counters and diverges caches. Redis is only a *seam* today
  (`RateLimitStorageFactory.swift:29` logs a warning and falls back to memory; no
  `RediStack`/`hummingbird-redis` dependency exists).
- Single VPS, no HA, disk fills.

Hard constraints that shape the design:

- **Hermes is single-tenant by design** — it loads ONE user's brain / skills / SOUL /
  context into memory at startup. Shared-runtime multi-tenancy is **not possible** without
  rewriting Hermes. X must never see Y's context or skills; the process boundary is the
  isolation guarantee.
- **Phone signals (Apple Health / Music / Maps) feed Hermes continuously**, even when the
  app is closed — Hermes is a long-lived, frequently-active per-user service, not idle.
- **Latency to the LLM / chat path is product-critical.** First-token latency is the UX.

## 2. Goals / non-goals

**Goals**
- API tier scales horizontally (2–N replicas behind HPA), all shared state in Redis.
- Run up to low-thousands of single-tenant Hermes instances across a node pool, with
  per-user isolation preserved, affordably (idle instances hibernate).
- Background phone-signal ingestion is durable and decoupled from Hermes uptime.
- Full GitOps platform: Terraform-provisioned K3s, ArgoCD-synced platform, KEDA-driven
  scale-to-zero. Built pre-launch (explicit user decision; learning is a stated goal).
- Cold-start latency hidden for the user's first interaction.

**Non-goals (YAGNI)**
- Rewriting Hermes to be multi-tenant.
- Multi-region / global HA (single region to start).
- Per-tenant *containers* on raw Docker (replaced).
- Self-hosted Postgres in-cluster (use managed).

## 3. Assumptions to confirm before implementation

- **A1 — Greenfield:** no real prod-user Hermes data to migrate (closed pre-launch).
  If beta users with live Hermes state exist, add a data-migration step
  (`/app/data/hermes-tenants/<tenant>` → per-tenant PVC).
- **A2 — Hermes hibernate/resume:** a Hermes instance can be stopped and cleanly resumed
  from its persisted data dir (PVC) with no state loss. **This is the load-bearing
  feasibility risk** — must be validated in a spike before committing to scale-to-zero.
  If it fails, fall back to always-on per-user pods + a larger node pool (cost up, design
  otherwise unchanged).
- **A3 — Managed Postgres supports pgvector** (Hetzner managed PG / Supabase / Neon — all
  do; confirm the chosen one + HNSW/IVFFlat).

## 4. Architecture

```
        ┌──────────── K3s cluster (Terraform-provisioned Hetzner nodes) ────────────┐
iOS ─TLS─▶  Traefik ingress                                                          │
        │      ▼                                                                      │
        │   API Deployment (Hummingbird, 2–N replicas + HPA, STATELESS)              │
        │      ├─▶ Redis  (rate-limit, pre-auth, caches, locks, tenant→Hermes route, │
        │      │            per-tenant ingestion streams)                            │
        │      ├─▶ Managed Postgres + pgvector  (external to cluster)                 │
        │      ├─▶ per-tenant QUEUE = Redis Stream  ◀── phone signals (Health/etc.)   │
        │      └─▶ Hermes control plane = Operator + `HermesInstance` CRD             │
        │              reconciles 1 StatefulSet + PVC + Service per tenant;           │
        │              KEDA ScaledObject scales each 0↔1 on stream-depth/activity     │
        │            Hermes-A    Hermes-B    Hermes-C ...  (single-tenant pods)        │
        │            (PVC-A)     (PVC-B)     (PVC-C)        hcloud-csi volumes         │
        └─────────────────────────────────────────────────────────────────────────── ┘
 ArgoCD syncs PLATFORM Helm charts from git (API, Redis, operator, KEDA, Traefik, OTel).
 Per-tenant HermesInstance CRs are RUNTIME objects the operator owns — NOT in git.
```

Two control surfaces, deliberately separated:
- **Declarative platform** (in git, ArgoCD): everything static and shared.
- **Dynamic tenant fleet** (runtime, operator-owned): one CR per user, created at signup,
  reconciled into a StatefulSet/PVC/Service, scaled 0↔1 by KEDA.

## 5. Components

Each: purpose / interface / dependencies.

### 5.1 Stateless API (Hummingbird) — *refactor*
- **Purpose:** HTTP/SSE API; now horizontally scalable. Owns tenant provisioning by
  creating/patching `HermesInstance` CRs (not by running containers).
- **Interface:** existing OpenAPI contract (unchanged for clients). New internal calls to
  the K8s API (create/patch CR) and Redis.
- **Depends on:** Redis, managed Postgres, K8s API (RBAC-scoped service account).
- **Change set:**
  - Add `hummingbird-redis` (RediStack) to `Package.swift`.
  - Implement the `.redis` branch in `RateLimitStorageFactory` (HB `RedisPersistDriver`).
  - Port `PreAuthChallengeStore`, `MeTodayCache`, achievement cache → Redis.
  - Provisioning lock + tenant→Hermes routing in Redis.
  - Replace `ProcessDockerExec` provisioning with a K8s-CR client
    (create/patch/delete `HermesInstance`).
  - Wire Redis + Postgres clients into `ServiceGroup` lifecycle (no `defer { Task }`).

### 5.2 Redis (in-cluster)
- **Purpose:** rate-limit `PersistDriver`, pre-auth challenges, caches, distributed locks,
  tenant→Hermes routing table, per-tenant ingestion **Streams**.
- **Interface:** RediStack from the API + the queue consumer in Hermes/sidecar.
- **Depends on:** PVC for light persistence (or accept ephemeral + rebuild). Single
  instance to start; Sentinel/cluster later if it becomes critical-path.

### 5.3 Ingestion queue (Redis Streams)
- **Purpose:** durable buffer of phone signals per tenant; decouples phone from Hermes
  uptime; lets Hermes hibernate and drain on wake; KEDA scale signal (stream depth).
- **Interface:** API `XADD`s to `tenant:<id>:signals`; Hermes (or a drain sidecar)
  `XREADGROUP`s + acks.
- **Depends on:** Redis. (NATS JetStream is the upgrade path if fan-out/throughput grows.)

### 5.4 Hermes Operator + `HermesInstance` CRD (Go / Kubebuilder) — *new*
- **Purpose:** reconcile desired per-tenant Hermes state. One CR ⇒ one StatefulSet(1) +
  PVC + Service + KEDA ScaledObject. Handles create, wake, hibernate, delete, self-heal,
  reschedule on node drain.
- **Interface:** `HermesInstance` CR (`spec: { tenantID, image, resources, dataVolumeSize,
  idleTimeout }`, `status: { phase, endpoint, lastActiveAt }`). API writes spec; reads
  status/endpoint.
- **Depends on:** K8s API, KEDA, hcloud-csi (PVC).
- **Why operator (not API-imperative / ArgoCD ApplicationSet):** dynamic per-tenant
  lifecycle + scale-to-zero + self-heal, declaratively, without tangling cluster logic
  into the app or abusing ArgoCD for thousands of churning apps.

### 5.5 KEDA
- **Purpose:** scale each tenant's StatefulSet 0↔1 on Redis-stream depth and/or an
  activity key. Wake on first queued signal or a live chat request; hibernate after
  `idleTimeout` with an empty stream.
- **Depends on:** Redis (scaler), the operator (creates ScaledObjects).

### 5.6 Platform (Terraform + ArgoCD + Traefik + observability)
- **Terraform:** Hetzner nodes, network/LB, hcloud-csi, DNS, K3s bootstrap, managed-PG
  provisioning + secrets.
- **ArgoCD:** sync platform Helm charts from git (API, Redis, operator, KEDA, Traefik,
  OTel→Jaeger/Grafana). App-of-apps pattern.
- **Traefik:** ingress/TLS.
- **Observability:** keep existing OTel; add cluster + per-tenant pod metrics, KEDA
  scale events, cold-wake timing.

## 6. Data flow

**Signup →** API creates `HermesInstance` CR → operator provisions PVC+StatefulSet+Service
+ ScaledObject → Hermes boots, initializes the user's brain on its PVC → status `Ready`.

**Phone signal →** API auth + tenant scope → `XADD tenant:<id>:signals` → (KEDA wakes
Hermes if hibernated) → Hermes drains stream, updates brain on PVC, acks.

**Chat (latency-critical) →** on app login/foreground, API issues a **pre-warm** (ensure
ScaledObject ≥1) so the pod is warm before the first message → chat request routes to the
tenant's Hermes Service → SSE stream back. Hibernated-instance first message pays wake
latency (mitigated by pre-warm).

**Idle →** stream empty + no activity for `idleTimeout` → KEDA scales to 0; PVC persists.

## 7. Migration / sequencing (phased — each phase independently shippable)

1. **P1 — Redis + stateless API (no K8s yet).** Add Redis, port all in-memory state,
   run 2 API replicas via current Docker Compose. Delivers multi-replica immediately.
   *(This is the original "cheap high-leverage fix.")*
2. **P2 — Cluster foundation.** Terraform → K3s + hcloud-csi + managed PG + Traefik +
   ArgoCD app-of-apps. Deploy the stateless API + Redis to the cluster. Cut traffic over.
3. **P3 — Ingestion queue.** Redis Streams ingestion path; API `XADD`; Hermes drain
   consumer. Validate durability (no loss across restarts).
4. **P4 — Hermes operator (always-on first).** `HermesInstance` CRD + Kubebuilder
   operator reconciling StatefulSet+PVC+Service. API switches provisioning from
   `ProcessDockerExec` → CRs. **No scale-to-zero yet** — always-on, correctness first.
5. **P5 — Scale-to-zero.** Spike A2 (hibernate/resume from PVC). If green: KEDA
   ScaledObjects + pre-warm-on-login + idle hibernation. If red: stay always-on, size the
   node pool, revisit.
6. **P6 — Latency validation + hardening.** Measurement (see §8), chaos tests, HA on
   Redis/ingress, backups.

## 8. Latency validation (refactor-first, measure-after)

No latency gate during build. After P4/P5, extend `audit/baseline.md`:
- Cold wake: hibernated → first token (the worst-case UX number).
- Warm chat: p50/p95/p99 first-token + full-response.
- Queue-drain lag: signal `XADD` → reflected in Hermes.
- API p95 under HPA at target concurrency.
- Validate pre-warm-on-login closes the cold-start gap.

## 9. Testing

- API: Redis-backed rate-limit correctness across 2 replicas; cache parity.
- Queue: kill Hermes mid-drain → zero event loss, exactly-once-ish via consumer groups.
- Operator: reconcile unit tests + `envtest`; CR create→Ready; delete→cleanup.
- Scale-to-zero: KEDA 1→0→1 on a k3d/kind cluster; data intact across the cycle.
- Chaos: node drain reschedules tenant pods; PVC reattaches.
- Isolation regression: tenant A cannot reach tenant B's Hermes Service / data.

## 10. Risks

- **R1 (load-bearing):** Hermes can't cleanly hibernate/resume from PVC (A2). Mitigation:
  spike early (P5 gate); fallback always-on.
- **R2:** Operator is the largest new build + Go learning curve. Mitigation: P4 always-on
  first (smaller blast radius), Kubebuilder scaffolding, envtest.
- **R3:** Cold-start UX if pre-warm misses (e.g., signal-driven wake while user is mid-app).
  Mitigation: pre-warm on login AND foreground; keep `idleTimeout` generous.
- **R4:** Cost of many always-ish-on pods. Mitigation: scale-to-zero (P5), right-size
  requests/limits, node autoscaling.
- **R5:** Redis becomes a single point of failure (now critical-path: rate-limit, routing,
  queue). Mitigation: persistence + Sentinel/managed Redis before real launch.

## 11. Open questions
- Managed PG choice (Hetzner vs Supabase vs Neon) — pick on pgvector + region + price.
- Operator in Go/Kubebuilder confirmed; who owns/maintains it long-term (Go skill)?
- Redis Streams vs NATS JetStream threshold — start Streams, define the migrate trigger.
- A1 greenfield confirmation (any beta users to migrate?).
