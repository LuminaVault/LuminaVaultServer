# Find something again

Four ways, depending on what you remember about it.

| You remember | Use |
|---|---|
| Roughly what it said | [Search memories](#search-memories) |
| What it looked like | [Search by picture](#search-by-picture) |
| Where you filed it | [Browse the vault](#browse-the-vault) |
| Only the question it answers | [Ask in chat](chat-and-ask.md) |

---

## Search memories

**Web** — Sidebar → **Memories**. Type in **"Semantic search"** and press Enter
or click **Search**. **Clear** goes back to the full list.

**iOS** — Settings → **Your Agent** → **Memories**. Search prompt is
**"Search memories"**.

This is semantic, not literal — near-enough wording finds it.

Each result can be opened to see its **lineage**: the **Source file** it came
from and its **Ancestors**. If it says **"No linked vault file"**, the memory
was written directly rather than extracted from a note.

---

## Search by picture

Show Lumina a photo and it finds related notes. **The two clients do genuinely
different things here.**

**Web** — Sidebar → **Visual search** → **"Choose an image"**. The search starts
the moment you pick a file; there is no Search button. PNG, JPEG, WebP or HEIC,
up to 8 MB.

The web matches the **picture itself** against your memories. It does not read
the text out of it. As the page says: *"a photo of a whiteboard finds what it
resembles, not what it says."* Results show a **distance** number, because an
image search has no wording to sanity-check against.

**iOS** — **More** → **Visual Search** → **"Pick an image"**. iOS reads the text
out of the picture **on your device first** (*"Reading text…"*), then searches
with that text (*"Asking Hermes…"*). Results come back as **"Hermes says"**, the
**"Recognised text"** it extracted, and **"Memory hits"**.

So: for a photo of dense text — a book cover, a menu, a sign — use iOS. For
finding something that *looks* like your picture, use the web.

Web validation copy: *"That file is \<type\>. Use a PNG, JPEG, WebP or HEIC
image."* and *"That image is X.X MB. The limit is 8.0 MB."*

---

## Browse the vault

**Web** — Sidebar → **Vault**. The left column lists files; click one to read it.

- **"Search paths"** searches filenames, not contents. It runs when you submit,
  not as you type.
- Markdown files get a **Rendered** / **Source** toggle. Other files show raw.
- Arriving from a Space shows a banner with **Show all notes** to clear it.

**iOS** — **Spaces** tab → a Space card (or **Inbox**) → a file row. Filter the
list with **All** / **Notes** / **Todos**.

- Long-press a row for **Move…**, **Share path**, **Delete**.
- In the reader, the **⋯** menu has **Edit** and **Delete** — but **only for
  markdown files, and only where the screen was opened with edit rights**.
  Notes you reach from a reflection or a chat citation are read-only, which is
  why the menu is sometimes missing.
- Editing gives you **Title**, body, tags, and **"Make this a todo"** with a due
  date and reminder.

iOS also has a vault search sheet — **"Ask Lumina or find a file…"** — which
returns **Lumina says**, **Memories** and **Files** together.

---

## Move or delete a file

**iOS** — long-press the row in a Space. **Move…** asks for a **New path**;
**Delete** warns *"…will be moved to the soft-deleted bin."*

**Web** — on the Home feed, hover a row for rename and delete.

Deleting a vault file also removes the memories derived from it. It is not
archived in a way you can restore from the app.

---

## Nothing found?

- **"Nothing close enough"** on visual search — try a different picture, or the
  thing genuinely is not saved yet.
- **"No vault file at …"** — the file was moved or deleted after something
  linked to it.
- Memories lag captures. Content is searchable once it has been processed; on
  iOS you can force it with **Sync & Learn** on the Dashboard.
