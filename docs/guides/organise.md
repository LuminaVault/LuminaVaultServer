# Keep it tidy

Spaces are folders. Memories are what Lumina extracted. The Brain is how they
connect.

---

## Spaces

A Space is a named folder in your vault. Captures can be filed into one, and
each Space links to a filtered view of your notes. Anything unfiled lands in
**Inbox**.

### Create one

**Web** — Sidebar → **Spaces** → **New space**.
**iOS** — **Spaces** tab → the **+** button.

Fields on both: **Name**, **Slug**, **Icon**, **Category**, and an optional
colour (`#FFAA00`).

The **slug** is auto-filled from the name until you edit it, and is
**permanent** — the field disappears when editing. Category is free text, with
one-tap chips for categories you already use.

### Edit or delete

**Web** — hover a card for **Edit** and **Delete**.
**iOS** — long-press a card for **Edit** and **Delete**.

Deleting warns you what happens: *"Notes stored under this space stay on disk in
a `_deleted_…` folder."* The Space goes; the notes do not.

### Filing things into one

There is **no "add note" button inside a Space**. You file at capture time, with
the Space picker in the capture sheet — see
[capture](capture.md#filing-into-a-space) — or by moving the file afterwards.

Category chips only appear once you have more than one category.

---

## Memories

A memory is something Lumina extracted and can recall. Some come from your
notes, some you save directly from a chat answer.

**Web** — Sidebar → **Memories**.
**iOS** — Settings → **Your Agent** → **Memories**.

### Edit one

Select it, click **Edit**, change the content or the tags (comma-separated),
then **Save**.

### Approve or reject

Memories learned automatically start as **pending**.

**Web** — select a pending memory. A **"Keep this memory?"** block appears with
**Keep** and **Reject**. It only shows for pending ones, because the server
refuses any other transition.

**iOS** — this happens in the **Sync & Learn** review sheet rather than the
memory list. After a compile you get **"Review what Hermes learned"** —
*"Approve to keep, reject to forget. Rejected items stay rejected on future
syncs."* Swipe each row to **Approve** or **Reject**.

### Delete one

**Web** — **Delete**, then confirm: *"Delete this memory permanently?"* /
*"It is not archived, and it cannot be recovered."* Two steps on purpose.

**iOS** — swipe the row → **Delete**.

### Review queues

The web has queues for memories needing attention — **Review overdue**,
**Pending review**, **Unorganized memories**, **Unused knowledge**.

**There is no filter control on the Memories page.** You reach a queue by
clicking a **Recommended next** card on **Analytics** or the **Dashboard**. Once
in one, a banner names it and offers **Show all**.

---

## The Brain

A graph of everything, with two layers.

**Web** — Sidebar → **Brain**. **iOS** — the **Brain** tab.

Switch layers with the **Knowledge** / **Memories** control:

- **Memories** — what you saved and how it links up. Tap a node to read it.
- **Knowledge** — claims, entities and events the extractor derived, with
  supporting and contradicting connections between them.

If Knowledge has nothing in it, both clients quietly fall back to Memories
rather than showing you an empty universe.

**Web** filters (Memories layer only): provider, model, source and a date range,
then **Apply**. Nothing reloads until you press it.

**iOS** filters the Memories layer with legend chips — **Sources**, **Links**,
**Tags**, **Spaces**, **Similar**, **Time**. **Time** starts off because it
makes a hairball.

### Asking the graph

**Web** — the **Reason over your brain** panel on the right.
**iOS** — the **Reason** button in the toolbar.

Type a question (*"What changed my view on…?"*) and run it. You get an answer, a
confidence score, the evidence behind it, and the reasoning paths — click one to
highlight it in the graph.

You can also select **two nodes** and ask **Explain this connection**.

### Confirming what it inferred

Both clients show **Connections to review**: edges the extractor is not sure
about, each with a rationale and sometimes counter-evidence. **Confirm** or
**Dismiss**.

This is how the graph gets better. Left alone, uncertain edges stay uncertain.

Note the Brain is read-only for memories on iOS — the detail sheet shows content
but no edit or delete. Use the Memories screen for that.
