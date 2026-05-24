# Discord & Vault Output Format

**Skill**: `corporate-announcements` | **Output**: Both channels identical (markdown)

## Discord Message Template

```markdown
📊 **Earnings & Announcements Calendar**
_Thu, Apr 30, 2026_

📰 **SEC EDGAR — Last 7 Days**  *(8-K ⚠️ news | Form 4 💼 insider)*
_No major filings for your watchlist this week._

---
📅 **Upcoming Earnings**
_No earnings data — add FINNHUB_API_KEY to .env to enable_

---
Sources: SEC EDGAR (last 7 days) | 💡 Add FINNHUB_API_KEY to .env for earnings
```

### With Content (example)

```markdown
📊 **Earnings & Announcements Calendar**
_Sun, May 3, 2026_

📰 **SEC EDGAR — Last 7 Days**  *(8-K ⚠️ news | Form 4 💼 insider)*
• **[8-K] Zeta Corp** — May 1 — https://www.sec.gov/...
• **[Form 4] AMD** — Insider buy (Director) — Apr 29 — https://www.sec.gov/...

---
📅 **Upcoming Earnings**
• **ZETA** — May 5 (Q1 FY2027)
• **AMD** — May 6 (Q1 FY2027)

---
Sources: SEC EDGAR (last 7 days) | Finnhub Earnings Calendar
```

### Formatting Rules

- **Header**: 📊 + bold title + italicized date line
- **SEC section**: 📰 + italic descriptor `*(8-K ⚠️ news | Form 4 💼 insider)*`
- **Bullets**: `• **[Form Type] TICKER** — short description — date — URL`
  - Form type in brackets for scannability: `[8-K]`, `[Form 4]`
  - URLs are plain (Discord auto-embeds some SEC links; markdown links optional)
  - Sort: 8-K first (more important), then Form 4; within each, reverse-chronological (newest first)
- **Earnings section**: 📅 + bullet list `• **TICKER** — date (period label)`
  - Sort: chronologically ascending (nearest date first)
  - Period label from Finnhub `EPSGross` field if available, else omit
- **Divider**: `---` between sections
- **Sources line**: Last line, plain text, `|` separator between sources

## Vault Markdown File

Same content as Discord message, saved to:

```
Raw/HermesPortfolio/Earnings/calendar_YYYYMMDD.md
```

Example: `calendar_20260503.md`

### Frontmatter (optional, not used)

Do **not** add YAML frontmatter — keep pure markdown for easy reading in Obsidian. If you want metadata, add as the first italic line (already present as date line).

## Empty Output Policy

If **both** SEC and earnings sections would be empty:
- Do **not** write a vault file (skip entirely)
- Do **not** post to Discord (silent exit 0)

This prevents "no news this week" spam in the channel.

## Error Messages

Send errors to **stderr only**; stdout reserved for the message content (cron deliver reads stdout). Example:

```
STDERR: [earnings_announcements] SEC fetch failed: HTTP 403 — retrying
STDERR: [earnings_announcements] Missing DISCORD_BOT_TOKEN in .env, exiting
```

## Channel Context

- **Discord channel ID**: `1499338003334561843` (StockPlan announcements)
- **Guild membership**: Bot must be a member of the guild containing this channel; 403 indicates missing membership or permissions.
- **Permissions required**: `View Channel`, `Send Messages`

## Vault Path Conventions

- Root: `/opt/data/obsidian-vault` (memory-stored)
- Subdirectory: `Raw/HermesPortfolio/Earnings/`
- Filename: `calendar_YYYYMMDD.md` (UTC date of script execution)
- Create parent directories if missing (`os.makedirs(..., exist_ok=True)`)

## Link Format

SEC filing URLs are of the form:
```
https://www.sec.gov/Archives/edgar/data/{cik}/{date}/{accession_number}.txt
```

or from RSS `link` field (often a HTML filing detail page). Both are acceptable; prefer the detail page for readability.
