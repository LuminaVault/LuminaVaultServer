# Hetzner Deployment (HER-31) — Optimized Docs

> **Status:** Scaffold. Each section below carries one or more `TODO(HER-31)`
> markers identifying what is missing. Promote a section by removing its
> marker once the content is filled in and verified end-to-end on a real
> Hetzner box.

Hetzner Cloud is the recommended primary host for LuminaVaultServer self-hosters
and small-team deployments. This guide is **Hetzner-specific** and assumes the
generic Ubuntu/VPS instructions in [`integration.md`](./integration.md) have
already been read.

---

## 0. Why Hetzner

<!-- TODO(HER-31): single tight paragraph on why Hetzner (€/GB-RAM ratio,
EU residency for GDPR, predictable bandwidth, no egress surcharge, 24h
support response). Cross-reference DO/AWS Lightsail in §9. -->

---

## 1. Sizing matrix

Three reference profiles, by tenant count. Numbers are **starting points** —
revisit after the first month of usage telemetry from `lv.usage.*` metrics.

| Tier         | Hetzner SKU | vCPU / RAM / Disk     | Concurrent users | Hermes model envelope | €/mo (excl. VAT) |
|--------------|-------------|-----------------------|------------------|-----------------------|------------------|
| **Solo**     | <!-- TODO(HER-31): CPX11 / CX22 confirmation --> | 2 / 4 GB / 40 GB SSD  | 1–5              | hermes-3-small        | <!-- TODO(HER-31) -->            |
| **Team**     | <!-- TODO(HER-31): CPX21 / CX32 confirmation --> | 3 / 8 GB / 80 GB SSD  | 5–50             | hermes-3              | <!-- TODO(HER-31) -->            |
| **Org**      | <!-- TODO(HER-31): CPX31 or CCX13 confirmation --> | 4 / 16 GB / 160 GB SSD | 50–250          | hermes-3 + pgvector hot index | <!-- TODO(HER-31) --> |

Notes on choosing:

- <!-- TODO(HER-31): explain CX (shared vCPU, ARM/x86) vs CPX (dedicated burst)
  vs CCX (dedicated vCPU) tradeoffs — when each is the right pick for the
  Hummingbird + Hermes + Postgres compose stack. -->
- <!-- TODO(HER-31): RAM sizing rule of thumb — Postgres `shared_buffers`,
  Hermes model weight residency, and Hummingbird NIO thread pool footprint. -->

---

## 2. Provisioning

### 2.1 hcloud CLI (recommended)

```bash
# TODO(HER-31): replace placeholders with verified working invocation.
hcloud server create \
  --name lv-prod \
  --type cpx21 \
  --image ubuntu-24.04 \
  --location <fsn1|nbg1|hel1> \
  --ssh-key <your-key-id> \
  --network <private-net-id> \
  --user-data-from-file cloud-init.yaml
```

### 2.2 cloud-init recipe

<!-- TODO(HER-31): commit a `infra/hetzner/cloud-init.yaml` that installs
docker, docker-compose-plugin, ufw, fail2ban, the unattended-upgrades
package, and drops a non-root deploy user. Link to it here. -->

### 2.3 Web Console (fallback)

<!-- TODO(HER-31): 6-step screenshot walk for users who don't want hcloud. -->

---

## 3. Networking

| Concern        | Recommendation                                  | Notes |
|----------------|-------------------------------------------------|-------|
| Public IPv4    | 1 per server                                    | <!-- TODO(HER-31): cost €0.50/mo at time of writing — verify --> |
| IPv6           | enable (free)                                   | Hetzner gives a /64 — Hummingbird supports IPv6 out of the box. |
| Private network| 1 vSwitch per env (prod, staging)               | <!-- TODO(HER-31): explain why — Hermes ↔ Hummingbird ↔ Postgres should never traverse public NAT. --> |
| Firewall       | Hetzner Cloud Firewall (free) + host `ufw`      | <!-- TODO(HER-31): list ingress rules — 22 (locked to your IPs), 80, 443. Internal-only: 5432, 8642, 4317. --> |
| DDoS           | included, no opt-in                             | |
| Floating IPs   | optional, used during blue/green                | <!-- TODO(HER-31): document the rebind procedure for zero-downtime swaps. --> |

---

## 4. Storage

<!-- TODO(HER-31): document the four storage classes Hetzner offers and which
LuminaVaultServer path belongs on each:
  - local NVMe → docker volumes, hot Postgres, Hermes models
  - Hetzner Volumes (block storage) → cold backups, vault file storage at scale
  - Hetzner Storage Box (SMB/NFS over WAN) → off-host backups, never hot data
  - S3-compatible Hetzner Object Storage → audit log archives, large media
Include the mount commands and where each shows up in the docker-compose file. -->

### 4.1 Filesystem layout on the host

