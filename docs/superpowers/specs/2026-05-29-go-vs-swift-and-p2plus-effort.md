# Go vs Swift + P2+ Migration Effort — Analysis

Date: 2026-05-29
Context: companion to `2026-05-29-luminavault-scale-infra-design.md`. Two questions:
(1) was Swift/Hummingbird the wrong call vs Go? (2) what's the real effort to build P2+
(K3s / Terraform / ArgoCD / Hermes operator)?

---

## Part A — Go vs Swift: split the question, it's really two

### A1. The Hermes operator → **Go. Decisively.**
The operator is K8s-native control-loop code. The entire operator ecosystem is Go:
Kubebuilder / controller-runtime (informers, caches, work queues, leader election,
finalizers, status subresources, CRD codegen) is all Go and has no real Swift equivalent.
Writing an operator in Swift means hand-rolling against the K8s REST API with none of that
machinery — large effort, fragile, off the trodden path. KEDA, client-go, the CRD
tooling, every example you'll copy: Go. **Operator = Go + Kubebuilder** (already chosen in
the spec). Not in question.

### A2. The API server (LuminaVaultServer) → **keep Swift. Do NOT rewrite to Go.**
This is the real question, and the answer is keep Swift — for reasons specific to *your*
situation, not Swift-fanboyism:

1. **It already exists and is good.** The audit found genuinely solid engineering:
   enforced tenant isolation (`TenantModel`), encrypted BYOK, idempotency, tracing,
   structured concurrency. Rewriting to Go buys **zero product value** and throws away
   months of working, audited code. That's the most expensive possible move pre-launch.
2. **`LuminaVaultShared` is the killer argument.** Your wire DTOs are a **Swift package
   shared between the iOS client and the server** (your CLAUDE.md mandates it as the single
   source of truth). Go server ⇒ you **lose that sharing** — every DTO gets defined twice
   (Swift for iOS, Go for server) or you bolt on codegen. That's permanent ongoing drift
   risk + duplicated work on every API change. This single fact tips it decisively.
3. **Swift-on-server is not the bottleneck.** Hummingbird/NIO is async, fast, and fine for
   your scale. The audit's ceilings were the **per-tenant container topology** and
   **in-memory state** — architecture, not language. Go would not have helped any of them.
4. **The K8s seam is thin.** The API's only K8s job is "create/patch a `HermesInstance`
   CR and read its status." That is a handful of authenticated HTTPS calls to the API
   server (bearer token from the pod's ServiceAccount) — trivial from the existing Swift
   HTTP client. You do **not** need the app in Go to talk to K8s.

**When Go *would* have won:** if you were greenfield with no server and no iOS-shared DTOs,
Go is a defensible default for an infra-heavy, K8s-native product (one language across
app + operator + tooling, biggest cloud-native ecosystem, huge hiring pool). You are not
in that situation. The sunk, working, DTO-sharing Swift server flips it.

### A3. Verdict: polyglot, on the natural seam
- **API server:** Swift / Hummingbird (unchanged).
- **Operator (+ any K8s control-plane glue):** Go / Kubebuilder.
- **Seam:** Swift API creates `HermesInstance` CRs via the K8s REST API (SA token,
  in-cluster). Optionally a tiny Go "provisioner" HTTP service co-located with the operator
  if you'd rather keep *all* K8s calls in Go — but direct CR-create from Swift is simpler
  and enough. This is the standard split: app in your language, operator in Go. No rewrite.

> One honest cost of staying Swift: you'll personally context-switch between Swift (app)
> and Go (operator). That's a learning cost, but a *bounded* one (the operator is small and
> self-contained) — far cheaper than rewriting the whole backend.

---

## Part B — Effort to build P2+ (rough, solo dev new to K8s/Go)

Estimates are **ideal engineering-weeks for one developer new to this stack**, ranges wide
because the learning tax dominates. Not calendar time. The two big rocks are **P2 (infra
learning)** and **P4 (Go operator)**.

