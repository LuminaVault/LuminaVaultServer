# Multimodal ingestion load test

Use the disk-streaming harness against staging to validate multi-GiB batches,
concurrent uploads, and distributed worker claiming. It never loads an entire
source file into memory; it reads and uploads one 8 MiB chunk at a time.

## Prerequisites

- Scale the staging API deployment to at least two replicas and confirm both are ready.
- Use non-sensitive staging fixtures. Each file must be at most 2 GiB and the
  comma-separated set must total at most 5 GiB.
- Install `curl`, `jq`, `file`, `shasum`, and standard `dd`/`stat` utilities.
- Obtain a short-lived staging access token.

## Run

```bash
API_BASE_URL=https://api-staging.luminavault.fyi \
AUTH_TOKEN='<staging access token>' \
LOAD_FILES='/fixtures/large-video.mp4,/fixtures/archive.pdf,/fixtures/audio.m4a' \
BATCHES=4 \
./scripts/load-multimodal-ingestion.sh
```

`BATCHES` controls concurrent batches. The harness verifies upload completion,
then polls every batch until `completed` or `attention`; the default timeout is
30 minutes.

## Pass criteria

- No upload returns 5xx, checksum mismatch, or incomplete-upload errors.
- Every batch reaches a terminal state before the timeout.
- Database inspection shows no item claimed by more than one worker and no
  expired leases after the run.
- Grafana receives `luminavault.ingestion.claimed`, `completed`, `failed`,
  `retried`, `deduplicated`, `apns.failures`, and `queue_latency` metrics.
- Compare pod logs to confirm at least two replicas claim work. Queue latency
  should drain after uploads stop and memory must stay bounded per pod.

An `attention` batch is a harness pass only when its item errors are expected
fixture/capability failures. Unexpected terminal failures remain a product test
failure and must be investigated before promotion.