```text
/srv/luminavault/
├── data/
│   ├── postgres18/       # PG cluster (NVMe)
│   ├── hermes/           # Hermes profile dirs (NVMe)
│   └── luminavault/      # vault/<tenantID>/{raw,wiki,outputs} (NVMe; rotate to volume when >50GB)
├── secrets/              # mounted read-only into hummingbird container
├── backups/              # rsynced to Storage Box nightly
└── compose.yaml
```

<!-- TODO(HER-31): explain why this is NOT under /home — systemd unit
expectations, SELinux/AppArmor profile expectations, and `df -h` clarity. -->

---

## 5. Reverse proxy + TLS

<!-- TODO(HER-31): pick ONE recommended option and write it end-to-end.
Caddy is the suggested default because automatic ACME + the smallest
caddyfile that survives next 12 months. Provide:
  - Full `Caddyfile` snippet
  - `docker-compose.override.yaml` that adds the caddy service
  - DNS A/AAAA record setup (cloudflare or Hetzner DNS console)
  - Verification — `curl -I https://<domain>/healthz` --> 200
Reference: integration.md §6 says HTTPS is out of scope there — this is
where we close that gap. -->

---

## 6. Backups

| Asset             | Frequency | Destination                          | Restore RTO |
|-------------------|-----------|--------------------------------------|-------------|
| Postgres          | hourly WAL + nightly base | Storage Box (encrypted at rest) | <!-- TODO(HER-31) --> |
| Hermes profiles   | nightly tarball | Storage Box                       | <!-- TODO(HER-31) --> |
| `data/luminavault/<tenant>/raw` | nightly | Storage Box | <!-- TODO(HER-31) --> |
| Secrets           | manual on rotate | password manager + sealed-secret git | n/a |

<!-- TODO(HER-31): commit a `scripts/backup.sh` that pgBackRest-or-equivalent
to the Storage Box. Cron it via `setup.sh` so a fresh box has it from day one. -->

---

## 7. Observability

<!-- TODO(HER-31): describe wiring lv's existing OTel exporter (see
`OTEL_EXPORTER_OTLP_ENDPOINT`) to either:
  a) self-hosted Jaeger on the same box (default, only the demo)
  b) Hetzner-hosted Grafana Cloud free tier
  c) the user's own SigNoz/Tempo install
Include where to inspect `lv.usage.*` metrics, `hermes.reconciler.service`
log lines, and `LapseArchiver` runs. -->

---

## 8. Cost model

Worked example for the **Team** tier. Numbers are placeholders until §1 lands.

| Line item                     | Cost / month |
|-------------------------------|--------------|
| CPX21 server                  | <!-- TODO(HER-31): € --> |
| IPv4 address                  | <!-- TODO(HER-31): € --> |
| 50 GB block volume (cold)     | <!-- TODO(HER-31): € --> |
| 1 TB Storage Box (backups)    | <!-- TODO(HER-31): € --> |
| Bandwidth (20 TB included)    | 0            |
| **Total**                     | **<!-- TODO(HER-31): € -->** |

<!-- TODO(HER-31): three-year TCO comparison vs DigitalOcean Droplet, AWS
Lightsail, and Render — same workload envelope. -->

---

## 9. Alternatives matrix

<!-- TODO(HER-31): one-table comparison: Hetzner vs DigitalOcean vs Vultr vs
AWS Lightsail vs Render. Columns: starting €, RAM/€, included egress, GDPR
data-residency story, time-to-first-deploy. Conclude with the rule the
team is committing to (e.g. "Hetzner unless residency requirement excludes
Germany, in which case Vultr Amsterdam"). -->

---

## 10. Day-2 operations

<!-- TODO(HER-31): cookbook for the operations that happen weekly:
  - `swift run App migrate` on a new release
  - `swift run App backfill-hermes-profiles` (HER-29 CLI) after Hermes incident
  - `swift run App bootstrap-admin` (already in startup.md — link, don't dup)
  - Rolling Postgres upgrade (pg18 → pg19 when it lands)
  - Rotating JWT_HMAC_SECRET without invalidating in-flight sessions -->

---

## 11. Common gotchas

<!-- TODO(HER-31): one item per pitfall the team has actually hit, including:
  - "Hetzner cloud-init reboots once, breaking long compose builds — use
     `cloud-init status --wait` before running `docker compose up`."
  - "`UFW_DEFAULT_FORWARD=DROP` blocks the docker bridge — explicit ACCEPT
     rule required."
  - "Postgres `shared_buffers` defaulted from packaging exceeds the CX11
     baseline RAM budget — tune in `postgresql.conf` before first start."
Reserve the rest for issues that surface during the first 30 days of prod. -->

---

## Cross-references

- Generic VPS runbook: [`integration.md`](./integration.md)
- Local dev + onboarding: [`startup.md`](./startup.md)
- Background jobs (LapseArchiver, HermesProfileReconciler, etc.): [`jobs.md`](./jobs.md)
- Skill / LLM model envelopes: [`llm-models.md`](./llm-models.md)
