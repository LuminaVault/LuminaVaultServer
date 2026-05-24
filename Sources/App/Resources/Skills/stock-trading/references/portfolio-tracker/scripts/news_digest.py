#!/usr/bin/env python3
"""
StockPlan News Digest — standalone, twice-daily (runs on Hermes host, posts to Discord).
Covers: NBA (Spurs), Football/Soccer (Benfica, Milan, Liverpool, Napoli, Bayern), Politics, Tech, AI, Swift, SwiftUI, Golang, iOS dev,
Software Development, and specific stocks/tickers (ABCL, ZETA, AMD, OSCR, ONDS, KRKNF, HIMS,
SMR, FLNC, SP500) plus "hot", "trendy", "beaten down", "rebound" movers.

Pure Python stdlib only. No external deps. Two runs per day (09:00 and 17:00 UTC).
"""

import urllib.request, sys, os, re, html
from datetime import datetime, timezone

# ── Networking helpers ──────────────────────────────────────────────────────────
def fetch(url, timeout=12):
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")

# ── HTML / XML cleaning ────────────────────────────────────────────────────────
def clean_text(s):
    if not s:
        return ""
    s = s.strip()
    # Strip CDATA wrapper
    if s.startswith("<![CDATA[") and s.endswith("]]>"):
        s = s[9:-3]
    s = html.unescape(s)
    s = re.sub(r"<[^>]+>", "", s)       # remove tags
    s = re.sub(r"\s+", " ", s).strip()  # collapse whitespace
    return s

def parse_rss_items(raw):
    items = []
    for block in raw.split("</item>"):
        t = re.search(r"<title[^>]*>(.*?)</title>", block, re.I | re.S)
        l = re.search(r"<link[^>]*>(.*?)</link>", block, re.I | re.S)
        if t and l:
            title = clean_text(t.group(1))
            link  = clean_text(l.group(1))
            if not title or not link:
                continue
            # Skip channel-intro items from Google News feeds (title or link based)
            if title.lower().startswith("google news") or "news.google.com/search" in link:
                continue
            items.append({"title": title, "link": link})
    return items

