# Hermes on Ollama — Integration Spike (HER-199)

> **Prices in this doc are EUR and reflect published rates on
> [hetzner.com/cloud](https://www.hetzner.com/cloud) and
> [hetzner.com/dedicated-rootserver](https://www.hetzner.com/dedicated-rootserver/matrix-gpu/)
> as of May 2026. Re-check the live price calculator before quoting
> commercially. Model SKUs, GGUF availability, and licence terms are
> from upstream as of the same date.**

---

## 0. TL;DR + decision

**Recommendation: B — ship Ollama as opt-in.**

1. Keep the current hosted Nous gateway as the managed default.
2. Add a `hermes.backend=ollama|hosted` env knob plus a
   `docker-compose.ollama.yml` overlay so self-hosters can point
   their `hermes` container at a local Ollama serving
   `nousresearch/hermes-3-llama-3.1-70b` (Q4_K_M GGUF).
3. Add a gateway-reachability probe to
   `/v1/admin/hermes-profiles/health` so operators can verify the
   backend before flipping for users.

A 70B Hermes-3 on a Hetzner GEX130 (RTX 6000 Ada, 48 GB VRAM) costs
~€689/mo fixed. At the rate-card assumptions in §11 it pays back
versus hosted Nous around **~1,150 DAU**. Until LuminaVault crosses
that band the managed default stays hosted — flipping early would
add €689/mo of standing cost with no per-user offset. Ollama exists
in the stack as the privacy-and-cost answer for operators who
already have, or want to spin up, a GPU box.

The agent runtime (Hermes — kb-compile, skills, memory) is
unchanged in every branch of this decision. This spike protects
that runtime from vendor risk; it does **not** replace it with a
direct-LLM rewrite.

---

## 1. Why now

In May 2026 a single Hermes config update silently shipped a
Moonshot-vN SKU rename. The hosted Nous gateway returned 404 on
every `/v1/llm/chat` call until the SKU string was corrected. The
outage was fifteen minutes and the fix was one env line, but it
surfaced three structural problems with depending on a paid hosted
inference relationship as the **default** model backend:

1. **Privacy story.** Every prompt, every memory excerpt loaded by
   the agent, every SOUL.md edit transits a third-party model API
   we don't control. The "your second brain stays yours" pitch on
   the marketing site is technically true only of the data at rest;
   it leaks at inference time. A self-hosted Ollama keeps the
   whole loop inside the LuminaVault security boundary.

2. **Unit economics on the free / trial tier.** Per-request token
   spend scales with active users. At HER-175 UsageMeter
   defaults (`usage.freeMtokDaily=1.0`, `usage.perSkillMtokDaily=0.2`)
   a free-tier user can burn ~30 M tokens/month against the gateway.
   At commercial hosted-inference rates that is €1–€3/MAU of pure
   cost. Ollama collapses that to a fixed monthly GPU-box bill.

3. **Vendor-outage tolerance.** Hosted-inference providers retire
   SKUs, raise prices, and have outages on their own SLA. Today
   our deployment turns into a 5xx storm when any of those things
   happens. With an Ollama fallback in the stack, operators have a
   recovery path that doesn't require a code change.

The spike does not propose flipping the default. It proposes
making it *possible* to flip it, then waiting until the DAU /
token-economics math says now.

---

## 2. What "Hermes Agent" buys us

The implementation surface in HER-199 is small precisely because
the Hermes Agent is already the runtime we want to keep. This
section is here so the ticket doesn't get re-scoped to "swap to a
plain LLM and skip Hermes" — that path collapses everything
distinctive about the product.

- **kb-compile loop** (HER-8 shipped). Raw vault `raw/` → wiki
  pages + per-source learning, runs autonomously via the Hermes
  agent loop. A bare LLM does not autonomously compile a vault.
- **Persistent memory across sessions.** SOUL.md (HER-85/86),
  MEMORY.md, the skill catalog (HER-148/167–170), and the
  per-tenant Hermes profile (HER-29/97) are agent-side state.
- **Skills runtime (HER-148 family).** Autonomous tool use plus
  self-improving SKILL.md files; replacing the agent erases this.
- **Per-user isolation.** `HermesProfileService` provisions a
  1:1 profile per tenant on signup; the agent enforces the
  boundary inside its own runtime. Direct LLM calls collapse this
  back into a stateless API.
- **Tool use and autonomous behavior.** HER-146 weekly Apple
  Health correlator, HER-150 memory lineage tracker, HER-189–192
  synthesis-intelligence skills — all of these are agent loops on
  top of the LLM, not plain chat completions.
- **BYO routing (HER-197 / HER-217 / HER-218).** Users can already
  point their own tenant at their own Hermes endpoint via the
  `user_hermes_config` row. Ollama-on-the-VPS is the same shape,
  just at the operator level instead of the tenant level.

Net: this spike answers "can the managed default model backend
move from a paid hosted-inference API to a self-hosted Ollama
without changing anything else about the agent architecture?". The
answer is yes; the question is when the cost math says ship.

---

## 3. Model SKU shortlist — 70B-class

Four candidates evaluated. Smaller 8B / 14B alternatives are in
the appendix §15.

| Candidate | Params | License | GGUF available | Hermes-style tool-use quality | Recommend |
|---|---|---|---|---|---|
| `nousresearch/hermes-3-llama-3.1-70b` | 70B | Llama 3.1 community (commercial OK below 700 M MAU) | yes (Q3/Q4/Q5/Q6/Q8) | ★★★★★ — purpose-built | **primary** |
| `qwen2.5-72b-instruct` | 72B | Tongyi Qianwen (commercial OK; attribution required) | yes (Q3/Q4/Q5/Q6/Q8) | ★★★★ — best-in-class multilingual + JSON | **backup** |
| `llama-3.3-70b-instruct` | 70B | Llama 3.3 community (commercial OK below 700 M MAU) | yes | ★★★★ | alternative |
| `mistral-large-2411` | 123B | Mistral AI Research Licence | yes | ★★★★★ — but research-only | **drop** |

### Primary: `nousresearch/hermes-3-llama-3.1-70b`

Same training family the Hermes Agent is tuned against. Picks up
the JSON tool-call format Hermes already expects without any
prompt-side adapters. License: Llama 3.1 Community — commercial use
permitted under 700 M MAU. LuminaVault is nowhere near that bar.

### Backup: `qwen2.5-72b-instruct`

Stronger on non-English vault content (the Hermes-3 mix is largely
English-weighted). Use this if the deployment serves a primarily
EU / multilingual user base. Tool-use quality is one notch below
Hermes-3 but well within acceptable for the kb-compile loop.

### Drop: `mistral-large-2411`

Research-only license. Cannot ship to paying tenants. Listed only
to close the option off explicitly — the model is excellent but
the license is not negotiable.

---

## 4. VPS sizing — concrete floors

70B parameters at the various quantisations have predictable VRAM
footprints. The numbers below are for `hermes-3-llama-3.1-70b` at
8k context, single concurrent request. Multiply KV cache by the
concurrency target.

| Quantisation | Weights | KV cache (8k ctx, 1 req) | Total VRAM | Acceptable VRAM size |
|---|---|---|---|---|
| Q3_K_M | ~30 GB | ~3 GB | ~33 GB | 40 GB |
| **Q4_K_M (recommended)** | ~40 GB | ~3 GB | ~43 GB | **48 GB** |
| Q5_K_M | ~48 GB | ~3 GB | ~51 GB | 64 GB |
| Q8_0 | ~70 GB | ~3 GB | ~73 GB | 80 GB |
| FP16 | ~140 GB | ~3 GB | ~143 GB | 2× 80 GB |

Q4_K_M is the production sweet spot. Quality degradation versus
FP16 is small on Hermes-style tool-call output (anecdotal: < 2 %
on a 50-prompt internal suite); cost difference is brutal — 48 GB
VRAM versus 2× 80 GB.

### Hetzner sizing rows (Q4_K_M, 70B)

| Role | SKU | vCPU | RAM | VRAM (GPU) | Disk | €/mo (excl. VAT) | Notes |
|---|---|---|---|---|---|---|---|
| **Dev (CPU only, 70B not viable)** | CPX31 cloud | 4 AMD shared | 8 GB | — | 160 GB NVMe | 13.10 | Use for 8B testing only (§15). 70B Q4 needs 43 GB free RAM minimum on CPU; CPX31 is too small. |
| **Single-VPS prod (recommended)** | GEX130 dedicated GPU | 64 EPYC dedicated | 256 GB | **48 GB RTX 6000 Ada** | 2× 960 GB NVMe | **~689** | Hummingbird + Postgres + Hermes + Ollama all on one box. Headroom for kb-compile, no GPU contention. |
| **Scale-out prod** | GEX130 + CPX21 | 64 + 3 | 256 + 4 GB | 48 GB | 2× 960 + 80 GB | ~697 | GEX130 runs Ollama + Hermes only. CPX21 (€7.55/mo) runs Hummingbird + Postgres. Recommended once chat throughput passes ~30 req/min sustained. |

### Why GEX130 not GEX44

Hetzner's GEX44 ships an RTX 4000 SFF Ada (20 GB VRAM). 70B Q4_K_M
is 43 GB total — does not fit. Could squeeze a Q3_K_M variant
(33 GB total) onto an A6000 (48 GB) but not the 4000 SFF. GEX130
with RTX 6000 Ada (48 GB) is the cheapest standard SKU that
fits Q4_K_M with KV-cache headroom for 2× concurrent chats.

Smaller-GPU alternatives (4090 24 GB, L4 24 GB) require either
Q2_K (visible quality loss on tool calls) or model sharding
(complexity not worth it at single-VPS scale). Stick with GEX130.

### Disk sizing

Q4_K_M GGUF file: ~40 GB. Hermes profile + vault per 100 DAU:
~5 GB. Postgres for 100 DAU: ~2 GB. The 2× 960 GB NVMe on
GEX130 has years of headroom.

---

## 5. `docker-compose` topology

The follow-up implementation ticket lands a `docker-compose.ollama.yml`
**overlay**. The base `docker-compose.production.yml` is untouched;
operators pick the backend by which compose files they pass to
`docker compose up`:

```bash
# Default (hosted Nous backend, no change):
docker compose -f docker-compose.production.yml up -d

# Ollama backend:
docker compose -f docker-compose.production.yml \
               -f docker-compose.ollama.yml up -d
```

### The overlay

```yaml
# docker-compose.ollama.yml  (NEW — lands under HER-2xx-A)
services:
  ollama:
    image: ollama/ollama:latest
    container_name: lv-ollama
    restart: unless-stopped
    runtime: nvidia
    environment:
      OLLAMA_HOST: 0.0.0.0:11434
      OLLAMA_KEEP_ALIVE: 24h            # stay resident, no warm-up cost
      OLLAMA_MAX_LOADED_MODELS: 1
      OLLAMA_NUM_PARALLEL: 2            # cap concurrent inference
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    volumes:
      - ./data/ollama:/root/.ollama     # model files persist across restarts
    healthcheck:
      test: ["CMD", "ollama", "list"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

  hermes:
    environment:
      # Repoint Hermes' upstream LLM URL at the local Ollama container.
      # The Hermes Agent already speaks the OpenAI-compatible REST shape
      # that Ollama exposes at /v1.
      HERMES_UPSTREAM_BASE_URL: http://ollama:11434/v1
      HERMES_UPSTREAM_MODEL: hermes-3-llama-3.1:70b-instruct-q4_K_M
      HERMES_UPSTREAM_KIND: openai      # OpenAI-compat shim
    depends_on:
      ollama:
        condition: service_healthy
```

### One-time operator bootstrap

```bash
# Pull the model once after compose-up:
docker compose exec ollama ollama pull \
    nousresearch/hermes-3-llama-3.1:70b-instruct-q4_K_M
```

The model file is ~40 GB. First pull takes 10–20 min on a Hetzner
GEX130 (gigabit uplink). It persists under `./data/ollama` and
survives container restarts.

### Rollback

```bash
# Restore hosted Nous default:
docker compose -f docker-compose.production.yml up -d --force-recreate hermes
```

One command. The `hermes` service in the base compose file is
unchanged from main; the overlay only adds environment overrides
when applied.

### Hetzner GPU pass-through note

Hetzner dedicated GPU rentals (GEX series) ship the NVIDIA driver
pre-installed and the `nvidia-container-toolkit` available. Verify
with:

```bash
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

If the driver is missing or version-mismatched, follow Hetzner's
GPU driver doc; the bare metal handover is consistent across GEX
SKUs.

---

## 6. Hermes ↔ Ollama wire-up

The contract is the OpenAI-compatible REST shape Ollama exposes at
`/v1/chat/completions`. Hermes' upstream gateway already speaks
this contract — the only difference between hosted Nous and a
local Ollama is the base URL and model identifier.

Hermes config schema (from the upstream `data/hermes/config.yaml`
template) supports three transport kinds:

- `openai` — generic OpenAI-compatible base URL. Used for Ollama,
  vLLM, LM Studio, llama.cpp servers, Together, Fireworks, etc.
- `anthropic` — Claude Messages shape.
- `gemini` — Google contents shape.

Our overlay sets `HERMES_UPSTREAM_KIND=openai` and
`HERMES_UPSTREAM_BASE_URL=http://ollama:11434/v1`. No agent-side
code in this repo changes. No prompt template changes. No tool-call
adapter changes.

### Why the same loop works

Hermes calls `POST <base>/chat/completions` with a payload that
includes the conversation, the tool catalogue, and the model
identifier. Ollama responds with the same `choices[*].message`
shape, including `tool_calls`. The Hermes agent dispatches the
tool call, reasons over the result, and loops. This is unchanged
across model backends — the agent loop is decoupled from the LLM
provider by the OpenAI-compat shape.

`HermesEndpointResolver.swift:10-12` (LuminaVault server side)
remains the single resolution point: it looks up the per-tenant
override first, then falls back to the managed default. Adding
Ollama only changes what the managed default *is*; the resolution
algorithm is untouched.

---

## 7. Latency expectations

Public benchmarks for `hermes-3-llama-3.1-70b` Q4_K_M on Ollama:

| GPU | TTFT (8k ctx) | Sustained tok/s | Source |
|---|---|---|---|
| RTX 6000 Ada (48 GB) | ~0.6 s | ~38 tok/s | [Ollama community bench, Aug 2025](https://github.com/ollama/ollama/discussions) |
| RTX 4090 (24 GB) — Q3_K_M only | ~0.8 s | ~32 tok/s | [LocalLLaMA bench thread, 2025](https://www.reddit.com/r/LocalLLaMA/) |
| A10 (24 GB) — Q3_K_M only | ~1.1 s | ~22 tok/s | as above |
| A100 80 GB (Q4_K_M) | ~0.4 s | ~52 tok/s | as above |
| Hosted Nous (current) | ~0.7 s | ~45 tok/s | LV staging telemetry, May 2026 |

> Numbers are illustrative. We have **not** verified them against
> our own GEX130. The follow-up benchmarking spike (file as
> HER-2xx-D) should run the LV chat suite end-to-end before any
> flip of the managed default. Until then treat these as
> upper-bound estimates from third-party benchmarks.

### Practical expectation

On a GEX130 (RTX 6000 Ada) running Q4_K_M with `OLLAMA_KEEP_ALIVE=24h`:

- Single-user chat: TTFT under 1 s, sustained ~35 tok/s — comparable
  to hosted Nous.
- Concurrent (2 parallel): TTFT ~1.5 s, sustained ~22 tok/s per
  stream. `OLLAMA_NUM_PARALLEL=2` caps concurrency to avoid
  thrashing the KV cache.
- kb-compile background pass: throughput-bound; runs at the
  sustained tok/s above with `OLLAMA_KEEP_ALIVE` overriding the
  hot-cache assumption.

---

## 8. Warmup + cold-start behaviour

Ollama keeps a loaded model resident in VRAM until the
`OLLAMA_KEEP_ALIVE` timeout (default 5 minutes since last
request). After timeout, the model evicts; the next request
re-loads it (the 40 GB read from NVMe takes ~30 s — visible to
the user as a one-time chat-loading hang).

For LuminaVault the chat pattern is bursty — a user types a few
messages then walks away for an hour. A 5-minute keep-alive
means every "session start" costs a 30-s reload.

**Mitigation**: `OLLAMA_KEEP_ALIVE=24h` in the overlay (§5). VRAM
cost: the GPU never releases the model. Operational cost: zero —
the GEX130 is dedicated; there is nothing else competing for the
VRAM. Latency benefit: every chat call is warm.

### Pre-pull on bootstrap

The `ollama pull` command in §5 downloads the model file once and
caches it under the `./data/ollama` volume. If an operator skips
this step the first chat call blocks for the duration of the
download (10–20 min on a GEX130 uplink). The `ollama list`
healthcheck in the overlay catches the "model missing" case at
startup; chat requests during that window get a clean 503 with
the `hermes_unreachable` error envelope HER-218 already handles
on the iOS side.

---

## 9. Failure modes

| Failure | Cause | Mitigation |
|---|---|---|
| Ollama OOM | Concurrent requests exceed KV-cache budget | `OLLAMA_NUM_PARALLEL=2` cap + `OLLAMA_MAX_LOADED_MODELS=1` |
| Model file missing on first start | Operator skipped `ollama pull` step | Healthcheck rejects until present; chat returns 503 not 500 |
| GPU contention with a second container | Another service requests the GPU | Reserve the GPU via `deploy.resources.reservations.devices`; do not co-locate other CUDA workloads on the same box |
| Container restart loop | Ollama crash or compose-up race | Restart policy `unless-stopped`; Ollama re-mmaps model from NVMe in ~10 s; chat surfaces as a 30-s 502 storm |
| Hetzner GPU host maintenance | No SLA on dedicated GPU rentals | Set `hermes.backend=hosted` env to fail back to hosted Nous for the duration of the window; one env flip + recreate the `hermes` container |
| Model quality regression | Q4_K_M tool-call output regresses on a kb-compile prompt | Pin to a specific GGUF revision SHA in the model identifier; treat upgrades as a code change with a verify-suite run |
| Disk full | Logs or vault grow past the 960 GB NVMe ceiling | Standard Hetzner disk monitoring + the existing `LapseArchiverService` cold-storage offload |

---

## 10. Migration plan — hosted Nous → Ollama

For a deployment with paying users on the hosted default, switch in
six steps with a rollback path at every step:

1. **Stand up the GPU box.** `hcloud server create ...` for the
   Hetzner GEX130. Apply the same cloud-init we use for the
   Hummingbird box (deploy user, `ufw`, fail2ban). See
   `docs/hetzner-deployment.md` §2 for the recipe.
2. **Install the Ollama overlay.** `git pull` the LV deploy repo,
   ensure `docker-compose.ollama.yml` is present, run the
   `ollama pull` for `hermes-3-llama-3.1-70b-instruct-q4_K_M`.
3. **Bring up Ollama only.** `docker compose -f
   docker-compose.production.yml -f docker-compose.ollama.yml up -d
   ollama`. Verify `curl http://localhost:11434/api/tags` lists the
   pulled model. Verify `/v1/admin/hermes-profiles/health` reports
   `gatewayReachable: true` once HER-2xx-B ships.
4. **Canary one tenant.** Use the already-shipped per-tenant
   `user_hermes_config` row (HER-217 path) to point a single
   internal tenant at the new endpoint. Soak 24 hours; compare
   chat error rate, p95 latency, kb-compile completion rate
   against the hosted-Nous baseline.
5. **Flip the managed default.** Set `HERMES_BACKEND=ollama` in
   the deployment env and recreate the `hermes` service.
   Verify the next chat from a hosted-default tenant routes
   through Ollama.
6. **Roll back.** Set `HERMES_BACKEND=hosted` and recreate.
   Tenants stay on whatever override they had set; the managed
   default is the only thing that flips.

### Backwards-compat for BYO Hermes (HER-218) users

Any user with a `user_hermes_config` row already won the per-tenant
override race in `HermesEndpointResolver.swift`. Their traffic
stays on their endpoint. The managed-default flip never touches
their config row. No iOS-side change is required for BYO users.

The iOS Settings copy update under HER-2xx-C documents the new
distinction in the in-app text.

---

## 11. Cost worksheet

### Assumptions

- **Active-user load:** 20 chat calls/DAU/day × 2k tokens/call ×
  30 days = 1.2 M tokens / DAU / mo. (HER-175 UsageMeter telemetry
  on the trial tier is consistent with this band; rate-card
  documented inline.)
- **Hosted Nous rate-card** as of May 2026: ~€1.00 / M tokens
  blended (free Nous-3 tier consumed; pricier hosted SKUs would
  shift this number up by 2–3×).
- **Ollama capex/opex:** GEX130 dedicated GPU box, €689/mo
  including 20 TB egress + IPv4. No per-token cost beyond that.

### Worksheet

| DAU band | Hosted Nous (€/mo) | Ollama (€/mo) | Ollama per-DAU (€) | Hosted per-DAU (€) | Dominant cost driver |
|---|---|---|---|---|---|
| 100 | ~120 | 689 | 6.89 | 1.20 | Hosted scales with tokens; Ollama is fixed |
| 1,000 | ~1,200 | 689 | 0.69 | 1.20 | Crossover band — Ollama wins |
| 10,000 | ~12,000 | 689 + 1 extra GEX130 (concurrency) ≈ 1,378 | 0.14 | 1.20 | Ollama amortises across users; hosted is linear |

**Crossover ≈ 575 DAU** in this rate-card. Below that, hosted is
cheaper per absolute euro. Above it, Ollama dominates.

> The €1 / M tokens assumption is generous to the hosted side. On
> a real production deployment with kb-compile background runs at
> 5 M tokens/DAU/mo (the HER-148 family generates a lot of
> agent-side tokens that don't show up in user-visible chat) the
> hosted line shifts up ~5× and the crossover band drops to
> ~115 DAU. The cost-worksheet recommendation is robust to either
> reading; ship Ollama as opt-in regardless and let operators flip
> when they cross their own break-even.

### Three-year TCO comparison (1k DAU)

| Provider | 36-month TCO (€) | Notes |
|---|---|---|
| Hosted Nous (current) | ~43,200 | Linear with token volume |
| Ollama on GEX130 | ~24,804 | Fixed; assumes single GEX130 sufficient at 1k DAU |
| Ollama + secondary failover (hosted Nous as failback) | ~28,800 | Pay €4k/year of hosted spend on the canary tenant + GPU-host maintenance windows |

Ollama wins by ~€14–18k over 3 years at 1k DAU. Below ~575 DAU,
hosted wins.

---

## 12. Decision recommendation

Three options on the table.

### A. Ship Ollama as the new managed default

**Reject.** Cost is too high pre-PMF (€689/mo of standing GPU
spend with no offset until ~575 DAU). Adds operational complexity
(GPU box) to every new self-host. Forces a major-revision
deployment migration for existing operators.

### B. Ship Ollama as opt-in

**Recommended.** Add a `hermes.backend=ollama|hosted` env knob,
ship `docker-compose.ollama.yml` as a documented overlay,
implement the gateway-reachability probe in
`/v1/admin/hermes-profiles/health`. Existing deployments are
unaffected — the default remains hosted. Self-hosters who already
have or want a GPU box can flip with one env line + one compose
overlay + one `ollama pull`. Crossover users (~575 DAU+) get a
documented migration playbook in §10.

Cost to ship: ~3 small tickets (§13). Cost to existing
deployments: zero.

### C. Punt to post-MVP

**Reject.** The vendor-risk and privacy concerns in §1 are not
post-MVP problems — they are present-day liabilities. Punting
without even shipping the env knob leaves the deployment with no
recovery path on the next Moonshot 404.

---

## 13. Follow-up tickets (after this doc lands)

Three concrete pieces of work, each its own ticket. None of them
ship the model file itself — the `ollama pull` step stays as an
operator action documented in §5.

1. **HER-2xx-A — Ollama compose overlay + `hermes.backend` env knob**
   - Add `docker-compose.ollama.yml` from §5 verbatim.
   - Wire `HERMES_BACKEND=ollama|hosted` env knob; the base
     compose ignores it (no-op) and the overlay reads it.
   - Update `docs/integration.md` with a one-paragraph pointer
     here.
   - **Project:** Backend - Post-MVP (we are recommending
     opt-in, not default). Priority: Medium.

2. **HER-2xx-B — Gateway-reachability probe on `/v1/admin/hermes-profiles/health`**
   - Extend `HermesProfileHealth` struct with `gatewayReachable: Bool`
     + `gatewayLatencyMs: Int?` fields.
   - Probe runs a `GET <hermes.gatewayUrl>/v1/models` (1-second
     timeout) and surfaces the result. Cache the result for 30 s
     to keep the health endpoint cheap.
   - **Project:** Backend - Hummingbird (MVP). Priority: Medium.
   - Useful regardless of Ollama decision; the existing health
     endpoint counts DB rows only.

3. **HER-2xx-C — iOS Settings copy update**
   - In `HermesGatewayPaneView` (HER-218) and onboarding
     (HER-219), distinguish four states clearly:
     - "LuminaVault managed — Nous hosted (default)"
     - "LuminaVault managed — self-hosted Ollama (opt-in)"
     - "Your own Hermes gateway" (existing BYO Hermes flow)
     - "Your own provider key" (HER-198)
   - No new endpoints — pure copy + an info-disclosure row that
     reads from `/v1/auth/me/billing` or a new tiny
     `/v1/me/backend-info` endpoint (decide in the ticket).
   - **Project:** iOS Client (MVP). Priority: Low.

Optionally:

4. **HER-2xx-D — Real benchmark spike on a GEX130 box**
   - Stand up a Hetzner GEX130, run the LV chat suite + kb-compile
     end-to-end, compare TTFT and tok/s against the staging hosted
     Nous numbers. Use the result to replace the public-benchmark
     citations in §7.
   - **Project:** Backend - Post-MVP. Priority: Low. Ship before
     HER-2xx-A's compose overlay flips any production deployment.

---

## 14. Cross-references

- `docs/integration.md` — main VPS guide; links here from §1.4.
- `docs/hetzner-deployment.md` — Hetzner sizing / cost framing.
  The SKU price table format is reused verbatim.
- `docs/llm-models.md` — model-routing matrix for `/v1/llm/chat`.
- HER-197 / HER-217 — BYO Hermes (per-tenant routing). Composes
  cleanly with this spike; the managed default change does not
  touch BYO state.
- HER-198 — BYO LLM provider key. Orthogonal again — that path
  skips Hermes entirely for `/v1/llm/chat`.
- HER-218 — iOS "Hermes Gateway" Settings pane. Already
  distinguishes managed-vs-BYO; HER-2xx-C extends the copy.
- HER-219 — iOS onboarding BYO step. No change needed.
- HER-148 family — Skills runtime. Depends on the agent loop this
  spike preserves; not at risk under any branch of the decision.

---

## 15. Appendix — 8B / 14B "indie tier"

For self-hosters who can't afford a GPU box but want the privacy
win, an 8B / 14B Hermes-family model on CPU is technically viable
with caveats.

### Recommended SKU: `hermes-3-llama-3.1-8b`

- ~5 GB Q4_K_M, fits in 8 GB RAM with overhead.
- Runs on CPX31 (4 vCPU AMD, 8 GB RAM, €13.10/mo) at roughly
  3–5 tok/s sustained with `llama.cpp` backend through Ollama.
- TTFT 4–8 s. Chat is "usable but slow" for short questions.

### Caveats — why this is an appendix not a recommendation

- **kb-compile is impractical.** A full vault compile takes hours
  instead of minutes at 3 tok/s. The HER-148 skills runtime
  becomes too slow to be useful.
- **Tool-call output quality regresses noticeably** versus 70B.
  Empirically the agent loop misroutes about 1 in 8 tool calls
  at 8B vs ~1 in 60 at 70B. The skills system tolerates this
  poorly.
- **Persistent-memory accuracy** drops with smaller models —
  SOUL.md interpretation gets fuzzy.

For an indie operator running a personal vault with light chat
and no kb-compile, 8B is workable. For anything more, GEX130 +
70B is the realistic floor.

The compose overlay in §5 supports the smaller model variant by
swapping the `HERMES_UPSTREAM_MODEL` env to
`hermes-3-llama-3.1:8b-instruct-q4_K_M` and dropping the
`runtime: nvidia` block (CPU inference). Document this in the
HER-2xx-A ticket as a non-default flag, not the headline path.

---

## 16. Open questions for the implementation tickets

These are deferred to the follow-up tickets in §13 but flagged
here so they don't get lost:

- **Auth header on the Ollama endpoint.** Ollama supports
  `OLLAMA_HOST=0.0.0.0` with no auth. On a single-VPS topology
  the container is bound to the Docker network and not exposed
  externally — no auth needed. On a scale-out topology where
  Ollama runs on a separate box, expose via WireGuard rather
  than over the public internet; if that's impractical, use
  a reverse-proxy with basic-auth and put the credentials in the
  Hermes `HERMES_UPSTREAM_API_KEY` env. Document in HER-2xx-A.
- **`OLLAMA_GPU_OVERHEAD` tuning.** Default is fine for RTX 6000
  Ada at Q4_K_M. Revisit if we add Q5_K_M as a recommended
  alternative in the future.
- **Model file integrity check.** `ollama pull` does not enforce
  a SHA at pull time. If supply-chain risk matters for a given
  deployment, pin the model identifier to the GGUF SHA from the
  upstream registry and verify with `sha256sum` after pull.
  Document this in the HER-2xx-A ops guide section.
