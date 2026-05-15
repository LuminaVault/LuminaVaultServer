# Hetzner Deployment (HER-31) — Optimized Docs

Hetzner Cloud is the recommended primary host for self-hosted and small-team
LuminaVaultServer deployments. This document is **Hetzner-specific** and
assumes the generic Ubuntu/VPS instructions in [`integration.md`](./integration.md)
have already been read.

> **Prices in this doc are EUR (excl. VAT) and reflect the published rates
> on [hetzner.com/cloud](https://www.hetzner.com/cloud) as of May 2026.
> Re-check the live price calculator before quoting commercially. Limits
> and SKU specs are pulled from the Hetzner documentation.**

---

## 0. Why Hetzner

For the LuminaVaultServer workload — single-tenant Hummingbird + Postgres +
Hermes — Hetzner Cloud wins on four axes that matter for a self-hosted vault:

1. **Predictable cost.** No per-request egress surcharge. Every server tier
   ships with 20 TB/mo inclusive traffic (sufficient for ~1 M hot-path API
   calls/day with audio/voice attachments). Compare DO/Vultr at 1–5 TB and
   AWS at metered egress.
2. **EU data residency.** Three German DCs (`fsn1`, `nbg1`) and `hel1`
   (Finland) keep tenant data inside the EU/EEA for GDPR-compliant deploys.
3. **RAM density.** The cheapest tier that fits the dev stack (CPX21, 4 GB
   RAM) lands at €7.55/mo — roughly half the equivalent DO Droplet.
4. **No CapEx ceremony.** `hcloud` CLI provisions a usable host in ~30 s;
   block storage volumes are `attach`-on-the-fly; cloud-init is supported
   without licence gymnastics.

Constraints: no managed Postgres (we ship our own in compose), no managed
Kubernetes for small fleets (use k3s/swarm if needed), no SLA above 99.9 %.
Trade-offs accepted for the indie/small-team profile.

---

## 1. Sizing matrix

Three reference profiles, by tenant count. **Solo** runs everything on the
same box; **Team** keeps the same single-box topology but with headroom;
**Org** splits Postgres onto a dedicated CCX box and keeps Hummingbird +
Hermes on a separate CPX. Revisit after the first month of `lv.usage.*`
metrics from `docs/jobs.md`.

| Tier      | Hetzner SKU      | vCPU class                | RAM   | NVMe   | Inclusive traffic | Concurrent users | Hermes envelope                          | €/mo |
|-----------|------------------|---------------------------|-------|--------|-------------------|------------------|------------------------------------------|------|
| **Solo**  | `cpx11`          | 2 × AMD EPYC (shared)     | 2 GB  | 40 GB  | 20 TB             | 1–5              | `hermes-3-small`                          | 4.15 |
| **Team**  | `cpx21`          | 3 × AMD EPYC (shared)     | 4 GB  | 80 GB  | 20 TB             | 5–50             | `hermes-3` (default model)                | 7.55 |
| **Org**   | `cpx31` + `ccx13` | 4 × AMD shared (app) + 2 × AMD dedicated (db) | 8 GB + 8 GB | 160 GB + 80 GB | 20 TB + 20 TB | 50–250 | `hermes-3` + pgvector hot index (≥4 GB shared_buffers) | 13.10 + 13.49 |

### 1.1 CX vs CPX vs CCX

- **CX** — shared Intel (or ARM `CAX*` in select DCs). Cheapest tier per GB
  of RAM. Variable single-thread perf because hypervisor schedules over a
  fat host. Pick for Solo where p99 latency is not yet a customer-visible
  metric.
- **CPX** — shared AMD EPYC with higher base clocks. Better burst headroom
  than CX. Default recommendation. The LuminaVault server's Swift NIO
  threadpool sees a clear ~25 % latency improvement on CPX21 over CX22 in
  the chat-completion path (anecdotal — measure on your tenant load).
- **CCX** — dedicated vCPUs. Required when you need sustained Postgres CPU
  (large pgvector indexes, heavy memory-pruning) or strict p99 guarantees.
  Approximately 2–3× the cost per vCPU vs CPX. Pin Postgres here on Org.

### 1.2 RAM sizing rule of thumb

```
RAM ≥
   1.0 GB Hummingbird (NIO threadpool, default JVM-equivalent footprint)
 + 0.7 GB per Hermes loaded model (hermes-3-small ≈ 0.5 GB; hermes-3 ≈ 2.5 GB)
 + 0.25 × <Postgres data-set size on disk> (rule for shared_buffers + cache)
 + 0.5 GB OS + container runtime overhead
```

Concretely, a Team tenant with 5 GB of vault content and `hermes-3` loaded
wants ≥ 4 GB RAM — the CPX21 box. If you load `hermes-3-medium` (4.0 GB),
jump to CPX31 (8 GB). Don't try to run `hermes-3-medium` on a CX22 — the
OOM killer will pick it as `oom_score=high` and your chat endpoint dies
silently.

---

## 2. Provisioning

### 2.1 `hcloud` CLI (recommended)

```bash
# One-shot Team-tier provision in Falkenstein with a 50 GB cold-storage volume
# already attached, sitting in a private network, with cloud-init pre-baked.
hcloud server create \
  --name lv-prod \
  --type cpx21 \
  --image ubuntu-24.04 \
  --location fsn1 \
  --ssh-key "$(hcloud ssh-key list -o columns=id -o noheader | head -1)" \
  --network <private-net-id> \
  --volume <cold-volume-id> \
  --user-data-from-file infra/hetzner/cloud-init.yaml \
  --enable-protection delete,rebuild
```

Notes:

- `--enable-protection delete,rebuild` blocks accidental console deletion.
- `--label env=prod,role=lv-server` is recommended once you run more than
  one server; firewalls can attach by label selector (see §3).
- `--placement-group <id>` is worth using once you split db/app — pins them
  on different physical hosts in the same DC.

### 2.2 cloud-init recipe

```yaml
# infra/hetzner/cloud-init.yaml — minimum viable LV host.
# TODO(HER-31): commit this file to the repo. The body below is the exact
# contents intended once the file lands; users can paste it inline until then.
#cloud-config
package_update: true
package_upgrade: true
packages:
  - ca-certificates
  - curl
  - gnupg
  - ufw
  - fail2ban
  - unattended-upgrades
  - docker.io
  - docker-compose-plugin
users:
  - name: deploy
    groups: [docker, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - <your SSH public key>
write_files:
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
runcmd:
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow OpenSSH
  - ufw allow 80/tcp
  - ufw allow 443/tcp
  - ufw --force enable
  - systemctl enable --now docker
  - mkdir -p /srv/luminavault && chown -R deploy:deploy /srv/luminavault
final_message: "LV host ready. Clone repo into /srv/luminavault and run setup.sh."
```

### 2.3 Web Console (fallback)

If `hcloud` is not an option, the Hetzner Console at
[console.hetzner.com](https://console.hetzner.com) walks the same path
through a web UI. The order is identical: Project → Servers → "Add Server"
→ pick location + type + image + cloud-init user-data → set SSH key →
Create. The Console exposes labels, firewalls, and volumes under the same
project namespace. Console users still need the cloud-init YAML above
pasted into the user-data field.

---

## 3. Networking

| Concern             | Recommendation                                              | Notes |
|---------------------|-------------------------------------------------------------|-------|
| Public IPv4         | 1 per server                                                | €0.50/mo (excl. VAT). Required for inbound HTTPS unless you front everything via a Load Balancer. |
| IPv6                | enable (free)                                               | Hummingbird supports IPv6 natively. Add an `AAAA` record alongside the `A` record. |
| Private network     | 1 per environment (prod, staging)                           | `10.0.0.0/16` is a reasonable default; subnet per role (`10.0.10.0/24` app, `10.0.20.0/24` db). Postgres ↔ Hummingbird ↔ Hermes must traverse the private interface — public NAT round-trips add 5–8 ms p50. |
| Cloud Firewall      | 1 per role, attached by label selector                      | Free service. Up to 5 firewalls/server, 500 rules/firewall, 80 000 concurrent connections, 10 000 new/s. |
| Host firewall       | `ufw` enabled by cloud-init (§2.2)                          | Defense-in-depth — Cloud Firewall handles ingress; `ufw` is the second wall when a misconfigured Cloud Firewall is the only thing between you and the internet. |
| DDoS                | included, no opt-in                                         | Hetzner mitigates volumetric attacks at the edge for all customers. |
| Floating IPs        | optional, used during blue/green deploys                    | Up to 20/server. Detach + attach atomically across servers; takes ~5 s. |

### 3.1 Cloud Firewall ruleset for `lv-server`

```text
# Inbound (all "drop" by default; explicit allows below)
22/tcp   from   <your-bastion-or-home-IP/32>     # SSH (lock down — never 0.0.0.0/0)
80/tcp   from   0.0.0.0/0, ::/0                  # HTTP — redirects to 443 via reverse proxy
443/tcp  from   0.0.0.0/0, ::/0                  # HTTPS (Hummingbird via Caddy)
51820/udp from  0.0.0.0/0, ::/0                  # Optional: WireGuard for admin tunnel

# Outbound — Cloud Firewall does NOT filter outbound. Use host `ufw` if you
# need egress restrictions (rare for an indie/team box).
```

Internal-only ports (`5432` Postgres, `8642` Hermes, `4317` OTLP) are
reachable **only** on the private network; they are never bound on the
public interface in the shipped `compose.yaml`.

### 3.2 DNS

Use Hetzner DNS Console (free, anycast) or your existing provider (Cloudflare,
Route53). Record set for a single-host install:

```text
A      lv.example.com.    <public-IPv4>     300
AAAA   lv.example.com.    <public-IPv6>     300
CAA    lv.example.com.    0 issue "letsencrypt.org"   3600
```

The `CAA` record is recommended once Caddy is issuing certificates — it
blocks any other CA from minting a cert for your domain even if a
registrar account is compromised.

---

## 4. Storage

Four classes; pick by access pattern, not by size:

| Class                    | Latency    | Cost (May 2026) | Use for                                                              |
|--------------------------|------------|-----------------|----------------------------------------------------------------------|
| Local NVMe (included)    | ~80 µs     | included        | Postgres `pgdata`, Hermes model weights, hot vault `raw/` content    |
| Cloud Volume (block)     | ~250 µs    | €0.044/GB/mo    | Cold backups, `data/luminavault/<tenant>/cold-storage` (HER-184 lapse archiver) |
| Storage Box (SMB/SFTP)   | WAN latency | €3.81/mo (1 TB BX11) → €20.30/mo (10 TB BX31) | Off-host backups, audit logs, anything mounted via SFTP at most weekly |
| Object Storage (S3)      | ~10 ms     | €5.99/TB-mo + €1/TB egress | Audit log archives (5+ years), large user-uploaded media, snapshots distributed across teams |

Capacity guidance: start with 100 % NVMe (the included server disk).
Promote a directory to a Cloud Volume the day Postgres or vault content
crosses 70 % of the NVMe disk. Send weekly snapshots to a Storage Box.
Move > 90-day audit logs to Object Storage only if you have a regulatory
reason to keep them online.

### 4.1 Filesystem layout on the host

```text
/srv/luminavault/
├── data/
│   ├── postgres18/       # PG cluster — NVMe only
│   ├── hermes/           # Hermes profile dirs — NVMe only
│   └── luminavault/      # per-tenant vaults (raw, wiki, outputs) — NVMe until cold-storage promotion
├── cold-storage/         # → mount of /dev/sdb (Cloud Volume) when present
├── backups/              # rsync target → Storage Box nightly via /etc/cron.daily/lv-backup
├── secrets/              # JWT_HMAC_SECRET, APNs key, RevenueCat secret — read-only mount into containers
└── compose.yaml
```

Why under `/srv` and not `/home`:

- `/home` is conventionally for user data and may be on a separate filesystem
  on hardened images — moving it requires re-mounting under load.
- `/srv` is the Linux FHS-blessed location for "site-specific service data";
  AppArmor/SELinux default profiles allow service writes here without policy
  edits.
- `df -h /srv` gives an at-a-glance answer for "is the box about to fill
  up?" which is hard when vault content is sprinkled under `/home/deploy/`.

### 4.2 Promoting a directory to a Cloud Volume

```bash
# Create + attach a 50 GB volume to the running server.
hcloud volume create --name lv-cold --size 50 --location fsn1 --automount no \
  --server lv-prod
sudo mkfs.ext4 -L lv-cold /dev/disk/by-id/scsi-0HC_Volume_<id>
sudo mkdir -p /srv/luminavault/cold-storage
sudo blkid -o export /dev/disk/by-id/scsi-0HC_Volume_<id> \
  | sed 's|^|/srv/luminavault/cold-storage ext4 defaults,nofail 0 2|' \
  >> /etc/fstab  # adjust as needed; verify before mounting
sudo mount /srv/luminavault/cold-storage
```

Set `billing.coldStoragePath=/srv/luminavault/cold-storage` in `.env` so
the LapseArchiver writes there. See `docs/jobs.md` §LapseArchiver.

---

## 5. Reverse proxy + TLS

Caddy is the recommended default — automatic ACME, the smallest Caddyfile
that survives the next 12 months, and zero config churn when you renew or
rotate certs.

### 5.1 Caddyfile

```caddy
# /srv/luminavault/Caddyfile
{
    email ops@example.com
    # storage redis on the same compose net later if you go multi-node;
    # default file storage is fine for single-host.
}

lv.example.com {
    encode zstd gzip
    @websockets {
        header Connection *Upgrade*
        header Upgrade websocket
    }
    handle @websockets {
        reverse_proxy hummingbird:8080
    }
    handle {
        reverse_proxy hummingbird:8080 {
            health_path /healthz
            health_interval 10s
            health_timeout 3s
        }
    }
    log {
        output file /var/log/caddy/lv.log {
            roll_size 50mb
            roll_keep 14
        }
        format json
    }
}
```

### 5.2 docker-compose.override.yaml

```yaml
# /srv/luminavault/docker-compose.override.yaml
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
      - /var/log/caddy:/var/log/caddy
    networks:
      - default
    depends_on:
      - hummingbird

volumes:
  caddy-data:
  caddy-config:
```

### 5.3 Verification

```bash
# DNS resolves
dig +short lv.example.com
dig +short AAAA lv.example.com

# Caddy minted a cert (look for the ACME log line)
docker compose logs caddy | grep "certificate obtained successfully"

# Health endpoint over HTTPS
curl -I https://lv.example.com/healthz   # expect: HTTP/2 200
```

If `/healthz` returns 200, the chain is wired correctly. If you see a
self-signed warning, Caddy is still using its internal CA — DNS or ACME
hasn't completed yet; wait 60 s and retry.

---

## 6. Backups

| Asset                                      | Frequency      | Destination                              | Restore RTO |
|--------------------------------------------|----------------|------------------------------------------|-------------|
| Postgres                                   | hourly WAL + nightly base | Storage Box (encrypted at rest)   | ~10 min     |
| Hermes profiles (`data/hermes/`)           | nightly tarball | Storage Box                             | ~5 min      |
| Vault `raw/` per tenant (`data/luminavault/<tenant>/raw`) | nightly | Storage Box                  | ~5 min      |
| Audit log archives                         | weekly         | Object Storage (lifecycle rule to Glacier-equivalent at 90 d) | ~hours      |
| Secrets                                    | manual on rotate | password manager + sealed-secret git    | n/a         |

### 6.1 Nightly backup script (sketch)

```bash
#!/usr/bin/env bash
# /etc/cron.daily/lv-backup — runs at 02:30 UTC under root.
# TODO(HER-31): commit a fully-tested version at scripts/lv-backup.sh.
set -euo pipefail
TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="ssh://u<storage-box-user>@<storage-box-user>.your-storagebox.de:23/backups"

# 1. PG base dump
docker compose exec -T postgres pg_dump -U luminavault luminavault \
  | zstd -19 -T0 > /srv/luminavault/backups/pg-${TS}.sql.zst

# 2. Hermes + vault (rsync, dedup-aware destination)
rsync -aHAX --delete /srv/luminavault/data/hermes/   ${DEST}/hermes/
rsync -aHAX --delete /srv/luminavault/data/luminavault/  ${DEST}/vault/

# 3. Ship PG dump
rsync -av /srv/luminavault/backups/pg-${TS}.sql.zst  ${DEST}/postgres/

# 4. Local retention (Storage Box keeps the long tail)
find /srv/luminavault/backups -name "pg-*.sql.zst" -mtime +7 -delete
```

Set up Storage Box SSH key + `~/.ssh/known_hosts` once with a manual
`ssh u<id>@<id>.your-storagebox.de -p 23` to accept the host key before
the cron's first run.

### 6.2 Restore drill

Run a restore drill on a second box once a quarter:

1. `hcloud server create` a fresh CPX21 with the same cloud-init.
2. `rsync` the latest Storage Box snapshot back to `/srv/luminavault/`.
3. `docker compose up -d postgres` → `psql -f pg-*.sql` into a fresh DB.
4. `swift run App migrate` → confirm migrations are at head.
5. `swift run App` and verify `GET /v1/me` works with a saved token.

If the drill takes longer than 30 min, refactor the script — your real
incident response cannot afford to discover problems in the script under
stress.

---

## 7. Observability

LuminaVaultServer exports OpenTelemetry traces and Prometheus metrics out
of the box. Three terminations:

1. **Self-hosted Jaeger (default).** The shipped `compose.yaml` includes
   a `jaeger` service on `:16686` (UI) and `:4317` (OTLP gRPC). Set
   `OTEL_ENABLED=true` and `OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger:4317`.
   Good for single-box self-hosters; in-memory ring buffer, no retention.
2. **Grafana Cloud Free tier.** Point the OTLP exporter at
   `OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp-gateway-prod-eu-west-2.grafana.net/otlp`
   with a Grafana Cloud API token in `OTEL_EXPORTER_OTLP_HEADERS=authorization=Basic%20<base64>`.
   50 GB logs / 50 GB metrics / 50 GB traces free, no credit card.
3. **Self-hosted SigNoz / Tempo.** Drop on a CCX13; same OTLP gRPC endpoint
   contract. Worth the extra €13.49/mo at Org tier.

Specific signals to watch:

| Signal                                        | Where                                  | Action |
|-----------------------------------------------|----------------------------------------|--------|
| `lv.usage.*`                                  | Prometheus / Grafana metric            | Capacity planning — driver for stepping up to the next SKU tier in §1. |
| `hermes.reconciler.service ran` log line      | Caddy/Docker log aggregator            | Daily smoke at 04:00 UTC. Missing for 24h → investigate. |
| `billing.lapse_archiver.service ran` line     | same                                   | Daily smoke at 03:00 UTC. |
| `http.server.duration_seconds{route="/v1/llm/chat",quantile="0.99"}` | Prometheus | Should stay < 4 s. Above → check Hermes box; CPX22 unlikely to keep up at sustained 50 req/s. |
| Postgres connection pool exhaustion (`pool wait` log) | Hummingbird logger              | Bump `postgres.maxConnections` or move Postgres to a CCX. |

---

## 8. Cost model

Worked example for the **Team** tier (≤ 50 concurrent users).

| Line item                              | EUR / month (excl. VAT) |
|----------------------------------------|--------------------------|
| CPX21 server (`lv-prod` in fsn1)       | 7.55                     |
| Primary IPv4                           | 0.50                     |
| Primary IPv6                           | 0.00                     |
| 50 GB Cloud Volume (cold storage)      | 2.20                     |
| BX11 Storage Box (1 TB backups)        | 3.81                     |
| Inclusive 20 TB egress                 | 0.00                     |
| **Total**                              | **14.06**                |

### 8.1 Three-year TCO comparison (Team workload)

| Provider                       | Equivalent SKU                  | €/mo (May 2026) | 36-month TCO | Notes |
|--------------------------------|---------------------------------|------------------|--------------|-------|
| **Hetzner**                    | CPX21 + BX11 + 50 GB Volume     | 14.06            | **506**      | Reference. |
| DigitalOcean                   | Premium AMD 4 GB + 50 GB Volume + 1 TB Spaces | 38       | 1 368        | 2.7× Hetzner; egress past 4 TB metered. |
| AWS Lightsail                  | 2 GB / 60 GB SSD + 50 GB volume + 1 TB S3 + IPv4 | 35  | 1 260        | 2.5× Hetzner; CPU credits throttle long requests. |
| Render                         | Standard (2 GB/2 vCPU) + PG starter + 50 GB disk | 52  | 1 872        | 3.7× Hetzner; no SSH access. |
| AWS EC2 t4g.medium (on-demand) | + RDS t4g.small + 50 GB EBS + 1 TB S3 + IPv4 | ~76  | 2 736        | 5.4× Hetzner; cheapest if you reserve 3-year. |

Even in the best case for AWS (3-year reserved + savings plan), Hetzner
remains 1.8–2.5× cheaper at this workload envelope. The trade-off is
operational maturity: no managed PG failover, no auto-scaling, no
multi-region failover.

---

## 9. Alternatives matrix

| Criterion                      | Hetzner                | DigitalOcean        | Vultr               | AWS Lightsail       | Render             |
|--------------------------------|------------------------|---------------------|---------------------|---------------------|--------------------|
| Starting tier (€/mo)           | 4.15 (CPX11, 2 GB)     | 5.30 (Basic, 1 GB)  | 5.60 (Cloud Compute, 1 GB) | 4.20 (Nano, 0.5 GB) | 6.20 (Starter)    |
| RAM per €                      | **~0.55 GB/€**         | 0.19 GB/€           | 0.18 GB/€           | 0.12 GB/€           | 0.08 GB/€          |
| Inclusive egress               | **20 TB**              | 1 TB                | 1 TB                | 2 TB                | 100 GB (Starter)   |
| EU data residency              | ✓ (fsn1, nbg1, hel1)   | ✓ (ams3, fra1)      | ✓ (Amsterdam, Frankfurt) | ✓ (eu-west)   | ✓ (Frankfurt)      |
| Time to first deploy           | ~3 min (hcloud)        | ~5 min              | ~5 min              | ~7 min              | ~10 min            |
| Managed Postgres               | ✗ (self-host)          | ✓ (€15+)            | ✓                   | ✓ (RDS via AWS)     | ✓ (PG starter)     |
| GDPR data-residency story      | strong (DE/FI)         | strong              | strong              | strong              | strong             |

**Decision rule:** Hetzner is the default. Switch to **Vultr Amsterdam**
only when a client contract requires "no Hetzner" (rare, but happens).
Switch to **Render** if the team has zero ops capacity and is willing to
pay the 3–4× premium for managed PG + zero-config deploys.

---

## 10. Day-2 operations

| Operation                                                | Command                                                                | Frequency |
|----------------------------------------------------------|------------------------------------------------------------------------|-----------|
| Run pending migrations on deploy                         | `swift run App migrate`                                                | every release |
| Heal Hermes profile rows after Hermes incident           | `swift run App backfill-hermes-profiles` (HER-29 CLI)                  | post-incident |
| Bootstrap admin user (first install only)                | `swift run App bootstrap-admin` — see `docs/startup.md`                | once per env |
| Rotate JWT secret without ejecting active sessions       | dual-key window: add `JWT_HMAC_SECRET_NEXT`, restart, flip after refresh-token TTL window (30 d) | yearly |
| PG major version upgrade (e.g. pg18 → pg19)              | restore drill (§6.2) into the new image, switch traffic on the next deploy | once per LTS |
| Floating-IP blue/green swap                              | `hcloud floating-ip assign <id> <new-server>`                          | every release |

Reference `docs/jobs.md` for the schedule of in-process scheduled services
(LapseArchiver, HermesProfileReconciler, MemoryPruning) — these run inside
the Hummingbird process and need no host-cron entry.

---

## 11. Common gotchas

- **cloud-init reboots once.** A long `apt-get upgrade` from the cloud-init
  package list can race against your first `docker compose up`. Always
  wait for `cloud-init status --wait` to print `done` before running
  setup.sh.
- **UFW + Docker bridge collision.** Default Ubuntu `UFW_DEFAULT_FORWARD=DROP`
  blocks the docker0 bridge — every container loses outbound DNS. Either
  set `DEFAULT_FORWARD_POLICY="ACCEPT"` in `/etc/default/ufw` or add an
  explicit `ufw route allow in on docker0` rule.
- **Postgres `shared_buffers` default exceeds CX11 RAM.** Default
  `pgvector/pgvector:pg18` image picks `shared_buffers=128MB` which is
  fine, but turning it up to "25 % of RAM" without checking the SKU has
  killed a CX11 box. Use `cgmem` / docker `mem_limit` to defend.
- **Snapshots are NOT backups.** Hetzner snapshots run on the same DC as
  the server. A DC-level event takes both — always also send to Storage
  Box, which sits on a different host/network.
- **Cloud Volume on /etc/fstab without `nofail`.** A detached volume on
  reboot becomes an unbootable host. Always mount with `nofail` so the
  server boots even if the volume is missing.
- **Hermes model download eats your /var/lib/docker on first boot.** The
  `hermes-3` weight pull is ~5 GB; the default Docker `/var/lib/docker`
  partition on Ubuntu's cloud image is the root NVMe. Pre-pull during
  cloud-init or symlink `/var/lib/docker` to `/srv/luminavault/docker`.

---

## 12. Cross-references

- Generic VPS runbook: [`integration.md`](./integration.md)
- Local dev + onboarding: [`startup.md`](./startup.md)
- Background jobs (LapseArchiver, HermesProfileReconciler, MemoryPruning): [`jobs.md`](./jobs.md)
- Skill / LLM model envelopes: [`llm-models.md`](./llm-models.md)
- Vault export format (used by backup script): [`vault-export.md`](./vault-export.md)
