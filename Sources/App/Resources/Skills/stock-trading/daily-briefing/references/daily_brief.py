#!/usr/bin/env python3
"""
Daily Morning Briefing — Comprehensive market intelligence for the AI cohort and portfolio.

Fetches:
- Major index prices (S&P 500, Nasdaq, Russell 2000, VIX)
- AI cohort performance (12 winners + 12 disrupted names)
- Top news headlines for key tickers

Pure stdlib implementation — no external dependencies.
"""

import argparse
import json
import os
import sys
import datetime
import http.client
import urllib.request
import urllib.parse
import urllib.error
import html
import re
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# ── Configuration ────────────────────────────────────────────────────────────
# Load environment variables from .env if present
env_path = Path("/opt/data/.env")
if env_path.exists():
    with env_path.open() as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, _, v = line.partition("=")
                if k and k not in os.environ:
                    os.environ[k] = v.strip()

# Constants
HERMES_HOME = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
PORTFOLIO_DIR = HERMES_HOME / "portfolio"
KG_ENTITIES_FILE = HERMES_HOME / "knowledge_graph" / "entities.json"

# Yahoo Finance ticker normalization
YAHOO_NORMALIZE = {
    "A6I": "A6I.F",
    # Add more as needed
}

# Major indices
INDICES = ["^GSPC", "^IXIC", "^RUT", "^VIX"]
INDEX_NAMES = {
    "^GSPC": "S&P 500",
    "^IXIC": "Nasdaq",
    "^RUT": "Russell 2000",
    "^VIX": "VIX",
}

# ─── Helper Functions ────────────────────────────────────────────────────────

def yahoo_price(ticker: str, logger=None) -> Optional[float]:
    """Fetch latest price from Yahoo Finance chart API."""
    yt = YAHOO_NORMALIZE.get(ticker, ticker)
    url_path = f"/v8/finance/chart/{yt}?range=1d&interval=1m"
    try:
        conn = http.client.HTTPSConnection("query1.finance.yahoo.com", timeout=15)
        conn.request("GET", url_path, headers={"User-Agent": "HermesDailyBrief/1.0"})
        resp = conn.getresponse()
        body = resp.read().decode("utf-8", errors="replace")
        conn.close()
        data = json.loads(body)
        result = data.get("chart", {}).get("result", [])
        if not result:
            return None
        meta = result[0].get("meta", {})
        price = meta.get("regularMarketPrice")
        if price is None:
            price = meta.get("chartPreviousClose")
        return float(price) if price is not None else None
    except Exception as e:
        if logger:
            print(f"⚠ Price fetch failed for {ticker}: {e}", file=sys.stderr)
        return None

def fetch_prices(tickers: List[str]) -> Dict[str, Optional[float]]:
    """Fetch prices for all tickers (sequentially). Returns dict ticker -> price or None."""
    prices = {}
    for ticker in tickers:
        prices[ticker] = yahoo_price(ticker)
    return prices

def parse_rss_items(raw: str, source_name: str) -> List[Dict]:
    """Parse RSS or Atom feed and return list of items with title, link, source."""
    items = []
    # RSS 2.0
    for block in re.split(r"</item>", raw, flags=re.IGNORECASE):
        t = re.search(r"<title[^>]*>(.*?)</title>", block, re.IGNORECASE | re.DOTALL)
        l = re.search(r"<link[^>]*>(.*?)</link>", block, re.IGNORECASE | re.DOTALL)
        if t and l:
            title = html.unescape(re.sub(r"<[^>]+>", " ", t.group(1))).strip()
            link = html.unescape(re.sub(r"<[^>]+>", " ", l.group(1))).strip()
            if title and link:
                items.append({"title": title, "link": link, "source": source_name})
    # Atom
    if not items:
        for block in re.split(r"</entry>", raw, flags=re.IGNORECASE):
            t = re.search(r"<title[^>]*>(.*?)</title>", block, re.IGNORECASE | re.DOTALL)
            l = re.search(r'<link[^>]*href=[\'"]([^\'"]+)[\'"]', block, re.IGNORECASE)
            if t and l:
                title = html.unescape(re.sub(r"<[^>]+>", " ", t.group(1))).strip()
                link = html.unescape(l.group(1).strip())
                if title and link:
                    items.append({"title": title, "link": link, "source": source_name})
    return items