| Phase | Scope | New-skill load | Effort (rough) | Risk |
|------|-------|----------------|----------------|------|
| **P1** | Redis + stateless API (plan written) | Low — it's Swift, your turf | **2–4 days** | Low |
| **P2** | TF → K3s + hcloud-csi + Traefik + ArgoCD app-of-apps + managed PG; deploy stateless API; cut over | **High** — TF, K3s, ArgoCD, GitOps all new | **1.5–3 weeks** | Med — most of the learning tax lives here |
| **P3** | Redis Streams ingestion + Hermes drain consumer | Med — Swift side easy; **Hermes-side consume is the unknown** | **3–6 days** + spike | **Med-High** — can Hermes read from a queue, or do you need a drain sidecar? |
| **P4** | Hermes Operator: CRD + reconcile StatefulSet/PVC/Svc, API switches provisioning to CRs (**always-on first**) | **Highest** — Go + Kubebuilder + controller-runtime + CRD design, all new | **2–4 weeks** | High — biggest single rock; correctness of reconcile + cleanup/finalizers |
| **P5** | Scale-to-zero: KEDA + hibernate/resume + pre-warm-on-login | Med | **1–1.5 weeks** + spike | **High — gated by A2 feasibility:** can Hermes stop/resume cleanly from its PVC? If no, scale-to-zero is dead and you stay always-on |
| **P6** | Latency measurement, chaos tests, Redis HA, backups, monitoring | Med (monitoring skills now installed) | **1–2 weeks** | Med — ongoing hardening |

**Total: ~8–14 weeks of mostly-new-skill work**, front-loaded with learning (P2) and
dominated by the operator (P4). Halve the learning-tax portions if you pair with the
installed DevOps skills (`iac-terraform`, `gitops-workflows`, `k8s-troubleshooter`,
`monitoring-observability`) and lean on Kubebuilder scaffolding.

### Critical-path risks to de-risk *before* committing the full estimate
- **R-Hermes-resume (A2):** can a Hermes instance hibernate and resume from its data dir
  with no loss? Spike this in **P0, before P4/P5**. If it fails: no scale-to-zero → bigger
  always-on node pool → higher cost, but the rest of the design holds.
- **R-Hermes-queue (P3):** does Hermes ingest from an external queue, or must you write a
  drain sidecar that reads Redis Streams and feeds Hermes? Confirm Nous/Hermes capabilities.
- **R-operator-scope (P4):** per-user StatefulSet+PVC at hundreds–thousands of CRs — watch
  reconcile throughput, PVC quota on Hetzner, and node bin-packing. Always-on first shrinks
  blast radius while you learn.

### Honest re-flag (you already overrode this once — your call)
P2+ is **~2–3 months of infra-heavy work for a pre-launch product**, most of it new skills,
before it ships a single user-facing feature. The cheaper path to "scales past one host"
is: **P1 (Redis, days) + a lighter stepping stone** — keep per-tenant Hermes but move them
onto K8s as **always-on StatefulSets via simple Helm/ApplicationSet (no custom operator, no
scale-to-zero) first**, then add the operator + KEDA once you have users and the
hibernate/resume risk is proven. That gets you horizontal scale + multi-node in ~P1+P2
(weeks) and defers the two big rocks (P4 operator, P5 scale-to-zero) until they pay for
themselves. The full operator pattern is correct *eventually*; the question is whether it's
worth ~6 of those weeks **before launch**.

---

## Recommendation
1. **Don't rewrite the server.** Swift API stays; Go only for the operator. (A2/A3.)
2. **Ship P1 now** (Redis, days, all Swift) — real value, no infra dependency.
3. **Spike the two Hermes unknowns early** (resume-from-PVC, queue-consume) — they gate P3/P5
   and can change the whole cost model.
4. **Consider the stepping-stone** (K8s always-on StatefulSets via Helm, no operator) before
   building the full operator + KEDA — get multi-node scale fast, defer the big rocks.
5. Build the **Go operator (P4) when** you've proven the Hermes lifecycle works and have
   users justifying the cost.
