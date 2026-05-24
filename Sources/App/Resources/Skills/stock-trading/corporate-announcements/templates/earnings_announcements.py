#!/usr/bin/env python3
"""
Corporate Announcements Calendar — reference implementation
Skill: corporate-announcements

Combines SEC EDGAR 8-K / Form 4 filings (last 7 days) with optional upcoming
earnings dates (Finnhub) into a single weekly calendar. Outputs to Discord
and Obsidian vault.

Usage (cron):     0 9 * * 0  python3 /opt/data/home/.hermes/scripts/earnings_announcements.py
Manual test:      python3 earnings_announcements.py

Exit codes: 0 = success (with or without content); 1 = misconfiguration (missing DISCORD_BOT_TOKEN)
"""

import os
import re
import sys
import json
import time
import datetime
import requests
from pathlib import Path

# ── Configuration ────────────────────────────────────────────────────────────

# Load .env if present
ENV_PATH = Path(__file__).parent / ".env"
if ENV_PATH.exists():
    with open(ENV_PATH) as f:
        for line in f:
            if "=" in line and not line.startswith("#"):
                k, v = line.strip().split("=", 1)
                os.environ.setdefault(k, v)

DISCORD_BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")
FINNHUB_API_KEY   = os.getenv("FINNHUB_API_KEY", "")

# Channel configured for StockPlan weekly reports
DISCORD_CHANNEL_ID = "1499338003334561843"

# Watchlist — must match stock-alert scripts (uppercase)
WATCHLIST = [
    "ZETA", "AMD", "AMZN", "HIMS", "OSCR", "SOFI", "KRKNF", "ONDS",
    "ABCL", "GRAB", "ASTS", "TE", "UBER", "NFLX", "NVO", "NKE", "SIDU",
    "SMR", "FLNC", "RDW", "ELF", "OUST", "CELH", "ZIP", "GOOGL"
]
WATCHLIST_SET = set(WATCHLIST)

# SEC EDGAR RSS
SEC_RSS_URL = "https://www.sec.gov/cgi-bin/browse-edgar?action=getcurrent&count=200&output=atom"

# Vault root (from memory or default)
VAULT_ROOT = Path(os.getenv("OBSIDIAN_VAULT_ROOT", "/opt/data/obsidian-vault"))
VAULT_OUTPUT_DIR = VAULT_ROOT / "Raw" / "HermesPortfolio" / "Earnings"

# ── Helpers ──────────────────────────────────────────────────────────────────

def log(msg: str) -> None:
    """Write debug/info to stderr only."""
    print(f"[earnings] {msg}", file=sys.stderr)

def now_utc() -> datetime.datetime:
    """Timezone-aware current UTC datetime."""
    return datetime.datetime.now(datetime.UTC)

def compile_ticker_regex(tickers: list[str]) -> re.Pattern:
    """Build regex that matches any ticker inside parentheses.
    Strategy: r'\((?:TICK1|TICK2|...)\)' with re.IGNORECASE.
    Sort by length descending to prefer longer matches if somehow overlapping.
    """
    sorted_tickers = sorted(tickers, key=len, reverse=True)
    pattern = r'\((?:' + '|'.join(sorted_tickers) + r')\)'
    return re.compile(pattern, re.IGNORECASE)

TICKER_RE = compile_ticker_regex(WATCHLIST)

def extract_ticker_from_title(title: str) -> str | None:
    """Return uppercase ticker if title contains a watchlist ticker inside parentheses."""
    m = TICKER_RE.search(title)
    if m:
        # strip surrounding parens
        return m.group(0)[1:-1].upper()
    return None

def sec_type_priority(form_type: str) -> int:
    """Lower numbers = more important (for sorting)."""
    form_type = form_type.upper()
    if form_type == "8-K":
        return 0
    if form_type == "FORM 4":
        return 1
    return 99

def fetch_sec_edgar() -> list[dict]:
    """Fetch last 7 days of SEC RSS entries; return list of relevant filings for watchlist."""
    log("Fetching SEC EDGAR RSS …")
    try:
        resp = requests.get(SEC_RSS_URL, timeout=15, headers={"User-Agent": "HermesAgent/1.0"})
        resp.raise_for_status()
    except Exception as e:
        log(f"SEC fetch failed: {e}")
        return []

    # Parse RSS (Atom). Using simple regex is fragile; use proper parser if available.
    # For brevity, assume feedparser or xml.etree available.
    try:
        import feedparser
        feed = feedparser.parse(resp.text)
    except ImportError:
        log("feedparser not available; cannot parse SEC RSS")
        return []

    cutoff = now_utc() - datetime.timedelta(days=7)
    relevant = []

    for entry in feed.entries:
        # Parse date
        published = getattr(entry, "published", None) or getattr(entry, "updated", None)
        if published:
            try:
                entry_dt = datetime.datetime.strptime(published[:25], "%a, %d %b %Y %H:%M:%S").replace(tzinfo=datetime.UTC)
            except Exception:
                entry_dt = now_utc()  # fallback
        else:
            entry_dt = now_utc()

        if entry_dt < cutoff:
            continue  # too old

        title = entry.get("title", "")
        ticker = extract_ticker_from_title(title)
        if not ticker or ticker not in WATCHLIST_SET:
            continue

        # Identify form type from title prefix "8-K —" or "Form 4 —"
        form_type = title.split("—")[0].strip() if "—" in title else "Unknown"

        relevant.append({
            "ticker": ticker,
            "title": title,
            "link": entry.get("link", ""),
            "published": entry_dt,
            "form_type": form_type,
            "priority": sec_type_priority(form_type),
        })

    # Sort: priority ascending (8-K first), then date descending (newest first)
    relevant.sort(key=lambda x: (x["priority"], -x["published"].timestamp()))
    log(f"  {len(relevant)} relevant filings found")
    return relevant

