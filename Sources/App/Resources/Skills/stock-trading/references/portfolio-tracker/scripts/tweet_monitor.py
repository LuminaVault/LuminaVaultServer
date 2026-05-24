#!/usr/bin/env python3
"""
Hermes Tweet Monitor — Daily resume of tweets from @fatc88, their following list,
and keyword search. Filters topics: stocks, nba, sl benfica, tech, ai, swift, ios, golang.

Output: ~/.hermes/output/tweet_digest_YYYY-MM-DD.md
Cron: Daily 08:00 UTC → delivered to Discord/Telegram/Slack
"""

import os
import sys
import json
import time
import datetime
import http.client
from pathlib import Path
from typing import List, Dict, Optional

# ── Configuration ─────────────────────────────────────────────────────────────
# Load credentials from file or environment
CRED_FILE = Path("/opt/data/home/.hermes/scripts/.twitter_creds")
try:
    creds = json.loads(CRED_FILE.read_text())
    BEARER_TOKEN = creds.get("BEARER_TOKEN", "")
    ACCESS_TOKEN = creds.get("ACCESS_TOKEN", "")
except Exception:
    BEARER_TOKEN = os.getenv("TWITTER_BEARER_TOKEN") or "YOUR_BEARER_TOKEN_HERE"
    ACCESS_TOKEN = os.getenv("TWITTER_ACCESS_TOKEN") or "YOUR_ACCESS_TOKEN_HERE"

# Use user access token when available (user rate limits, not app credits)
AUTH_TOKEN = ACCESS_TOKEN if ACCESS_TOKEN and "YOUR_" not in ACCESS_TOKEN else BEARER_TOKEN
USE_USER_AUTH = bool(ACCESS_TOKEN and "YOUR_" not in ACCESS_TOKEN)

# Set FETCH_FOLLOWING=False to conserve API credits when app quota exhausted
FETCH_FOLLOWING = os.getenv("TWITTER_FETCH_FOLLOWING", "true").lower() == "true"
FOLLOWING_SAMPLE_SIZE = int(os.getenv("TWITTER_FOLLOWING_SAMPLE_SIZE", "30"))

# Topics to filter (OR logic across all sources)
TOPICS = ["stocks", "nba", "sl benfica", "tech", "ai", "swift", "ios", "golang"]

# Target user – whose timeline + following list we scan
TARGET_USERNAME = "fatc88"

# Output directory
OUTPUT_DIR = Path("/opt/data/home/.hermes/output")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# ── X API v2 endpoints ─────────────────────────────────────────────────────────
BASE_URL = "api.twitter.com"
USER_BY_USERNAME = "/2/users/by/username/{username}"
USER_TWEETS = "/2/users/{user_id}/tweets"
FOLLOWING = "/2/users/{user_id}/following"
SEARCH_RECENT = "/2/tweets/search/recent"

# Max results per page
PAGE_SIZE = 100

# ── HTTP helper with headers ───────────────────────────────────────────────────
def auth_headers() -> Dict[str, str]:
    token = ACCESS_TOKEN if USE_USER_AUTH else BEARER_TOKEN
    return {"Authorization": f"Bearer {token}", "User-Agent": "HermesTweetMonitor/1.0"}

def make_request(method: str, path: str, query_string: str = "", body: str = None) -> Dict:
    """Make HTTP request to X API v2 using http.client."""
    conn = http.client.HTTPSConnection(BASE_URL, timeout=30)
    headers = auth_headers()
    if body:
        headers["Content-Type"] = "application/json"

    full_url = path + (f"?{query_string}" if query_string else "")
    conn.request(method, full_url, body, headers)
    resp = conn.getresponse()
    data = resp.read().decode("utf-8")

    if resp.status not in (200, 201):
        print(f"HTTP {resp.status} on {method} {path}: {data[:300]}", file=sys.stderr)
        conn.close()
        return {"error": resp.status, "detail": data}

    conn.close()
    try:
        return json.loads(data)
    except json.JSONDecodeError:
        return {"raw": data}

# ── Fetch helpers ───────────────────────────────────────────────────────────────
def get_user_id(username: str) -> Optional[str]:
    """Resolve username to user ID."""
    resp = make_request("GET", USER_BY_USERNAME.format(username=username))
    if "data" in resp:
        return resp["data"]["id"]
    print(f"Could not resolve @{username}: {resp}", file=sys.stderr)
    return None

