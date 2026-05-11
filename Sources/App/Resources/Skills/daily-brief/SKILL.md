---
name: daily-brief
description: Morning brief of pending threads, due reminders, and recent captures for the user.
allowed-tools: session_search vault_read
metadata:
  capability: low
  schedule: "0 7 * * *"
  outputs:
    - kind: memo
      path: memos/{date}/daily-brief.md
    - kind: apns_digest
---
TODO HER-173 — body prompt to be written. The runner expects ~300 words of skill-specific instructions here.
