# Multimodal ingestion load harness

This harness uploads one batch per worker with a bounded 8 MiB memory footprint per request. Point `-base-url` at the production-like load balancer so requests exercise every server and worker replica.

```bash
truncate -s 3G /tmp/lv-ingestion-load.bin
go run . \
  -base-url https://staging-api.example.com \
  -token "$LV_LOAD_TEST_TOKEN" \
  -file /tmp/lv-ingestion-load.bin \
  -workers 8
```

Use a dedicated tenant and delete its generated vault data afterward. Observe `luminavault.ingestion.*` metrics, pod memory, Postgres locks, queue latency, and terminal failure rates during the run. The source is read through `io.SectionReader`; the harness never loads the full file into memory.