# ── Keyword scoring ─────────────────────────────────────────────────────────────
CATEGORY_KEYWORDS = {
    "NBA":               [r"nba", r"basketball", r"playoffs", r"nba.com", r"warriors", r"lakers",
                          r"celtics", r"nuggets", r"heat", r"bucks", r"jokic", r"lebron", r"curry"],
    "Football":          [r"nfl", r"football", r"quarterback", r"super bowl", r"draft", r"touchdown",
                          r"chiefs", r"eagles", r"cowboys", r"packers", r"patrick mahomes"],
    "SL Benfica":        [r"\bbenfica\b", r"sl benfica", r" sport Lisboa ", r"benfiquista",
                          r"Águia", r"Estádio da Luz"],

    "San Antonio Spurs":   [r"san antonio spurs", r"spurs nba", r"victor wembanyama", r"wembanyama", r"kawhi leonard",
                          r"coach popovich", r"gregg popovich"],
    "AC Milan":            [r"ac milan", r"acmilan", r"rossoneri", r"san siro", r"milan serie a",
                          r"milan fc", r"acm official", r"paulo foulkes", r"simone inzaghi"],
    "Liverpool FC":        [r"liverpool", r"liverpool fc", r"lfc", r"anfield", r"jurgen klopp", r"arne slot"],
    "SSC Napoli":          [r"napoli", r"ssc napoli", r"napoli fc", r"partenopei", r"stadio san paolo"],
    "Bayern Munich":       [r"bayern", r"bayern munich", r"fc bayern", r"borussia bayern", r"allianz arena", r"bundesliga"],
    "Politics":          [r"politics", r"congress", r"senate", r"president", r"election", r"democrat",
                          r"republican", r"white house", r"capitol", r"biden", r"trump", r"policy"],
    "Tech":              [r"tech", r"technology", r"iphone", r"ipad", r"mac", r"apple", r"google",
                          r"microsoft", r"samsung", r"android", r"chip", r"semiconductor", r"hardware"],
    "AI":                [r"artificial intelligence", r"ai", r"machine learning", r"llm", r"gpt",
                          r"openai", r"anthropic", r"claude", r"stable diffusion", r"midjourney",
                          r"deep learning", r"neural", r"transformers"],
    "Swift":             [r"swift\b", r"swift.org", r"apple swift", r"swift language"],
    "SwiftUI":           [r"swiftui\b", r"swift ui", r"apple ui", r"ios ui"],
    "Golang":            [r"\bgolang\b", r"\bgo\b(?!ogle)", r"golang", r"go language", r"go programming"],
    "iOS development":   [r"ios\b", r"ipados", r"xcode", r"app store", r"ios developer", r"ios dev",
                          r"ios development", r"iphone app", r"ios app"],
    "Software Development": [r"software development", r"software engineering", r"programming",
                              r"coding", r"developer", r"engineering", r"full-stack", r"backend",
                          r"frontend", r"devops", r"code review", r"debugging"],
    "Stocks":            [r"\bapple\b", r"\bgoogle\b", r"\bamzn\b", r"\bmsft\b", r"\bnvda\b",
                          r"\bmeta\b", r"\btesla\b", r"\bpltr\b", r"\bsnow\b"],
    "ABCL":              [r"\bABCL\b", r"ABCL stock", r"ABC Logistics"],
    "ZETA":              [r"\bZETA\b", r"ZETA stock", r"Zeta Global", r"Zeta"],
    "AMD":               [r"\bAMD\b", r"AMD stock", r"Advanced Micro Devices"],
    "OSCR":              [r"\bOSCR\b", r"OSCR stock", r"Oscar Health"],
    "ONDS":              [r"\bONDS\b", r"ONDS stock", r"Oncolytics", r"Oncolys"],
    "KRKNF":             [r"\bKRKNF\b", r"KRKNF stock", r"Karikas"],
    "HIMS":              [r"\bHIMS\b", r"HIMS stock", r"Hims", r"Hims & Hers"],
    "SMR":               [r"\bSMR\b", r"SMR stock", r"NanoNuclear", r"Nuclear Energy"],
    "FLNC":              [r"\bFLNC\b", r"FLNC stock", r"Fluence"],
    "SP500":             [r"\bSPX\b", r"\bSP500\b", r"S&P 500", r"S&P500"],
    "Hot / Trendy":      [r"hot stock", r"trendy stock", r"trending", r"meme stock", r"popular"],
    "Beaten Down / Rebound": [r"beaten down", r"oversold", r"rebound", r"recovery",
                                r"bounce back", r"undervalued", r"bottomed"],
}

