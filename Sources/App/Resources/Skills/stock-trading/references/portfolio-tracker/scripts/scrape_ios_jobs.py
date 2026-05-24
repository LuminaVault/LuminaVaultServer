#!/usr/bin/env python3
"""
Daily iOS/Swift/Vapor Remote Job Aggregator
Sources: RemoteOK, Hacker News, WeWorkRemotely, Remotive API
Pure stdlib. Outputs Markdown + JSON.
"""

import re
import sys
import json
import xml.etree.ElementTree as ET
import urllib.request
import urllib.parse
from datetime import datetime
from pathlib import Path
from html import unescape
from html.parser import HTMLParser

# ─── Config ───
OUTPUT_DIR = Path.home() / ".cache" / "hermes" / "job_scrapes"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

REMOTEOK_TAGS = [
    "ios",
    "swift",
    "swiftui",
    "mobile",
    "architect",
    "xcode",
    #"all",  # Too broad — hundreds of results daily, slows scraper
]
HN_URL = "https://news.ycombinator.com/jobs"
WWR_URL = "https://weworkremotely.com/categories/remote-dev-jobs"
REMOTIVE_URL = "https://remotive.com/api/remote-jobs?category=software-dev"

# ─── Helpers ───
def clean_html(html):
    if not html:
        return ""
    text = re.sub(r'<[^>]+>', ' ', html)
    text = unescape(text)
    return re.sub(r'\s+', ' ', text).strip()[:500]


def score_job(title, tags=None):
    """0-10 relevance score. Threshold 3+."""
    s, r, t = 0, [], title.lower()
    tags = [tg.lower() for tg in (tags or [])]

    # Primary tech keywords in title
    if re.search(r'\bios\b|\biphone\b|\bipad\b', t):
        s += 4; r.append("iOS in title")
    if re.search(r'\bvapor\b', t):
        s += 3; r.append("Vapor")
    elif re.search(r'\bswift\b', t):
        s += 2; r.append("Swift")
    elif re.search(r'\bswiftui\b', t):
        s += 2; r.append("SwiftUI")

    # Architect bonus (if title or tags have architect + iOS/Swift context)
    if ('architect' in tags or re.search(r'\barchitect\b', t)) and re.search(r'\bios\b|\biphone\b|\bswift\b|\bswiftui\b', t):
        s += 2; r.append("iOS/Swift Architect")

    # Tag-based bonuses
    if 'ios' in tags:
        if not re.search(r'react native|interpreter|support agent|customer success|security researcher|threat intel|analyst|designer(?<!ios designer)|ui/ux|translator|consultant', t):
            s += 2 if s == 0 else 1; r.append("iOS tag")
    if 'swift' in tags and s < 2:
        s += 1; r.append("Swift tag")
    if 'swiftui' in tags and s < 2:
        s += 1; r.append("SwiftUI tag")
    if 'vapor' in tags and s < 3:
        s += 2; r.append("Vapor tag")

    # Mobile boost only when iOS also in tags/title
    if 'mobile' in tags and ('ios' in tags or re.search(r'\bios\b', t)):
        s += 1; r.append("Mobile+iOS")

    # Cross-platform penalties
    if re.search(r'React Native|Flutter|Kotlin Multiplatform|Xamarin|Ionic', title, re.I):
        s -= 3; r.append("Cross-platform penalty")

    # Android-only penalty
    if re.search(r'\bAndroid\b', title, re.I) and not re.search(r'\bios\b|\biphone\b', t):
        s -= 3; r.append("Android-only")

    # Non-dev blacklist
    non_dev = r'\b(designer(?!.*ios)|ui/ux|ux designer|visual designer|researcher|intelligence|analyst|customer success|support agent|translator|interpreter|consultant)\b'
    if re.search(non_dev, t, re.I) and not re.search(r'\bios\b|\biphone\b|\bswift\b|\bvapor\b', t):
        s = max(0, s - 5); r.append("Non-dev exclusion")

    # Remote bonus
    if 'remote' in tags or re.search(r'\bremote\b|\bremotely\b|\bdistributed\b', t):
        s += 1; r.append("Remote")

    return s, r


