#!/usr/bin/env python3
"""
Daily Cinema Chatter — current theatrical releases + social buzz
Sources:
  - Wikipedia "2026 in film" (highest-grossing → now playing)
  - Reddit r/movies RSS search
  - Reddit r/boxoffice RSS search
  - Google News RSS
"""

import os, re, json, sys, datetime, urllib.request, html
from collections import Counter

HERMES_DIR = os.path.expanduser("~/.hermes")
LOG_PATH = os.path.join(HERMES_DIR, "logs", "movie_chatter.log")

def log(msg):
    ts = datetime.datetime.now().strftime("[%Y-%m-%d %H:%M:%S]")
    line = f"{ts} {msg}"
    print(line)
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    with open(LOG_PATH, "a") as f:
        f.write(line + "\n")

# ── Source 1: Wikipedia 2026 highest-grossing films ───────────────────────────
def fetch_wikipedia_movies():
    """Parse wikitable from '2026 in film' page, return list of movie dicts"""
    url = "https://en.wikipedia.org/wiki/2026_in_film"
    req = urllib.request.Request(url, headers={"User-Agent": "HermesBot/1.0"})
    with urllib.request.urlopen(req, timeout=15) as r:
        raw = r.read().decode("utf-8", errors="replace")
    
    # Locate the highest-grossing films table
    table_match = re.search(r'<table class="wikitable[^"]*">(.*?)</table>', raw, re.DOTALL)
    if not table_match:
        log("⚠  Wikipedia: no wikitable found")
        return []
    
    table = table_match.group(1)
    rows = re.findall(r'<tr>(.*?)</tr>', table, re.DOTALL)
    movies = []
    for row in rows[1:]:  # skip header
        cells = re.findall(r'<(?:t[hd])[^>]*>(.*?)</(?:t[hd])>', row, re.DOTALL)
        if len(cells) < 3:
            continue
        # Rank from first cell
        rank = re.sub(r'<[^>]+>', '', cells[0]).strip()
        # Title from second cell (extract link text)
        title_cell = cells[1]
        title_link = re.search(r'<a [^>]*?title="([^"]+)"[^>]*>', title_cell) or re.search(r'<a [^>]*>([^<]+)</a>', title_cell)
        if not title_link:
            continue
        title = html.unescape(title_link.group(1).strip())
        # Gross from first cell that contains a dollar sign
        gross = "N/A"
        for c in cells[2:]:
            txt = re.sub(r'<[^>]+>', '', c).strip()
            if '$' in txt:
                gross = txt
                break
        movies.append({"rank": rank, "title": title, "gross": gross})
    
    log(f"✓ Wikipedia: {len(movies)} movies from highest-grossing table")
    return movies

# ── Source 2: RSS feeds for buzz ───────────────────────────────────────────────
def fetch_reddit_titles(query, subreddit):
    """Return list of post titles from Reddit RSS search for query in given subreddit"""
    encoded = urllib.parse.quote_plus(query)
    url = f"https://www.reddit.com/r/{subreddit}/search.rss?q={encoded}&sort=new&restrict_sr=1"
    req = urllib.request.Request(url, headers={"User-Agent": "HermesBot/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            raw = r.read().decode("utf-8", errors="replace")
        entries = re.findall(r'<entry[^>]*>(.*?)</entry>', raw, re.DOTALL)
        titles = []
        for entry in entries[:3]:
            t_match = re.search(r'<title[^>]*>(.*?)</title>', entry, re.DOTALL)
            if t_match:
                raw_t = t_match.group(1)
                clean = re.sub(r'<[^>]+>', '', raw_t)
                clean = html.unescape(clean).strip()
                if clean:
                    titles.append(clean)
        return titles
    except Exception as e:
        log(f"  ⚠  Reddit r/{subreddit} RSS failed for '{query[:30]}': {e}")
        return []

def fetch_google_news_titles(query):
    """Return list of headlines from Google News RSS for query"""
    encoded = urllib.parse.quote_plus(query)
    url = f"https://news.google.com/rss/search?q={encoded}&hl=en-US&gl=US&ceid=US:en"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            raw = r.read().decode("utf-8", errors="replace")
        entries = re.findall(r'<entry[^>]*>(.*?)</entry>', raw, re.DOTALL)
        if not entries:
            entries = re.findall(r'<item[^>]*>(.*?)</item>', raw, re.DOTALL)
        titles = []
        for entry in entries[:4]:
            t_match = re.search(r'<title[^>]*>(.*?)</title>', entry, re.DOTALL)
            if t_match:
                raw_t = t_match.group(1)
                clean = re.sub(r'<[^>]+>', '', raw_t)
                clean = html.unescape(clean).strip()
                if clean:
                    titles.append(clean)
        return titles
    except Exception as e:
        log(f"  ⚠  Google News RSS failed for '{query[:30]}': {e}")
        return []



def get_buzz_for_movie(title):
    """Combine buzz snippets from multiple sources"""
    snippets = []
    
    # Reddit r/movies
    reddit_titles = fetch_reddit_titles(title, "movies")
    for t in reddit_titles:
        snippets.append(("[r/movies]", t))
    
    # Reddit r/boxoffice
    box_titles = fetch_reddit_titles(title, "boxoffice")
    for t in box_titles:
        snippets.append(("[r/boxoffice]", t))
    
    # Google News
    news_titles = fetch_google_news_titles(title)
    for t in news_titles:
        snippets.append(("[Google News]", t))
    
    if not snippets:
        snippets.append(("[N/A]", "No public discussion found"))
    return snippets[:8]

def build_digest(movies):
    today = datetime.date.today().strftime("%Y-%m-%d")
    lines = []
    lines.append(f"# 🎬 Daily Cinema Chatter — {today}")
    lines.append("*What's in theaters & what people are saying*")
    lines.append("")
    
    if not movies:
        lines.append("⚠️  No theatrical release data available today (Wikipedia fetch failed).")
        return "\n".join(lines)
    
    lines.append(f"## 📊 Now Playing — Top {len(movies)} Grossing Films")
    lines.append("")
    
    for i, m in enumerate(movies, 1):
        lines.append(f"### {i}. {m['title']}")
        lines.append(f"**Rank:** {m['rank']}  ·  **Gross:** {m['gross']}")
        lines.append("**Buzz:**")
        buzz = get_buzz_for_movie(m['title'])
        for src, text in buzz:
            lines.append(f"- *{src}* {text}")
        lines.append("")
    
    lines.append("---")
    lines.append(f"*Generated {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')} UTC*")
    lines.append("*Sources: Wikipedia (2026_in_film), Reddit RSS, Google News RSS*")
    return "\n".join(lines)

# ── Step 4: Deliver ────────────────────────────────────────────────────────────
def deliver(markdown):
    out_path = os.path.join(HERMES_DIR, "movie_digest_today.md")
    with open(out_path, "w") as f:
        f.write(markdown)
    log(f"✓ Digest saved ({len(markdown)} chars)")
    print("\n" + markdown)
    return out_path

def main():
    log("=== Daily Cinema Chatter started ===")
    
    movies = fetch_wikipedia_movies()
    log(f"→ {len(movies)} movies loaded")
    
    digest = build_digest(movies)
    out = deliver(digest)
    
    log(f"✓ Complete — {out}")

if __name__ == "__main__":
    main()
