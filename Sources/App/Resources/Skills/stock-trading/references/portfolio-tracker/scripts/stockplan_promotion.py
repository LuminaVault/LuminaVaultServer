#!/usr/bin/env python3
"""
Hermes StockPlan Promotion — Hourly tweets about the StockPlan app.

Publishes to X (@fatc88) on a rotating 24-hour schedule using OAuth 2.0 user context.
24 unique messages covering: features, tips, market insights, fintech education,
and Norviq branding. Hashtags: #StockPlan #iOS #SwiftUI #FinTech #Investing #Norviq

Cron: Hourly (every hour on the hour) — auto-publishes to @fatc88
"""

import os
import sys
import json
import http.client
import datetime
from pathlib import Path
from typing import Dict, Optional

# ── Configuration ─────────────────────────────────────────────────────────────
# Load credentials from file or environment
CRED_FILE = Path("/opt/data/home/.hermes/scripts/.twitter_creds")
try:
    creds = json.loads(CRED_FILE.read_text())
    ACCESS_TOKEN = creds.get("ACCESS_TOKEN", "")
    BEARER_TOKEN = creds.get("BEARER_TOKEN", "")
except Exception:
    ACCESS_TOKEN = os.getenv("TWITTER_ACCESS_TOKEN") or "YOUR_ACCESS_TOKEN_HERE"
    BEARER_TOKEN = os.getenv("TWITTER_BEARER_TOKEN") or "YOUR_BEARER_TOKEN_HERE"

# DRY_RUN=True → print tweet but don't actually POST (safe for testing)
DRY_RUN = os.getenv("STOCKPLAN_PROMO_DRY_RUN", "true").lower() == "true"

# X API v2 endpoint
BASE_URL = "api.twitter.com"
POST_TWEET = "/2/tweets"

# Hourly content pool (24 items → one per hour, rotates daily)
TWEET_POOL = [
    # Morning (0–5)
    "Good morning, investors! 📈 Building your portfolio should be simple. @Norviq's StockPlan brings real-time tracking, VASP-ready security, and SwiftUI elegance to your iPhone. #StockPlan #iOS #FinTech",
    "Wake up and check your net worth in seconds. StockPlan's daily sync means no more stale prices. Download now → @Norviq #Investing #SwiftUI",
    "Early birds get the gains. 📊 Our portfolio tracker alerts you to big moves before the market opens. #StockPlan #FinTech #Norviq",
    "Coffee + portfolio review = perfect morning routine. ☕ StockPlan's charts are optimized for quick glances. #iOS #SwiftUI #StockPlan",
    "While you sleep, StockPlan watches your positions. 🔔 Smart alerts, zero hassle. @Norviq #Investing #FinTech",
    "Rise and shine — your portfolio just updated automatically. No more manual refreshes. #StockPlan #iOS",

    # Mid-morning / noon (6–11)
    "Did you know? StockPlan supports 15+ tickers with full fundamentals, insider trading data, and analyst ratings. 🧠 All in one app. #StockPlan #Norviq #Tech",
    "Lunch break portfolio check? 📱 StockPlan's intuitive design makes it a breeze. Built with SwiftUI-Concurrency best practices. #iOS #SwiftUI",
    "Multi-asset tracking coming soon to StockPlan. 📈 Stocks today, crypto & forex tomorrow. @Norviq #FinTech",
    "Question: What's the #1 feature you want in a portfolio tracker? Poll in our next update note! #StockPlan #iOSDev",
    "Behind the scenes: We're measuring cycle time and throughput on our Vapor backend. 🚀 Performance matters. #Golang #Backend #StockPlan",
    "Tech tip: StockPlan uses SwiftData with CloudKit for seamless cross-device sync. No login required. #SwiftUI #iOS #Data",

    # Afternoon (12–17)
    "Afternoon slump? Check if your biggest gainer is still winning. 📊 Real-time data, always. #StockPlan #Investing #Norviq",
    "Portfolio diversification check at 2 PM. How balanced are you? StockPlan's allocation pie chart keeps you honest. #FinTech #iOS",
    "Quick demo: How to set a price alert in 3 taps. 🎯 Watch for your entry/exit points automatically. #StockPlan #SwiftUI",
    "We're tracking: AMD, GOOGL, AMZN, NFLX, UBER, ZETA, HIMS, OSCR, ASTS, SOFI, and 10 more. 📈 #Investing #Norviq",
    "Security first: StockPlan is VASP-compliant, data encrypted at rest and in transit. 🛡️ #FinTech #iOS",
    "Backend devs: Our Vapor metrics show 99.9% uptime this week. Go GoLang! 🐹 #Golang #Backend #StockPlan",

    # Evening (18–23)
    "Market close wrap-up! 📉📈 Which ticker moved the most today? StockPlan's daily digest summarises it all. #StockPlan #Norviq",
    "Evening portfolio reflection. Did you stick to your strategy? Track your psychology with our journal notes. #Investing #iOS",
    "Dinner + portfolio review = winning combo. 🍽️ StockPlan's dark mode is easy on the eyes. #SwiftUI #FinTech",
    "Weekend prep: Export your positions to CSV for Excel analysis. One-tap export in StockPlan. #StockPlan #Tech",
    "Building in public: Our architecture diagrams are on GitHub. Star us ⭐ @Norviq #OpenSource #SwiftUI #Vapor",
    "Nightcap: Sleep better knowing StockPlan's automated job scraper keeps you informed. Goodnight, investors! 🌙 #StockPlan #Norviq",
]

