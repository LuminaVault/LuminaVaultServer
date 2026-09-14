# Bring things in, take everything out

---

## Import

For more than a file or two at a time, or anything that needs processing —
PDFs, audio, video, web pages.

### Web

1. Sidebar → **Import**. The page is headed **Capture anything**.
2. Drag files onto **"Drop files here"**, or click it to pick. PDF, image, audio
   or video. **Up to 50 files** per batch.
3. Choose **Save to Space**. The first option is **Inbox**. Your choice is
   remembered for next time.
4. Paste URLs into **Web pages** — one per line or space-separated, both work.
5. Click **Capture N items**.

You get *"Capture saved to the vault. Hermes processing started."*

### iOS

1. Tap **+** in the tab bar → the **Files** mode.
2. **Choose files** — PDFs, images, audio or video.
3. Pick a Space under **Save to Space** (first row **Inbox**).
4. Optionally paste a URL into **"Paste a web page URL"**.
5. Tap **Save to vault**.

### Watching it process

Both clients show a per-item list with a state — `awaiting upload`,
`processing`, `completed`, and so on.

- **Retry** appears only for items that **failed** or were **blocked**.
- **Cancel** appears for anything not already finished.
- Where Hermes returned one, a **Source credibility** score and rationale shows.

Uploads are resumable. Close the tab mid-upload and it picks up from where it
stopped when you come back — there is no button for this, it just happens.

### If capture is blocked

A red banner:

> Your connected Hermes does not advertise multimodal ingestion with remote
> source access. Upgrade or enable its ingestion API before uploading files.

This is your own Hermes saying it cannot do ingestion. It only applies if you
are on BYO Hermes — the managed brain always can. See
[integrations/hermes.md](../integrations/hermes.md).

Per-file rejections come from the same capability probe:
*"\<name\> is not supported by the connected Hermes."* and
*"\<name\> exceeds the connected Hermes source-size limit."*

### Other ways in

**Bookmarks** — the server accepts bookmark exports. **Vault bulk import** —
for moving an existing folder of markdown in. Neither has a dedicated screen
yet; both go through the import endpoints.

**From your own Hermes** — if you already keep a knowledge vault there, the
Hermes mirror imports it rather than you re-uploading. Web only:
Settings → **Hermes server** → **Hermes mirror** → **Import vault**, or
**Import from path** for a directory you name.

---

## Export

Everything you have saved, in one archive. No ceremony, no support ticket.

**Web** — Sidebar → **Vault** → **Export vault**. The button reads
**Preparing…** and then the archive downloads. The same button is in
Settings → **Account**, as **Download my vault**.

**iOS** — Settings → **Account & Data** → **Privacy & Data** →
**Export my data**. It streams to a file and hands it to the share sheet, so you
can save it to Files, AirDrop it, or send it wherever.

The export is your vault as files. It is readable without LuminaVault — it is
markdown and the assets you uploaded.

---

## Deleting your account

**Web** — Settings → **Account** → **Delete this account**. Type
`DELETE MY ACCOUNT` into the confirmation field, add your password if you use
one (leave blank for Apple or Google sign-in), then **Delete my account**.

**iOS** — Settings → **Account & Data** → **Privacy & Data**. The app makes you
export first: *"Export your data first — the Delete button enables after you
dismiss the share sheet."* The Delete button stays disabled until you have.

This is not reversible.

---

## Known limits

- **Import is capped at 50 files per batch** on the web.
- **Bookmark and bulk-vault import have no UI** — endpoints only.
- **Mirror import is web-only**, because it needs the Hermes dashboard, which
  iOS cannot link.
- **Export is a download, not a sync.** There is no continuous backup to a
  folder you control; run it again when you want a fresh copy.