# ── RSS source definitions ─────────────────────────────────────────────────────
SOURCES = [
    # ── Sports ──────────────────────────────────────────────────────────────────
    {
        "name":   "NBA.com News",
        "url":    "https://www.nba.com/news/feeds/latest/news?format=rss",
        "cat":    ["NBA"],
    },
    {
        "name":   "SportingNews (US)",
        "url":    "https://www.sportingnews.com/us/rss",
        "cat":    ["NBA", "Football"],
    },
    # Football (use general sports RSS that carries NFL/Football too)
    {
        "name":   "CBS Sports Headlines",
        "url":    "https://www.cbssports.com/rss/headlines/",
        "cat":    ["Football"],
    },
    # ── SL Benfica (Google News search RSS) ────────────────────────────────────
    {
        "name":   "Google News — SL Benfica",
        "url":    "https://news.google.com/rss/search?q=SL+Benfica&hl=en-US&gl=US&ceid=US:en",
        "cat":    ["SL Benfica"],
    },
    # ── San Antonio Spurs (NBA) ──────────────────────────────────────────────────
    {
        "name":   "Google News — San Antonio Spurs",
        "url":    "https://news.google.com/rss/search?q=San+Antonio+Spurs&hl=en-US&gl=US&ceid=US:en",
        "cat":    ["San Antonio Spurs"],
    },
    # ── AC Milan ─────────────────────────────────────────────────────────────────
    {
        "name":   "Google News — AC Milan",
        "url":    "https://news.google.com/rss/search?q=AC+Milan&hl=en-US&gl=US&ceid=US:en",
        "cat":    ["AC Milan"],
    },
    # ── Liverpool FC ─────────────────────────────────────────────────────────────
    {
        "name":   "Google News — Liverpool FC",
        "url":    "https://news.google.com/rss/search?q=Liverpool+FC&hl=en-US&gl=US&ceid=US:en",
        "cat":    ["Liverpool FC"],
    },
    # ── SSC Napoli ───────────────────────────────────────────────────────────────
    {
        "name":   "Google News — SSC Napoli",
        "url":    "https://news.google.com/rss/search?q=SSC+Napoli&hl=en-US&gl=US&ceid=US:en",
        "cat":    ["SSC Napoli"],
    },
    # ── Bayern Munich ─────────────────────────────────────────────────────────────
    {
        "name":   "Google News — Bayern Munich",
        "url":    "https://news.google.com/rss/search?q=Bayern+Munich&hl=en-US&gl=US&ceid=US:en",
        "cat":    ["Bayern Munich"],
    },
    # ── Politics ────────────────────────────────────────────────────────────────
    {
        "name":   "Google News — Politics",
        "url":    "https://news.google.com/rss/search?q=politics+US&hl=en-US&gl=US&ceid=US:en",
        "cat":    ["Politics"],
    },
    # ── Tech & AI ───────────────────────────────────────────────────────────────
    {
        "name":   "The Verge — Tech",
        "url":    "https://www.theverge.com/rss/index.xml",
        "cat":    ["Tech"],
    },
    {
        "name":   "Ars Technica",
        "url":    "https://arstechnica.com/feed/",
        "cat":    ["Tech"],
    },
    {
        "name":   "AI News",
        "url":    "https://www.artificialintelligence-news.com/feed/",
        "cat":    ["AI"],
    },
    # ── Swift / SwiftUI ─────────────────────────────────────────────────────────
    {
        "name":   "Apple Developer News",
        "url":    "https://developer.apple.com/news/rss/news.rss",
        "cat":    ["Swift", "SwiftUI", "iOS development"],
    },
    {
        "name":   "Swift.org Blog",
        "url":    "https://swift.org/feed/",
        "cat":    ["Swift"],
    },
    {
        "name":   "Kodeco (RayWenderlich)",
        "url":    "https://www.kodeco.com/feed/rss",
        "cat":    ["Swift", "SwiftUI", "iOS development"],
    },
    # ── Golang ──────────────────────────────────────────────────────────────────
    {
        "name":   "Go Blog (golang.org)",
        "url":    "https://go.dev/blog/feed.atom",
        "cat":    ["Golang"],
    },
    # ── Software Development ───────────────────────────────────────────────────
    {
        "name":   "Dev.to — Programming",
        "url":    "https://dev.to/feed/tag/programming",
        "cat":    ["Software Development"],
    },
    {
        "name":   "GitHub Blog",
        "url":    "https://github.blog/feed/",
        "cat":    ["Software Development"],
    },
    {
        "name":   "StackOverflow Blog",
        "url":    "https://stackoverflow.blog/feed/",
        "cat":    ["Software Development", "Tech"],
    },
    # ── Stocks ──────────────────────────────────────────────────────────────────
    {
        "name":   "Google News — Stocks & Markets",
        "url":    "https://news.google.com/rss/search?q=stock+market+US&hl=en-US&gl=US&ceid=US:en",
        "cat":    ["Stocks"],
    },
]
# ────────────────────────────────────────────────────────────────────────────────

def score_item(title, link=""):
    """Return (best_category, match_count).  If no keywords match → (None, 0)."""
    title_lower = title.lower()
    best_cat, best_count = None, 0
    for cat, patterns in CATEGORY_KEYWORDS.items():
        count = sum(1 for p in patterns if re.search(p, title_lower, re.I))
        if count > best_count:
            best_cat, best_count = cat, count
    return (best_cat if best_count > 0 else None), best_count

def classify_link(link_lower):
    """Quick path: if URL contains a ticker, assign that category immediately."""
    for cat in ["ABCL", "ZETA", "AMD", "OSCR", "ONDS", "KRKNF", "HIMS", "SMR", "FLNC", "SP500"]:
        if cat.lower() in link_lower:
            return cat
    return None

