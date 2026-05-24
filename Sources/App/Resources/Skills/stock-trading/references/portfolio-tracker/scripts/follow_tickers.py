#!/usr/bin/env python3
"""
Stock Ticker X Monitor — Discover & follow accounts that post about your tickers.

For each ticker in TICKERS, fetches recent tweets (search), extracts unique authors,
ranks them by relevance (verified, follower count, tweet volume), and either:
  • dry-run (default): prints who you should follow
  --no-dry-run: actually follows them via xurl

Also builds a search query string you can use directly with `xurl search`.

Usage:
  python3 follow_tickers.py              # show suggestions
  python3 follow_tickers.py --execute    # actually follow accounts
  python3 follow_tickers.py --query      # output ready-to-copy xurl search string
  python3 follow_tickers.py --digest     # show recent tweets per ticker
"""

import json, subprocess, re, os
from collections import defaultdict

# ─── Configuration ──────────────────────────────────────────────────────────────
# All tickers you track (must match stock_threshold_alert.py keys for consistency)
TICKERS = [
    "ZETA", "AMD", "AMZN", "HIMS", "OSCR", "SOFI", "KRKNF", "ONDS",
    "ABCL", "GRAB", "ASTS", "TE", "UBER", "NFLX", "NVO", "NKE", "SIDU",
    "SMR", "FLNC", "RDW",
]

# Tickers with cashtag prefix ($) — Twitter/X treats these specially
# Most stock tickers work both plain ($AMD) and keyword (#AMD), use both
CASHTAG_PREFIX = True   # prepend $ in search: "$AMD"

# Search parameters
SEARCH_RESULTS_PER_TICKER = 20   # tweets to sample per ticker
MIN_FOLLOWER_COUNT      = 1000   # ignore very-small accounts
MAX_FOLLOW_SUGGESTIONS  = 5      # top N per ticker to suggest

# xurl binary path (installed)
XURL_BIN = os.path.expanduser("~/.local/bin/xurl")

# ─── Helpers ────────────────────────────────────────────────────────────────────

def xurl_search(query: str, n: int = 20):
    """Return list of tweet dicts for a search query."""
    cmd = [XURL_BIN, "search", query, "-n", str(n)]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            # Credits depleted or rate-limited — return empty
            try:
                err = json.loads(result.stdout)
                if "CreditsDepleted" in str(err):
                    print(f"  ⚠ Credits depleted — cannot fetch tweets for '{query}'")
            except:
                pass
            return []
        data = json.loads(result.stdout)
        return data.get("data", [])
    except Exception as e:
        print(f"  ✗ Search error: {e}")
        return []


def xurl_whoami():
    """Return authenticated user info."""
    result = subprocess.run([XURL_BIN, "whoami"], capture_output=True, text=True, timeout=10)
    if result.returncode == 0:
        return json.loads(result.stdout).get("data", {})
    return None


def xurl_follow(username: str, dry_run: bool = True) -> bool:
    """Follow a user (via xurl). Returns success bool."""
    if dry_run:
        return True
    result = subprocess.run([XURL_BIN, "follow", username],
                           capture_output=True, text=True, timeout=15)
    return result.returncode == 0


# ─── Main ───────────────────────────────────────────────────────────────────────

