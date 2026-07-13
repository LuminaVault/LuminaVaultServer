#!/usr/bin/env bash
set -euo pipefail

# Streams real source files through the chunked ingestion API without loading a
# source into shell memory. Run against staging after scaling the API deployment
# to at least two replicas; see docs/multimodal-ingestion-load-testing.md.

: "${API_BASE_URL:?Set API_BASE_URL, for example https://api-staging.luminavault.fyi}"
: "${AUTH_TOKEN:?Set AUTH_TOKEN to a staging bearer token}"
: "${LOAD_FILES:?Set LOAD_FILES to comma-separated absolute source paths}"

BATCHES="${BATCHES:-2}"
CHUNK_SIZE="${CHUNK_SIZE:-8388608}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
PROCESS_TIMEOUT_SECONDS="${PROCESS_TIMEOUT_SECONDS:-1800}"

command -v curl >/dev/null
command -v jq >/dev/null
command -v shasum >/dev/null

IFS=',' read -r -a files <<<"$LOAD_FILES"
if (( ${#files[@]} == 0 )); then
  echo "LOAD_FILES did not contain any paths" >&2
  exit 2
fi

file_size() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

content_type() {
  file --brief --mime-type "$1" 2>/dev/null || printf '%s\n' application/octet-stream
}

items='[]'
batch_bytes=0
for path in "${files[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "Source file does not exist: $path" >&2
    exit 2
  fi
  size="$(file_size "$path")"
  if (( size <= 0 || size > 2147483648 )); then
    echo "Each source must be 1..2147483648 bytes: $path ($size bytes)" >&2
    exit 2
  fi
  batch_bytes=$((batch_bytes + size))
  mime="$(content_type "$path")"
  sha="$(shasum -a 256 "$path" | awk '{print $1}')"
  items="$(jq -c \
    --arg name "$(basename "$path")" \
    --arg mime "$mime" \
    --arg sha "$sha" \
    --argjson size "$size" \
    '. + [{kind:"file", fileName:$name, contentType:$mime, sizeBytes:$size, sha256:$sha}]' <<<"$items")"
done
if (( batch_bytes > 5368709120 )); then
  echo "Batch exceeds 5368709120 bytes ($batch_bytes bytes)" >&2
  exit 2
fi

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/lv-ingestion-load.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

upload_batch() {
  local ordinal="$1" response batch_id item_count item_id path size offset index chunk
  response="$(curl --fail-with-body --silent --show-error \
    -X POST "$API_BASE_URL/v1/ingestions" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$(jq -cn --argjson items "$items" '{items:$items}')")"
  batch_id="$(jq -er '.id' <<<"$response")"
  item_count="$(jq -er '.items | length' <<<"$response")"
  if (( item_count != ${#files[@]} )); then
    echo "Batch $batch_id returned $item_count items; expected ${#files[@]}" >&2
    return 1
  fi

  for ((file_index = 0; file_index < item_count; file_index++)); do
    item_id="$(jq -er ".items[$file_index].id" <<<"$response")"
    path="${files[$file_index]}"
    size="$(file_size "$path")"
    offset=0
    index=0
    chunk="$tmp_root/chunk-$ordinal-$file_index"
    while (( offset < size )); do
      dd if="$path" of="$chunk" bs="$CHUNK_SIZE" skip="$index" count=1 status=none
      curl --fail-with-body --silent --show-error \
        -X PUT "$API_BASE_URL/v1/ingestions/$batch_id/items/$item_id/chunks/$index" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H 'Content-Type: application/octet-stream' \
        --data-binary "@$chunk" >/dev/null
      offset=$((offset + $(file_size "$chunk")))
      index=$((index + 1))
    done
    curl --fail-with-body --silent --show-error \
      -X POST "$API_BASE_URL/v1/ingestions/$batch_id/items/$item_id/complete" \
      -H "Authorization: Bearer $AUTH_TOKEN" >/dev/null
    rm -f "$chunk"
  done
  printf '%s\n' "$batch_id" >"$tmp_root/batch-$ordinal"
  echo "uploaded batch=$batch_id bytes=$batch_bytes files=$item_count"
}

pids=()
for ((batch = 0; batch < BATCHES; batch++)); do
  upload_batch "$batch" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"
done

deadline=$((SECONDS + PROCESS_TIMEOUT_SECONDS))
for batch_file in "$tmp_root"/batch-*; do
  batch_id="$(<"$batch_file")"
  while (( SECONDS < deadline )); do
    detail="$(curl --fail-with-body --silent --show-error \
      "$API_BASE_URL/v1/ingestions/$batch_id" \
      -H "Authorization: Bearer $AUTH_TOKEN")"
    state="$(jq -er '.state' <<<"$detail")"
    if [[ "$state" == completed || "$state" == attention ]]; then
      echo "terminal batch=$batch_id state=$state completed=$(jq -r '.completed' <<<"$detail") failed=$(jq -r '.failed' <<<"$detail")"
      break
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
  if (( SECONDS >= deadline )); then
    echo "Timed out waiting for batch $batch_id" >&2
    exit 1
  fi
done