def fetch_paginated(path_template: str, user_id: str, params: Dict[str, str]) -> List[Dict]:
    """Fetch all pages from a paginated endpoint."""
    all_items = []
    page = path_template.format(user_id=user_id)
    query = "&".join(f"{k}={v}" for k, v in params.items())
    next_token = None

    while True:
        q = query + (f"&pagination_token={next_token}" if next_token else "")
        resp = make_request("GET", page, q)
        items = resp.get("data", [])
        if isinstance(items, list):
            all_items.extend(items)

        # Check for pagination
        meta = resp.get("meta", {})
        next_token = meta.get("next_token")
        if not next_token:
            break
        time.sleep(1)  # Gentle rate limit

    return all_items

def fetch_user_tweets(user_id: str, days_back: int = 2) -> List[Dict]:
    """Fetch recent tweets from a user."""
    since_iso = (datetime.datetime.utcnow() - datetime.timedelta(days=days_back)).isoformat() + "Z"
    tweets = fetch_paginated(
        USER_TWEETS,
        user_id,
        {
            "max_results": str(PAGE_SIZE),
            "tweet.fields": "id,text,created_at,public_metrics,author_id,referenced_tweets",
            "expansions": "author_id",
            "since": since_iso,
        },
    )
    # Attach author info if available
    return tweets

def fetch_following(user_id: str) -> List[str]:
    """Get list of user IDs that target_user follows."""
    following = fetch_paginated(
        FOLLOWING,
        user_id,
        {"max_results": "1000", "user.fields": "id,username,public_metrics"},
    )
    return [u["id"] for u in following if "id" in u]

def search_recent_tweets(query: str, max_per_query: int = 50) -> List[Dict]:
    """Search recent tweets by keyword. Spaces and special chars URL-encoded."""
    # Encode query for URL: replace spaces with %20, handle quotes
    encoded = query.replace(" ", "%20").replace('"', '%22')
    resp = make_request(
        "GET",
        SEARCH_RECENT,
        "",
        f"query={encoded}&max_results={max_per_query}&tweet.fields=id,text,created_at,public_metrics,author_id,referenced_tweets&expansions=author_id&user.fields=id,username",
    )
    if "data" in resp:
        return resp["data"]
    return []

def rank_tweets(tweets: List[Dict]) -> List[Dict]:
    """Rank tweets by engagement (likes+retweets+replies) and recency."""
    scored = []
    for t in tweets:
        metrics = t.get("public_metrics", {})
        score = metrics.get("like_count", 0) + metrics.get("retweet_count", 0) * 2 + metrics.get("reply_count", 0)
        scored.append({"score": score, "tweet": t, "created_at": t.get("created_at", "")})
    scored.sort(key=lambda x: (-x["score"], x["created_at"]))
    return [item["tweet"] for item in scored]

# ── Topic filtering ────────────────────────────────────────────────────────────
def matches_topics(text: str) -> bool:
    ltext = text.lower()
    return any(topic.lower() in ltext for topic in TOPICS)

# ── Formatting ─────────────────────────────────────────────────────────────────
def summarise_tweet(text: str, max_len: int = 200) -> str:
    """Truncate and clean tweet text for digest."""
    cleaned = text.replace("\n", " ").strip()
    if len(cleaned) > max_len:
        cleaned = cleaned[:max_len - 3] + "..."
    return cleaned

def format_digest(tweets_by_source: Dict[str, List[Dict]]) -> str:
    """Generate Markdown digest."""
    date_str = datetime.date.today().strftime("%A, %b %d, %Y")
    lines = [
        f"# 📊 Hermes Tweet Digest — {date_str}",
        f"_Monitoring @{TARGET_USERNAME} + following list — topics: {', '.join(TOPICS)}_",
        "",
    ]

    total = sum(len(v) for v in tweets_by_source.values())
    lines.append(f"**{total} tweet(s)** matched your interests today.\n")

    # Source sections
    for source, tweets in tweets_by_source.items():
        if not tweets:
            continue
        lines.append(f"## 📍 {source}")
        for t in tweets:
            author_id = t.get("author_id", "unknown")
            created = t.get("created_at", "")[:10]
            summary = summarise_tweet(t.get("text", ""))
            metrics = t.get("public_metrics", {})
            likes = metrics.get("like_count", 0)
            rt = metrics.get("retweet_count", 0)
            tweet_id = t.get("id", "")
            link = f"https://twitter.com/i/status/{tweet_id}" if tweet_id else "#"

            lines.append(f"- **@{author_id}** · {created} ❤️ {likes} 🔄 {rt}")
            lines.append(f"  > {summary}")
            lines.append(f"  [View tweet →]({link})")
            lines.append("")
        lines.append("---\n")

    lines.append("\n_Generated by Hermes Tweet Monitor_")
    return "\n".join(lines)