def fetch_all_items():
    all_items = []
    errors = []
    for src in SOURCES:
        try:
            raw = fetch(src["url"])
            items = parse_rss_items(raw)
            for it in items:
                it["source"] = src["name"]
                it["src_cats"] = src["cat"]
            all_items.extend(items)
        except Exception as e:
            errors.append(f"{src['name']}: {e}")
    return all_items, errors

def dedupe(items):
    seen_links = set()
    uniq = []
    for it in items:
        if it["link"] not in seen_links:
            seen_links.add(it["link"])
            uniq.append(it)
    return uniq

def truncate_title(text, limit=80):
    """Truncate title at word boundary to fit limit, appending ellipsis if truncated."""
    if len(text) <= limit:
        return text
    cutoff = text[:limit].rfind(' ')
    if cutoff == -1 or cutoff < limit // 2:  # no space or very early space → hard cut
        return text[:limit] + "…"
    return text[:cutoff] + "…"

def build_markdown_output(items, total_scored=None):
    """Group items by category and return formatted markdown for Telegram delivery."""
    from collections import defaultdict
    buckets = defaultdict(list)
    for it in items:
        cat, count = score_item(it["title"], it["link"])
        if not cat:
            cat = classify_link(it["link"].lower())
        if not cat:
            cat = "Other"
        buckets[cat].append(it)

    # ────────────────────────────────────────────────────────────────────────────────
    # TELEGRAM-FRIENDLY: Ultra-compact format (<4000 chars).
    #  - Only core categories: Tech, AI, Swift, iOS dev, Software Dev, Politics
    #  - Max 2 items per category
    #  - Titles truncated to 80 chars
    #  - Bold category headers inline
    # ────────────────────────────────────────────────────────────────────────────────
    priority_categories = ["Tech", "AI", "Swift", "iOS development", "Software Development", "Politics"]
    
    lines = []
    lines.append(f"# 📰 Tech News Digest")
    lines.append(f"**Generated:** {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
    lines.append("")

    total_shown = 0
    categories_with_items = 0
    
    for cat in priority_categories:
        items_ = buckets.get(cat, [])
        if not items_:
            continue
        categories_with_items += 1
        shown = items_[:2]
        total_shown += len(shown)
        lines.append(f"**{cat}** ({len(shown)}/{len(items_)})")
        for it in shown:
            title = truncate_title(it["title"][:120], 80)  # apply smart truncation
            link = it["link"]
            lines.append(f"• {title}")
            lines.append(f"  {link}")
        if len(items_) > 2:
            lines.append(f"  _…+{len(items_) - 2} more_")
        lines.append("")

    lines.append(f"**Summary:** {total_shown} items across {categories_with_items} topics.")
    if total_scored is not None:
        lines.append(f"_Total items fetched: {total_scored}_")
    
    return "\n".join(lines).strip()

def main():
    print("⏳  Fetching news sources …", file=sys.stderr)
    items, errors = fetch_all_items()
    if errors:
        print("⚠  Source errors:", file=sys.stderr)
        for e in errors:
            print("   -", e, file=sys.stderr)

    print(f"✅  Fetched {len(items)} raw items", file=sys.stderr)
    uniq = dedupe(items)
    print(f"✅  Unique items: {len(uniq)}", file=sys.stderr)

    # Score + classify
    scored = []
    for it in uniq:
        cat, count = score_item(it["title"], it["link"])
        if not cat:
            cat = classify_link(it["link"].lower()) or "Other"
        it["_cat"] = cat
        it["_score"] = count
        scored.append(it)

    # Build output (markdown for Telegram delivery)
    output = build_markdown_output(scored, total_scored=len(scored))

    # Print stats to stderr (won't go to Telegram)
    print("\n" + "="*60 + "\n", file=sys.stderr)
    
    # Count categories for stats
    from collections import defaultdict
    stat_buckets = defaultdict(list)
    for it in scored:
        stat_buckets[it["_cat"]].append(it)
    
    print(f"✅  Digest generated: {len(scored)} items, {len(stat_buckets)} categories", file=sys.stderr)

    # Output markdown digest to stdout (Hermes cron delivers this to Telegram home)
    print(output)

if __name__ == "__main__":
    main()
