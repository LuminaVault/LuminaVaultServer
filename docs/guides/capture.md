# Save something

Notes, links, files, voice. The point of LuminaVault is that saving is fast
enough that you actually do it.

Everything you save becomes a file in your vault and is searchable afterwards.

---

## A note

**Web** — Sidebar → **Home**. Click the box (**"What do you want to remember?"**),
type, press **Enter**. Shift+Enter gives you a newline. You get
*"Saved to your vault."*

**iOS** — **Home** tab. Tap the field (same placeholder), type, tap the **Save**
arrow.

Both file it into `inbox/`. Neither Home composer has a Space picker — use the
capture sheet ([below](#filing-into-a-space)) if you want it filed on the way in.

---

## A link

Paste the URL **on its own**, with nothing else in the box.

A chip appears showing the site and the words **"Saved as a link"**. That is a
preview of what will happen, not a confirmation that it already did — it is
telling you this will be filed as a bookmark rather than as a note. Press Save.

Add any other word next to the URL and the chip disappears and you get a note
containing a link, which is usually what you want for *"read this before Friday
https://…"*. The rule is strict on purpose: one whitespace-delimited token,
`http` or `https`.

The server fetches the page afterwards. The row reads **"Fetching the page…"**
until it lands.

---

## A file

**Web** — On **Home**, click the paperclip. Accepted: markdown, text, PNG, JPEG,
WebP, GIF, HEIC, PDF, MP3, M4A, AAC, WAV, FLAC, MP4, MOV, WebM. Then **Save**.

For more than one file at a time, use **Import** — see
[import-and-export](import-and-export.md#import).

**iOS** — **Home** tab → **"Add a photo"** or **"Add a file"**, which opens the
capture sheet. Or tap the **+** in the tab bar and choose a mode.

---

## A voice note

**Web** — On Home or in Chat, click **"Speak"**. It turns red and reads
**"Stop"**. Click it again; the button shows **"Transcribing…"** and the text is
**appended to the box**. You still press Save. The button is absent entirely if
your browser cannot record.

**iOS, on Home** — tap the mic (**"Record a voice note"**). A chip shows elapsed
time and **"Recording"**, with **"Cancel"**. Tap the mic again to save. It stops
and saves itself at two minutes.

**iOS, in chat** — **press and hold** the mic, speak, and **release to send**.
Holding is the gesture; there is no tap-to-toggle unless you use VoiceOver or
Full Keyboard Access, which get a tap toggle instead.

Only the transcript is stored. The audio is never uploaded.

---

## Without opening the app

These are all iOS.

**Share sheet** — in any app, Share → **LuminaVault**. The sheet is titled
**"Save to LuminaVault"** and lets you add a note and pick a Space.

**Siri / Shortcuts** — say *"Capture to LuminaVault"*, *"Save a note in
LuminaVault"*, or *"Remember this in LuminaVault"*. It asks
**"What do you want to remember?"** and saves without opening the app. There is
also *"Ask LuminaVault"*, which opens the app with your question in the chat box.

**Widget** — a **Recent Captures** widget shows what you last saved. It is
read-only, holds no credentials, and makes no network calls.

**Offline** — captures queue on the device and sync when you are back. A queued
row says **"Queued"**; one that failed offers **"Try again"** and **"Discard"**.

---

## Filing into a Space

The Home composer always saves to `inbox/`. To file on the way in, use the
capture sheet.

**iOS** — tap **+** in the tab bar. Four modes: **"Photos"**, **"Text"**,
**"Link"**, **"Files"**. Photos, Text and Link each have a **"Space"** picker
whose first row is **"Unfiled"**; Files calls it **"Save to Space"** with
**"Inbox"** first. The Space card is hidden if you have no Spaces yet.

**Web** — the **Capture** button in the header (or the **+** on mobile) opens
**"Quick capture"** with **"Note"** and **"Link"** tabs. It has no Space picker;
use **Import** to file into a Space, or move the file afterwards.

Photos on iOS also offer **"Tag with current location"**, off by default. Turning
it on sends one location fix and the place name with that capture.

---

## Did it save?

Both clients show a **Recently saved** feed under the composer. Web adds a
**Load more** button past 30 items.

If a row sits at **"Queued"** on iOS you are offline, which is fine — it will
go when you reconnect.

---

## When it does not work

| You see | What it means |
|---|---|
| *"Nothing to capture."* | The box is empty and there is no attachment. |
| *"That does not look like a link."* | Link mode with something that is not a URL. |
| *"Could not save that."* | The save failed. Your text stays in the box — try again. |
| *"That recording was empty."* / *"Nothing was picked up."* | No speech detected. Nothing was written. |
| *"Microphone unavailable. Check the site permission and try again."* | Browser mic permission denied. |
| *"Enable Microphone & Speech Recognition in Settings to talk to Lumina."* | iOS permission denied — iOS Settings ▸ Privacy & Security. |
| *"That recording is too long to transcribe. Try a shorter one."* | Past the duration cap. |
| *"Capture isn't ready yet"* | iOS only, and rare — the vault is still being prepared. Wait a moment. |
