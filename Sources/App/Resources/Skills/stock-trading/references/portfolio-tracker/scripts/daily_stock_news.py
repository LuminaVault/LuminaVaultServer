#!/usr/bin/env python3
"""
Daily Stock News Digest — Yahoo Finance + Google News RSS
Fetches recent headlines for followed tickers and formats a Markdown digest.
Stocks: AMD, GOOGL, ZETA, HIMS, AMZN, OSCR, ASTS, SOFI, ADUR, TE,
        NFLX, ONDC, UBER, NVO, KRKNF, A6I, ABCL

Pure stdlib. Output: Markdown to stdout.
"""

import re, sys, os, json, datetime, urllib.request, urllib.parse, html
from collections import defaultdict

# ─── Tickers ───
TICKERS = [
    "^GSPC", "^IXIC",   # S&P 500 and NASDAQ indices (Yahoo Finance RSS)
    "AMD", "GOOGL", "AMZN", "NFLX", "UBER",
    "ZETA", "HIMS", "OSCR", "ASTS", "SOFI", "ADUR", "TE",
    "ONDC",  # likely what user meant (ONDS not found on Yahoo)
    "ABCL",
    "KRKNF",
    "A6I",   # Yahoo uses A6I.F for Frankfurt
    "NVO",
]

# Ticker normalization for Yahoo Finance queries
YAHOO_TICKER = {
    "A6I": "A6I.F",
    "NVO": "NVO",
    "KRKNF": "KRKNF",
}

# ─── State (deduplication) ───
STATE_DIR = os.path.expanduser("~/.cache/hermes/stock_news")
os.makedirs(STATE_DIR, exist_ok=True)
SEEN_FILE = os.path.join(STATE_DIR, "seen_links.json")

def load_seen():
    try:
        with open(SEEN_FILE) as f:
            return set(json.load(f))
    except Exception:
        return set()

def save_seen(seen):
    with open(SEEN_FILE, "w") as f:
        json.dump(list(seen), f)

# ─── Networking ───
UA = "Mozilla/5.0 (compatible; HermesBot/1.0; +https://hermes.dev)"
def fetch(url, timeout=12):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")

# ─── RSS/Atom parsing ───
def parse_rss_items(raw, source_name=""):
    items = []
    # RSS 2.0
    for block in re.split(r"</item>", raw, flags=re.I):
        t = re.search(r"<title[^>]*>(.*?)</title>", block, re.I | re.S)
        l = re.search(r"<link[^>]*>(.*?)</link>", block, re.I | re.S)
        if t and l:
            title = html.unescape(re.sub(r"<[^>]+>", " ", t.group(1)).strip())
            link = html.unescape(re.sub(r"<[^>]+>", " ", l.group(1)).strip())
            if title and link:
                items.append({"title": title, "link": link, "source": source_name})
    # Atom
    if not items:
        for block in re.split(r"</entry>", raw, flags=re.I):
            t = re.search(r"<title[^>]*>(.*?)</title>", block, re.I | re.S)
            l = re.search(r'<link[^>]*href=["\'](.*?)["\']', block, re.I | re.S)
            if t and l:
                title = html.unescape(re.sub(r"<[^>]+>", " ", t.group(1)).strip())
                link = html.unescape(l.group(1).strip())
                if title and link:
                    items.append({"title": title, "link": link, "source": source_name})
    return items

# ─── Feed URLs ───
def yahoo_feed(ticker):
    yt = YAHOO_TICKER.get(ticker, ticker)
    return f"https://feeds.finance.yahoo.com/rss/2.0/headline?s={urllib.parse.quote(yt)}&region=US&lang=en-US"

def google_feed(ticker):
    q = urllib.parse.quote(f"{ticker} stock news")
    return f"https://news.google.com/rss/search?q={q}&hl=en-US&gl=US&ceid=US:en"

# ─── Fetch per ticker ───
def fetch_ticker_news(ticker):
    seen_local = set()
    results = []

    # Yahoo Finance
    try:
        raw = fetch(yahoo_feed(ticker))
        for it in parse_rss_items(raw, "Yahoo Finance"):
            if it["link"] not in seen_local:
                results.append(dict(it, ticker=ticker))
                seen_local.add(it["link"])
    except Exception as e:
        print(f"⚠  {ticker} [Yahoo]: {e}", file=sys.stderr)

    # Google News fallback (if < 3 Yahoo items)
    if len(results) < 3:
        try:
            raw = fetch(google_feed(ticker))
            for it in parse_rss_items(raw, "Google News"):
                if it["link"] not in seen_local:
                    results.append(dict(it, ticker=ticker))
                    seen_local.add(it["link"])
        except Exception as e:
            print(f"⚠  {ticker} [Google]: {e}", file=sys.stderr)

    return results[:5]

# ─── Formatting ───
def format_digest(items_by_ticker):
    now = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M UTC")
    lines = [f"📈 **Daily Stock News Digest** — {now}", ""]

    for ticker in TICKERS:
        items = items_by_ticker.get(ticker)
        if not items:
            continue
        lines.append(f"## {ticker}")
        for it in items:
            title = it["title"][:110]
            link = it["link"]
            src_tag = f"  _({it['source']})_" if it.get("source") else ""
            lines.append(f"• [{title}]({link}){src_tag}")
        lines.append("")
    return "\n".join(lines).strip()

# ─── Main ───
def main():
    print("⏳  Fetching news for", len(TICKERS), "tickers …", file=sys.stderr)

    seen_global = load_seen()
    new_global = set()
    items_by_ticker = defaultdict(list)

    for ticker in TICKERS:
        items = fetch_ticker_news(ticker)
        fresh = [it for it in items if it["link"] not in seen_global]
        for it in fresh:
            new_global.add(it["link"])
        items_by_ticker[ticker] = fresh
        print(f"  {ticker}: {len(fresh)} new", file=sys.stderr)

    output = format_digest(items_by_ticker)

    save_seen(new_global)

    print(output)
    total = sum(len(v) for v in items_by_ticker.values())
    print(f"\n✅  Total fresh headlines: {total}", file=sys.stderr)

if __name__ == "__main__":
    main()