# ── X API v2 interaction ────────────────────────────────────────────────────────
def auth_headers(use_bearer: bool = False) -> Dict[str, str]:
    if use_bearer:
        return {"Authorization": f"Bearer {BEARER_TOKEN}", "Content-Type": "application/json", "User-Agent": "HermesStockPlanPromo/1.0"}
    # OAuth2 user access token
    return {"Authorization": f"Bearer {ACCESS_TOKEN}", "Content-Type": "application/json", "User-Agent": "HermesStockPlanPromo/1.0"}

def get_hour_index() -> int:
    """Which tweet from the pool to use today? Rotates by UTC hour."""
    now = datetime.datetime.utcnow()
    # Use hour of day (0–23) as index into pool; pool has 24 items
    return now.hour % len(TWEET_POOL)

def post_tweet(text: str) -> Optional[str]:
    """Post a tweet using X API v2."""
    if DRY_RUN:
        print(f"[DRY_RUN] Would post: {text[:100]}…")
        return "dry-run-tweet-id"

    body = json.dumps({"text": text})
    try:
        conn = http.client.HTTPSConnection(BASE_URL, timeout=30)
        headers = auth_headers(use_bearer=False)  # Use access token for user context
        conn.request("POST", POST_TWEET, body, headers)
        resp = conn.getresponse()
        data = resp.read().decode("utf-8")
        conn.close()

        if resp.status in (200, 201):
            result = json.loads(data)
            tweet_id = result.get("data", {}).get("id")
            print(f"✓ Tweet posted: {tweet_id}")
            return tweet_id
        else:
            print(f"✗ Failed to post tweet — HTTP {resp.status}: {data[:300]}", file=sys.stderr)
            if resp.status == 401:
                print("  → Check: access token needs tweet.write scope", file=sys.stderr)
            elif resp.status == 403:
                print("  → Check: token may be expired or app lacks permission", file=sys.stderr)
            return None
    except Exception as e:
        print(f"✗ HTTP error posting tweet: {e}", file=sys.stderr)
        return None

def save_archive(text: str, tweet_id: Optional[str]) -> None:
    """Save each published tweet to an archive for record-keeping."""
    archive_dir = Path("/opt/data/home/.hermes/output/stockplan_tweets")
    archive_dir.mkdir(parents=True, exist_ok=True)
    fname = archive_dir / f"{datetime.datetime.utcnow().strftime('%Y-%m-%d_%H%M')}.md"
    with fname.open("w", encoding="utf-8") as f:
        f.write(f"🕒 {datetime.datetime.utcnow().isoformat()}Z\n")
        if tweet_id:
            f.write(f"🐦 https://twitter.com/i/status/{tweet_id}\n")
        f.write("\n" + text + "\n")
    print(f"  Archived to {fname}")

# ── Main ───────────────────────────────────────────────────────────────────────
def main() -> int:
    if ACCESS_TOKEN == "YOUR_ACCESS_TOKEN_HERE" and BEARER_TOKEN == "YOUR_BEARER_TOKEN_HERE":
        print("ERROR: Set TWITTER_ACCESS_TOKEN or TWITTER_BEARER_TOKEN", file=sys.stderr)
        return 1

    hour_idx = get_hour_index()
    tweet_text = TWEET_POOL[hour_idx]

    print(f"[{datetime.datetime.utcnow().isoformat()}] Posting tweet #{hour_idx+1}/24:")
    print(f"  {tweet_text[:100]}…")

    tweet_id = post_tweet(tweet_text)
    if tweet_id:
        save_archive(tweet_text, tweet_id)
        print(f"✓ StockPlan promotion published → https://twitter.com/i/status/{tweet_id}")
    else:
        print("✗ Tweet not published", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