def fetch_earnings_finhub() -> list[dict]:
    """Fetch this week's upcoming earnings from Finnhub if API key configured."""
    if not FINNHUB_API_KEY:
        return []  # graceful degradation

    log("Fetching earnings calendar from Finnhub …")
    today = now_utc().strftime("%Y-%m-%d")
    week_end = (now_utc() + datetime.timedelta(days=7)).strftime("%Y-%m-%d")
    url = f"https://finnhub.io/api/v1/calendar/earnings?from={today}&to={week_end}&token={FINNHUB_API_KEY}"

    try:
        resp = requests.get(url, timeout=15)
        resp.raise_for_status()
        data = resp.json()
    except Exception as e:
        log(f"Finnhub fetch failed: {e}")
        return []

    earnings = []
    for item in data.get("earningsCalendar", []):
        ticker = item.get("symbol", "").upper()
        if ticker in WATCHLIST_SET:
            earnings.append({
                "ticker": ticker,
                "date": item.get("date", ""),
                "eps_guess": item.get("epsEstimate", None),
                "revenue_guess": item.get("revenueEstimate", None),
                "period": item.get("period", ""),  # e.g., "Q1 FY2027"
            })

    # Sort by date ascending
    earnings.sort(key=lambda x: x["date"])
    log(f"  {len(earnings)} upcoming earnings found")
    return earnings

def format_section(items: list[dict], kind: str) -> str:
    """Format SEC or earnings items into markdown bullets."""
    lines = []
    if kind == "sec":
        for item in items:
            date_str = item["published"].strftime("%b %d")
            lines.append(f"• **[{item['form_type']}] {item['ticker']}** — {date_str} — {item['link']}")
    elif kind == "earnings":
        for item in items:
            date_str = item["date"]
            label = f" ({item['period']})" if item.get("period") else ""
            lines.append(f"• **{item['ticker']}** — {date_str}{label}")
    return "\n".join(lines)

def post_to_discord(content: str) -> bool:
    """Post markdown message to Discord channel using bot token."""
    if not DISCORD_BOT_TOKEN:
        log("ERROR: DISCORD_BOT_TOKEN not set in .env")
        return False

    url = f"https://discord.com/api/v10/channels/{DISCORD_CHANNEL_ID}/messages"
    headers = {
        "Authorization": f"Bot {DISCORD_BOT_TOKEN}",
        "Content-Type": "application/json",
    }
    payload = {"content": content}
    try:
        r = requests.post(url, headers=headers, json=payload, timeout=15)
        if r.status_code in (200, 201):
            log("Discord post successful")
            return True
        else:
            log(f"Discord post failed HTTP {r.status_code}: {r.text[:200]}")
            return False
    except Exception as e:
        log(f"Discord post exception: {e}")
        return False

def write_vault(content: str, date_str: str) -> Path | None:
    """Write markdown to vault; return Path on success, None on failure."""
    try:
        VAULT_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
        vault_file = VAULT_OUTPUT_DIR / f"calendar_{date_str}.md"
        vault_file.write_text(content, encoding="utf-8")
        log(f"Vault write: {vault_file}")
        return vault_file
    except Exception as e:
        log(f"Vault write failed: {e}")
        return None

# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    if not DISCORD_BOT_TOKEN:
        print("ERROR: DISCORD_BOT_TOKEN missing from .env", file=sys.stderr)
        return 1

    date_str = now_utc().strftime("%Y%m%d")
    date_display = now_utc().strftime("%a, %b %d, %Y")

    # 1. SEC EDGAR
    sec_items = fetch_sec_edgar()
    sec_section = format_section(sec_items, "sec") if sec_items else "_No major filings for your watchlist this week._"

    # 2. Earnings (optional)
    earn_items = fetch_earnings_finhub()
    if earn_items:
        earn_section = format_section(earn_items, "earnings")
    elif FINNHUB_API_KEY:
        earn_section = "_No earnings announcements found for your watchlist this week._"
    else:
        earn_section = "_No earnings data — add FINNHUB_API_KEY to .env to enable_"

    # Build full message
    lines = [
        f"📊 **Earnings & Announcements Calendar**",
        f"_{date_display}_",
        "",
        f"📰 **SEC EDGAR — Last 7 Days**  *(8-K ⚠️ news | Form 4 💼 insider)*",
        sec_section,
        "",
        "---",
        "",
        "📅 **Upcoming Earnings**",
        earn_section,
        "",
        "---",
        "",
        f"Sources: SEC EDGAR (last 7 days){' | Finnhub Earnings Calendar' if FINNHUB_API_KEY else ' | 💡 Add FINNHUB_API_KEY to .env for earnings'}",
    ]
    message = "\n".join(lines)

    # Deliver
    post_ok = post_to_discord(message)
    vault_ok = write_vault(message, date_str) is not None

    # Print to stdout for cron deliver (if configured)
    print(message)

    log(f"Done. Discord: {'✅' if post_ok else '❌'}, Vault: {'✅' if vault_ok else '❌'}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
