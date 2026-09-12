# Voice metering — what is recorded, and how to read it

Every transcription attempt through `/v1/transcribe` or
`/v1/audio/transcriptions` leaves three traces. They answer different
questions and none substitutes for another.

| Where | Grain | Answers |
|---|---|---|
| `usage_meter` | per tenant/day/model | "how much has this tenant burned" — feeds tier caps |
| `usage_events` | per request | "what happened, from where, how long, at what cost" |
| OTel metrics | sampled series | "is voice healthy right now" — dashboards and alerts |

## The per-request row

One `usage_events` row per attempt, **including failures**. Metering only
successes makes a failing provider look like a drop in demand: the chart goes
quiet exactly when something is wrong.

- `metric` — `voice_transcribe`
- `amount` — audio duration in **milliseconds** (0 on failure)
- `source` — the channel, denormalised so the common `GROUP BY` needs no JSON
- `idempotency_key` — the response id, so a retried write cannot double-count
- `metadata` — JSONB:

```jsonc
{
  "channel": "telegram",          // platform it arrived on
  "surface": "voice_note",
  "provider": "openai_compatible",
  "model": "Systran/faster-whisper-small",
  "outcome": "ok",                // ok | upstream_permanent | upstream_transient | network | decode | no_provider
  "latencyMs": 431,
  "audioBytes": 18244,
  "language": "en",
  "usdMicros": 0,                 // real spend — 0 for the in-cluster service
  "imputedUsdMicros": 6000        // what a hosted provider would have charged
}
```

### Where `channel` comes from

Hermes sets `X-Lumina-Channel` on its OpenAI audio client (see
`tools/transcription_tools.py:_audio_attribution_headers`). Without it the
server can only see the tenant — a Telegram voice note and an iOS mic
recording arrive identical over the OpenAI wire shape.

It is **advisory**. An absent, unknown, or hostile value is recorded as
`unknown` and never rejects the request; a user's voice note must not fail
because attribution failed. Values are reduced to a bare `[a-z0-9_-]` token,
truncated at the first character outside that set, on both ends of the wire.
`/v1/transcribe` defaults to `app`, since that route is the iOS microphone.

## Real cost vs imputed cost

The cluster's whisper is free per request, so `usdMicros` is genuinely `0` and
nothing is written to `cost_ledger` — there is no spend to reconcile.

`imputedUsdMicros` is the other question: what this traffic *would* have cost
hosted. Off by default, because a rate nobody configured is a number nobody
should act on. Turn it on per provider:

```
TRANSCRIBE_RATECARD_OPENAI_IMPUTED_USD_PER_AUDIO_MINUTE=0.006   # OpenAI whisper-1
```

Note the spelling. `ConfigReader` splits `transcribe.ratecard.openai.imputedUsdPerAudioMinute`
on `.`, inserts `_` at every camelCase boundary, and uppercases — see the
naming warning in [CONFIG.md](CONFIG.md). The flattened form
(`..._IMPUTEDUSDPERAUDIOMINUTE`) reads nothing, silently, and the imputed
figure would stay `0` with no error to notice.

It never reaches `cost_ledger`. It is not money anyone owes — it is what makes
"running our own whisper saves $X" a measurement instead of an assertion.

## Queries

Voice minutes and imputed spend by channel, last 30 days:

```sql
SELECT metadata->>'channel'                                   AS channel,
       COUNT(*)                                               AS calls,
       ROUND(SUM(amount) / 60000.0, 1)                        AS audio_minutes,
       ROUND(SUM((metadata->>'imputedUsdMicros')::bigint) / 1e6, 2) AS imputed_usd,
       ROUND(SUM((metadata->>'usdMicros')::bigint) / 1e6, 2)  AS real_usd
FROM usage_events
WHERE metric = 'voice_transcribe'
  AND occurred_at >= NOW() - INTERVAL '30 days'
GROUP BY 1
ORDER BY audio_minutes DESC;
```

Failure rate by channel and cause — the query that catches a broken provider:

```sql
SELECT metadata->>'channel' AS channel,
       metadata->>'outcome' AS outcome,
       COUNT(*)             AS calls
FROM usage_events
WHERE metric = 'voice_transcribe'
  AND occurred_at >= NOW() - INTERVAL '7 days'
GROUP BY 1, 2
ORDER BY 1, 3 DESC;
```

Latency and clip-length distribution for Telegram:

```sql
SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY (metadata->>'latencyMs')::bigint) AS p50_latency_ms,
       PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY (metadata->>'latencyMs')::bigint) AS p95_latency_ms,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amount) / 1000.0 AS median_clip_seconds
FROM usage_events
WHERE metric = 'voice_transcribe'
  AND metadata->>'channel' = 'telegram'
  AND metadata->>'outcome' = 'ok'
  AND occurred_at >= NOW() - INTERVAL '7 days';
```

Top tenants by voice minutes:

```sql
SELECT tenant_id,
       ROUND(SUM(amount) / 60000.0, 1) AS audio_minutes,
       COUNT(*)                        AS calls
FROM usage_events
WHERE metric = 'voice_transcribe'
  AND occurred_at >= NOW() - INTERVAL '30 days'
GROUP BY 1
ORDER BY audio_minutes DESC
LIMIT 20;
```

## Live metrics

Exported only when `otel.enabled=true` (otherwise they go to
`DiscardingMetricsFactory` and cost nothing), through the existing
otel-collector pipeline.

| Instrument | Type | Dimensions |
|---|---|---|
| `luminavault.voice.transcribe.requests` | counter | provider, channel, outcome |
| `luminavault.voice.transcribe.audio_duration` | timer | provider, channel, outcome |
| `luminavault.voice.transcribe.latency` | timer | provider, channel, outcome |
| `luminavault.voice.transcribe.audio_bytes` | recorder | provider, channel, outcome |

`channel` is collapsed to `other` outside a known set, and `tenant_id` is
deliberately absent: per-tenant series would multiply every instrument by the
user count. That question belongs to `usage_events`, which costs nothing extra
to keep.

Duration, latency and bytes are recorded for successful attempts only —
counting the zero from a failure would drag the median toward nothing and hide
a change in what users actually send. The failure *count* is still there, in
the requests counter.

## Retention

`usage_events` takes one row per transcription attempt, so it grows with
voice traffic. Retention is **off by default** — deleting usage history is
irreversible, so it stays a deliberate operator decision rather than
something that starts happening because a service was wired in.

```
USAGE_EVENTS_RETENTION_DAYS=90
```

Then sweep from the host cron, as with the memory prune:

```
curl -X POST -H "X-Admin-Token: $T" $BASE/v1/admin/usage-events/prune
```

Deletes in batches by primary key rather than one `DELETE ... WHERE
occurred_at < cutoff`, which would hold a single long lock over a table the
transcription path writes to synchronously. A sweep stops after 20 batches
and reports `moreRemaining: true`; run it again rather than raising the batch
size, which is how a maintenance job starts blocking writes.

The response echoes the policy, so a cron that finds `"enabled": false`
reports a misconfiguration instead of quietly doing nothing every night.

## Not yet metered

`POST /v1/audio/speech` returns 501, so spoken replies produce no rows. The
`voice_speech` metric value and the `voice_note` surface field exist ahead of
that writer, so landing TTS will not need another migration.