def main():
    import argparse
    parser = argparse.ArgumentParser(description="X ticker follow assistant")
    parser.add_argument("--execute", action="store_true",
                        help="Actually follow suggested accounts (default: dry-run)")
    parser.add_argument("--query", action="store_true",
                        help="Print a combined xurl search query for all tickers")
    parser.add_argument("--digest", action="store_true",
                        help="Show recent tweets per ticker instead of follow suggestions")
    parser.add_argument("--max-tweets", type=int, default=10,
                        help="Tweets per ticker for digest (default: 10)")
    args = parser.parse_args()

    me = xurl_whoami()
    if not me:
        print("✗ Cannot authenticate — run `xurl auth status` to verify")
        return 1
    print(f"✓ Authenticated as @{me.get('username')} ({me.get('id')})\n")

    if args.query:
        # Build single search string: ($AMD OR $GOOGL OR ...) -filter:retweets
        terms = [f"${t}" for t in TICKERS] if CASHTAG_PREFIX else TICKERS
        query = " OR ".join(terms) + " -filter:retweets"
        print(" === COPY-PASTE THIS XURL SEARCH === ")
        print(f"xurl search \"{query}\" -n 50")
        return 0

    if args.digest:
        # Show recent tweets per ticker
        for ticker in TICKERS:
            tag = f"${ticker}" if CASHTAG_PREFIX else ticker
            print(f"\n{'='*50}")
            print(f"  Recent tweets for {ticker} ({tag})")
            print(f"{'='*50}")
            tweets = xurl_search(tag, args.max_tweets)
            if not tweets:
                print("  (no tweets found or credits depleted)")
                continue
            for t in tweets[:args.max_tweets]:
                author = t.get("author", {})
                username = author.get("username", "unknown")
                text = t.get("text", "").replace("\n", " ")
                print(f"\n  @{username}: {text[:200]}")
                print(f"  ↳ https://x.com/{username}/status/{t.get('id')}")
        return 0

    # Normal mode: rank authors per ticker
    print("=== Scanning recent tweets for each ticker ===\n")
    ticker_authors = defaultdict(list)   # ticker -> list of author dicts

    for ticker in TICKERS:
        tag = f"${ticker}" if CASHTAG_PREFIX else ticker
        print(f"[{ticker:6s}] searching '{tag}' …")
        tweets = xurl_search(tag, SEARCH_RESULTS_PER_TICKER)
        if not tweets:
            print(f"         (0 tweets — credits?)\n")
            continue

        authors_seen = set()
        for t in tweets:
            author = t.get("author", {})
            uid = author.get("id")
            if not uid or uid in authors_seen:
                continue
            authors_seen.add(uid)
            ticker_authors[ticker].append({
                "id":       uid,
                "username": author.get("username", ""),
                "name":     author.get("name", ""),
                "verified": author.get("verified", False),
                "followers": author.get("public_metrics", {}).get("followers_count", 0),
                "tweets":   author.get("public_metrics", {}).get("tweet_count", 0),
            })
        print(f"         found {len(tickers:=ticker_authors[ticker])} unique authors\n")

    # Rank and print suggestions
    print("\n=== TOP ACCOUNTS TO FOLLOW (sorted by verified → followers) ===\n")
    suggestions = []
    for ticker, authors in ticker_authors.items():
        if not authors:
            continue
        # Rank: verified first, then followers, then tweet volume
        authors.sort(key=lambda a: (not a["verified"], -a["followers"], -a["tweets"]))
        top = authors[:MAX_FOLLOW_SUGGESTIONS]
        for a in top:
            if a["followers"] < MIN_FOLLOWER_COUNT:
                continue
            suggestions.append({
                "ticker": ticker,
                "username": a["username"],
                "name": a["name"],
                "verified": a["verified"],
                "followers": a["followers"],
            })

    if not suggestions:
        print("No qualifying accounts found. Try with lower MIN_FOLLOWER_COUNT or wait for credits.\n")
        return 0

    # Pretty print
    for s in suggestions:
        check = "✓" if s["verified"] else "○"
        print(f"  {check} @{s['username']:20s} {s['name'][:30]:30s} "
              f"({s['followers']:>6,} followers)  [{s['ticker']}]")

    dry = "(DRY-RUN — use --execute to actually follow)" if not args.execute else ""
    print(f"\nTotal unique accounts: {len({s['username'] for s in suggestions})}")
    print(f"Follow count per ticker capped at {MAX_FOLLOW_SUGGESTIONS}. {dry}")

    if args.execute:
        print("\n=== Following accounts ===")
        for s in suggestions:
            uname = s["username"]
            ok = xurl_follow(uname, dry_run=False)
            status = "✓ followed" if ok else "✗ failed"
            print(f"  {status}: @{uname}")
    else:
        print("\nTo follow these accounts, either:")
        print("  1. Re-run with --execute")
        print("  2. Manually run for each:")
        for s in suggestions:
            print(f"     xurl follow {s['username']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
