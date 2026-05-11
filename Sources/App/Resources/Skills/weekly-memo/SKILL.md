---
name: weekly-memo
description: Sunday-evening synthesis of the past week — themes, accomplishments, open loops, next-week priors.
allowed-tools: session_search vault_read memory_upsert
metadata:
  capability: medium
  schedule: "0 18 * * 0"
  outputs:
    - kind: memo
      path: memos/weekly/{year}-W{week}.md
    - kind: apns_digest
---
TODO HER-173 — body prompt to be written. The runner expects ~300 words of skill-specific instructions here.