# ─── RemoteOK API ───
def fetch_remoteok():
    jobs = []
    for tag in REMOTEOK_TAGS:
        url = f"https://remoteok.com/api?tags={urllib.parse.quote(tag)}"
        try:
            req = urllib.request.Request(
                url,
                headers={"User-Agent": "Mozilla/5.0", "Accept": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode('utf-8'))

            for item in data[1:]:
                if not isinstance(item, dict):
                    continue
                title = item.get("position", "")
                tags = item.get("tags", [])
                score, reasons = score_job(title, tags)
                if score >= 3:
                    jobs.append({
                        "title": title,
                        "company": item.get("company", "Unknown"),
                        "url": item.get("apply_url", item.get("url", "")),
                        "source": f"remoteok-{tag}",
                        "description": clean_html(item.get("description", ""))[:300],
                        "salary": (f"${item['salary_min']:,}–${item['salary_max']:,}"
                                   if item.get("salary_min") and item.get("salary_max") else ""),
                        "score": score,
                        "relevance": ", ".join(reasons),
                    })
        except Exception as e:
            print(f"  ⚠️  RemoteOK [{tag}]: {e}", file=sys.stderr)
    return jobs


# ─── Hacker News Parser ───
class HNParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_tl = False
        self.in_a = False
        self.jobs = []
        self.href = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "titleline" in a.get("class", ""):
            self.in_tl = True
        if self.in_tl and tag == "a":
            self.in_a = True
            self.href = a.get("href", "")

    def handle_endtag(self, tag):
        if tag == "span" and self.in_tl:
            self.in_tl = False
        if tag == "a" and self.in_a:
            self.in_a = False
            self.href = None

    def handle_data(self, data):
        if self.in_a:
            t = data.strip()
            if t:
                self.jobs.append({"title": t, "url": self.href})


def fetch_hn():
    jobs = []
    try:
        req = urllib.request.Request(HN_URL, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            parser = HNParser()
            parser.feed(resp.read().decode("utf-8", errors="replace"))

        for item in parser.jobs[:30]:
            score, reasons = score_job(item["title"])
            if score >= 2:
                jobs.append({
                    "title": item["title"],
                    "company": "Hacker News",
                    "url": f"https://news.ycombinator.com/{item['url']}",
                    "source": "hacker-news",
                    "description": f"HN thread: {item['title']}",
                    "score": score,
                    "relevance": ", ".join(reasons),
                })
    except Exception as e:
        print(f"  ⚠️  HN: {e}", file=sys.stderr)
    return jobs


# ─── WeWorkRemotely (disabled — parser needs work) ───
# def fetch_weworkremotely():
#     return []


# ─── Remotive API ───
def fetch_remotive():
    jobs = []
    print("🌐 Remotive API (software-dev)")
    try:
        req = urllib.request.Request(
            REMOTIVE_URL,
            headers={"User-Agent": "Mozilla/5.0", "Accept": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode('utf-8'))

        for item in data.get("jobs", [])[:30]:
            title = item.get("title", "")
            desc = clean_html(item.get("description", ""))
            tags = item.get("tags", [])
            score, reasons = score_job(title, tags)
            if score >= 3:
                jobs.append({
                    "title": title,
                    "company": item.get("company_name", "Unknown"),
                    "url": item.get("url", ""),
                    "source": "remotive",
                    "description": desc[:300],
                    "salary": "",
                    "score": score,
                    "relevance": ", ".join(reasons),
                })
    except Exception as e:
        print(f"  ⚠️  Remotive: {e}", file=sys.stderr)
    return jobs


# ─── Report ───
def generate_report(jobs):
    today = datetime.now().strftime("%Y-%m-%d")
    md = OUTPUT_DIR / f"ios_swift_jobs_{today}.md"
    js = OUTPUT_DIR / f"ios_swift_jobs_{today}.json"

    uniq = {}
    for j in jobs:
        uniq[j["url"]] = j
    uniq_jobs = sorted(uniq.values(), key=lambda x: -x.get("score", 0))

    lines = [
        f"# iOS/Swift/Vapor Remote Jobs — {today}",
        f"**{len(uniq_jobs)}** relevant listings from {len(set(j['source'] for j in uniq_jobs))} sources.\n",
    ]

    if not uniq_jobs:
        lines.append("_No matching jobs today._\n")
    else:
        for i, j in enumerate(uniq_jobs, 1):
            lines.append(f"## {i}. {j['title']}")
            lines.append(f"- **Company:** {j.get('company','See listing')}")
            lines.append(f"- **Source:** {j.get('source','?')}")
            lines.append(f"- **Relevance:** {j.get('relevance','N/A')} (score: {j.get('score','?')})")
            lines.append(f"- **URL:** {j['url']}")
            if j.get("salary"):
                lines.append(f"- **Salary:** {j['salary']}")
            if j.get("description"):
                lines.append(f"\n  {j['description']}")
            lines.append("")

    md.write_text("\n".join(lines))
    js.write_text(json.dumps(uniq_jobs, indent=2))
    print(f"✓ {md}")
    print(f"✓ {js}")
    return md


def main():
    print("🔍 iOS/Swift/Vapor Job Scraper\n")
    jobs = []
    jobs.extend(fetch_remoteok())
    jobs.extend(fetch_hn())
#    jobs.extend(fetch_weworkremotely())  # Disabled temporarily — parser needs fixing
    jobs.extend(fetch_remotive())

    print(f"\n✅ {len(jobs)} raw listings → deduping...")
    report = generate_report(jobs)
    print(f"\n📄 {report}")

    # Preview
    uniq = {j['url']: j for j in jobs}.values()
    sorted_jobs = sorted(uniq, key=lambda x: -x.get("score", 0))
    print("\n📋 Top 5:")
    for i, j in enumerate(sorted_jobs[:5], 1):
        print(f"  {i}. [{j['source']}] {j['title']}")
        print(f"     {j['url']}")

    if len(sorted_jobs) > 5:
        print(f"  ... and {len(sorted_jobs) - 5} more")
    return 0


if __name__ == "__main__":
    sys.exit(main())
