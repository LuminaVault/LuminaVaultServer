---
name: kb-compile
description: Compile recent vault captures into structured memory entries with embeddings and tags.
allowed-tools: vault_read memory_upsert
metadata:
  capability: medium
  schedule: "0 2 * * *"
  on_event:
    - vault_file_created
  outputs:
    - kind: memory_emit
---
TODO HER-173 — body prompt to be written. The runner expects ~300 words of skill-specific instructions here.