# ── Main pipeline ──────────────────────────────────────────────────────────────
def main() -> int:
    if BEARER_TOKEN == "YOUR_BEARER_TOKEN_HERE":
        print("ERROR: TWITTER_BEARER_TOKEN not set in script or environment", file=sys.stderr)
        return 1

    print(f"→ Fetching @{TARGET_USERNAME} user ID…")
    target_id = get_user_id(TARGET_USERNAME)
    if not target_id:
        return 1
    print(f"  Found user ID: {target_id}")

    tweets_by_source: Dict[str, List[Dict]] = {
        f"@{TARGET_USERNAME} (own)": [],
        "Following accounts": [],
        "Keyword search": [],
    }

    # 1. Fetch @fatc88's own recent tweets
    print("→ Fetching own tweets…")
    own_tweets = fetch_user_tweets(target_id, days_back=2)
    filtered = [t for t in own_tweets if matches_topics(t.get("text", ""))]
    tweets_by_source[f"@{TARGET_USERNAME} (own)"] = filtered[:25]
    print(f"  {len(filtered)}/{len(own_tweets)} match topics")

    # 2. Fetch following list + sample tweets from followed accounts
    if FETCH_FOLLOWING:
        print("→ Fetching following list…")
        following_ids = fetch_following(target_id)
        print(f"  Following {len(following_ids)} accounts")
    
        # Sample first N followed users for tweets (rate-limit safe)
        SAMPLE_SIZE = min(FOLLOWING_SAMPLE_SIZE, len(following_ids))
        following_tweets: List[Dict] = []
        for uid in following_ids[:SAMPLE_SIZE]:
            ut = fetch_user_tweets(uid, days_back=2)
            following_tweets.extend([t for t in ut if matches_topics(t.get("text", ""))])
            time.sleep(0.5)  # Rate-limit friendliness
        tweets_by_source["Following accounts"] = rank_tweets(following_tweets)[:25]
        print(f"  {len(tweets_by_source['Following accounts'])} from following")

    # 3. Keyword search across X (recent)
    print("→ Searching tweets by keywords…")
    keyword_tweets: List[Dict] = []
    for topic in TOPICS:
        qt = search_recent_tweets(topic, max_per_query=20)
        keyword_tweets.extend([t for t in qt if matches_topics(t.get("text", ""))])
    keyword_tweets = deduplicate_by_id(keyword_tweets)
    tweets_by_source["Keyword search"] = rank_tweets(keyword_tweets)[:30]
    print(f"  {len(tweets_by_source['Keyword search'])} from search")

    # 4. Rank within sources
    for src in tweets_by_source:
        tweets_by_source[src] = rank_tweets(tweets_by_source[src])

    # 5. Write digest
    date_str = datetime.date.today().strftime("%Y-%m-%d")
    outfile = OUTPUT_DIR / f"tweet_digest_{date_str}.md"
    digest_md = format_digest(tweets_by_source)
    outfile.write_text(digest_md, encoding="utf-8")
    print(f"✓ Written digest to {outfile}")

    # Also print preview for cron stdout
    print(digest_md[:2000])
    print(f"\n[Full digest: {outfile} — {sum(len(v) for v in tweets_by_source.values())} tweets]")
    return 0

def deduplicate_by_id(tweets: List[Dict]) -> List[Dict]:
    seen = set()
    uniq = []
    for t in tweets:
        tid = t.get("id")
        if tid and tid not in seen:
            seen.add(tid)
            uniq.append(t)
    return uniq

if __name__ == "__main__":
    sys.exit(main())