def get_news_for_ticker(ticker: str) -> List[Dict]:
    """Fetch top 5 news headlines for a ticker using Yahoo Finance and Google News."""
    results = []
    seen = set()

    # Yahoo Finance feed
    yt = YAHOO_NORMALIZE.get(ticker, ticker)
    try:
        yf_url = f"https://feeds.finance.yahoo.com/rss/2.0/headline?s={urllib.parse.quote(yt)}&region=US&lang=en-US"
        raw = urllib.request.urlopen(yf_url, timeout=10).read().decode("utf-8", errors="replace")
        for it in parse_rss_items(raw, "Yahoo Finance"):
            if it["link"] not in seen:
                results.append(dict(it, ticker=ticker))
                seen.add(it["link"])
    except Exception as e:
        print(f"⚠ {ticker} Yahoo: {e}", file=sys.stderr)

    # Google News fallback (if less than 3 items)
    if len(results) < 3:
        try:
            q = urllib.parse.quote(f"{ticker} stock news")
            gn_url = f"https://news.google.com/rss/search?q={q}&hl=en-US&gl=US&ceid=US:en"
            raw = urllib.request.urlopen(gn_url, timeout=10).read().decode("utf-8", errors="replace")
            for it in parse_rss_items(raw, "Google News"):
                if it["link"] not in seen:
                    results.append(dict(it, ticker=ticker))
                    seen.add(it["link"])
        except Exception as e:
            print(f"⚠ {ticker} Google: {e}", file=sys.stderr)

    return results[:5]

def read_config_cohort() -> Tuple[List[str], List[str]]:
    """Read AI cohort from the scoreboard config file."""
    config_path = Path("/opt/data/scripts/ai-scoreboard/config.yaml")
    if not config_path.exists():
        return [], []
    content = config_path.read_text()
    winners = []
    disrupted = []
    in_winners = False
    in_disrupted = False
    for line in content.splitlines():
        line = line.strip()
        if line.startswith("winners:"):
            in_winners = True
            in_disrupted = False
            continue
        if line.startswith("disrupted:"):
            in_winners = False
            in_disrupted = True
            continue
        if in_winners and line.startswith("- "):
            winners.append(line[2:].strip())
        elif in_disrupted and line.startswith("- "):
            disrupted.append(line[2:].strip())
    return winners, disrupted

# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Daily Morning Briefing")
    parser.add_argument("--test", action="store_true", help="Simulate without sending alerts or updating state. Prints would-send messages.")
    args = parser.parse_args()

    print(f"⏳ Generating daily briefing...", file=sys.stderr)

    # 1. Get current UTC time and format
    now_utc = datetime.datetime.now(datetime.timezone.utc)
    now_et = now_utc.astimezone(datetime.timezone(datetime.timedelta(hours=-4)))  # EST/EDT
    date_str = now_et.strftime("%A, %B %d, %Y")
    time_str = now_et.strftime("%I:%M %p ET")

    # 2. Load AI cohort from config
    winners, disrupted = read_config_cohort()
    all_tickers = winners + disrupted

    # 3. Fetch prices for indices and cohort
    index_prices = fetch_prices(INDICES)
    cohort_prices = fetch_prices(all_tickers)

    # 4. Format index section
    index_lines = []
    for sym in INDICES:
        price = index_prices.get(sym)
        if not price:
            continue
        name = INDEX_NAMES.get(sym, sym)
        # For VIX, we don't have prev close easily, just show price
        if sym == "^VIX":
            index_lines.append(f"• {name}: {price:.2f}")
        else:
            index_lines.append(f"• {name}: {price:.2f}")

    # 5. Format cohort section
    cohort_lines = []
    for ticker in all_tickers[:6]:  # Show first 6, maybe limit to top 6
        price = cohort_prices.get(ticker)
        if price:
            cohort_lines.append(f"• {ticker}: ${price:.2f}")

    # 6. Fetch news headlines for top holdings
    news_items = []
    # Focus on a subset of tickers for news
    news_tickers = ["NVDA", "AMD", "MSFT", "GOOGL", "META", "AMZN", "TSLA", "AAPL"]  # Mix of cohort and major tech
    for ticker in news_tickers:
        items = get_news_for_ticker(ticker)
        for it in items[:2]:  # 2 headlines per ticker
            title = re.sub(r"<[^>]+>", "", it["title"])
            news_items.append(f"• {ticker}: {title} ([Link]({it['link']}))")

    # 7. Build the briefing
    briefing = f"""📈 **Daily Market Intelligence — {date_str} — {time_str} ET**

---

## 📊 Major Indices
{chr(10).join(index_lines)}

## 🤖 AI Cohort Leaders (Top 6)
{chr(10).join(cohort_lines)}

## 🗞️ Top Stories
{chr(10).join(news_items)}

---

*Generated by Hermes — Live market data via Yahoo Finance. News via RSS.*
"""

    # 8. Output to stdout (captured by Hermes for delivery)
    print(briefing)

    # 9. Log success
    print(f"✅ Daily briefing generated successfully for {len(all_tickers)} tickers.", file=sys.stderr)
    return 0

if __name__ == "__main__":
    sys.exit(main())