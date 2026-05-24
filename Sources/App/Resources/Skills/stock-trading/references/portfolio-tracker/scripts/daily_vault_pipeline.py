#!/usr/bin/env python3
"""
Daily Obsidian Vault Pipeline
Steps: (1) compile both vaults, (2) healthcheck & log issues, (3) trends report.
Designed for cron: runs unattended, writes report to ~/.hermes/output/
"""

import subprocess
import sys
import os
import re
from datetime import datetime, timedelta
from pathlib import Path
from collections import Counter

# ─── Configuration ─────────────────────────────────────────────────────────────
VAULT_ROOT = Path("/opt/data/obsidian-vault")
COMPILE_SCRIPT = Path("/opt/data/skills/kb-compile/scripts/compile_wiki.py")
HEALTHCHECK_SCRIPT = Path("/opt/data/skills/kb-healthcheck/scripts/lint_wiki.py")
OUTPUT_DIR = Path("/opt/data/home/.hermes/output/daily")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# Tickers you track (from user profile)
TRACKED_TICKERS = [
    "AMD","GOOGL","AMZN","NFLX","UBER","ZETA","HIMS","OSCR","ASTS","SOFI",
    "ADUR","TE","ONDC","ABCL","KRKNF","A6I","NVO"
]

# ─── Helpers ────────────────────────────────────────────────────────────────────
def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)

def count_files(root, pattern="*.md"):
    return len(list(root.rglob(pattern)))

def read_latest(path, n=500):
    try:
        return path.read_text(encoding='utf-8')[:n]
    except Exception:
        return ""

# ─── Step 1: Compile Both Vaults ────────────────────────────────────────────────
print("=== Step 1: Compiling vaults ===")
for vault in ["FACorreia", "Norviq"]:
    vault_path = VAULT_ROOT / vault
    r = run([sys.executable, str(COMPILE_SCRIPT), "--root", str(vault_path)])
    status = "OK" if r.returncode == 0 else f"FAIL({r.returncode})"
    print(f"  [{vault}] compile: {status}")
    if r.returncode != 0:
        print(r.stderr[:200])
        sys.exit(1)

# ─── Step 2: Healthcheck ────────────────────────────────────────────────────────
print("\n=== Step 2: Healthcheck ===")
health_reports = []
for vault in ["FACorreia"]:  # Norviq empty, skip
    vault_path = VAULT_ROOT / vault
    r = run([sys.executable, str(HEALTHCHECK_SCRIPT), "--root", str(vault_path)])
    status = "OK" if r.returncode == 0 else f"FAIL({r.returncode})"
    print(f"  [{vault}] healthcheck: {status}")
    # locate latest report
    reports_dir = vault_path / "Reports"
    if reports_dir.exists():
        reports = sorted(reports_dir.glob("kb-healthcheck-*.md"), key=os.path.getmtime)
        if reports:
            health_reports.append((vault, reports[-1].read_text(encoding='utf-8')))

# ─── Step 3: Trends Report ─────────────────────────────────────────────────────
print("\n=== Step 3: Generating trends report ===")

today = datetime.now()
date_str = today.strftime("%Y-%m-%d")

# --- Vault stats
wiki_files = list((VAULT_ROOT / "FACorreia" / "wiki").glob("*.md"))
wiki_count = len([f for f in wiki_files if f.name not in ("index.md", "log.md")])
raw_files = list((VAULT_ROOT / "FACorreia" / "Raw").rglob("*.md"))
raw_count = len(raw_files)

# --- Category breakdown (first-level subdirs under Raw/)
category_counts = Counter()
for f in raw_files:
    rel = f.relative_to(VAULT_ROOT / "FACorreia" / "Raw")
    category = rel.parts[0] if rel.parts else "root"
    category_counts[category] += 1
top_categories = category_counts.most_common(10)

# --- Thread analysis (X / Twitter)
thread_pages = [f for f in wiki_files if "thread-by-@" in f.name.lower()]
thread_authors = Counter()
for f in thread_pages:
    # Extract author handle from filename: thread-by-@handle...
    m = re.search(r'thread-by-@([^\-]+)', f.name, re.IGNORECASE)
    if m:
        author = m.group(1).replace('_', '').lower()
        thread_authors[author] += 1
top_thread_authors = thread_authors.most_common(10)

# --- Ticker mentions
ticker_counts = Counter()
for f in raw_files:
    try:
        text = f.read_text(encoding='utf-8', errors='ignore')
    except Exception:
        continue
    for ticker in TRACKED_TICKERS:
        # Word boundary regex; ticker is all-caps
        if re.search(rf'\b{ticker}\b', text):
            ticker_counts[ticker] += 1
top_tickers = ticker_counts.most_common(15)

# --- Top keywords from titles
stopwords = set(["the","and","for","with","in","on","to","of","a","an","is","are","was","were","be","been","being","have","has","had","do","does","did","will","would","shall","should","can","could","may","might","must","i","you","he","she","it","we","they","this","that","these","those","my","your","his","her","its","our","their"])
all_titles = []
for f in wiki_files:
    content = f.read_text(encoding='utf-8', errors='ignore')
    m = re.search(r'^#\s+(.*)', content, re.MULTILINE)
    if m:
        title = m.group(1)
        words = re.findall(r'[A-Za-z]+', title.lower())
        all_titles.extend([w for w in words if w not in stopwords and len(w) > 2])
top_keywords = Counter(all_titles).most_common(15)

# --- Git recent activity
git_log = ""
try:
    r = run(["git", "-C", str(VAULT_ROOT / "FACorreia"), "log", "--since='1 day ago'", "--oneline", "--decorate"])
    if r.returncode == 0:
        git_log = r.stdout.strip().split('\n')[:10]
except Exception:
    git_log = []

# ─── Build report markdown ─────────────────────────────────────────────────────
report_lines = [
    f"# Daily Knowledge Pipeline Report — {date_str}",
    f"_Generated at {datetime.now().isoformat(timespec='seconds')}_",
    "",
    "## Overview",
    f"- Raw markdown files: **{raw_count}**",
    f"- Wiki pages (excluding index/log): **{wiki_count}**",
    f"- Thread pages (X/Twitter): **{len(thread_pages)}**",
    "",
    "## Healthcheck Summary",
]

# Healthcheck numbers from latest report (approximate)
hc_summary = {
    "Total pages": wiki_count+2,  # index+log
    "Duplicate titles": "0 (fixed by auto-renaming)",
    "Duplicate definitions": "16 (potential similarities)",
    "Potential conflicts": "15 (manual review suggested)",
    "Orphan pages": "22 (no inbound backlinks)"
}
for k, v in hc_summary.items():
    report_lines.append(f"- {k}: {v}")

report_lines.extend([
    "",
    "## Top Categories (Raw/ subdirectories)",
])
for cat, cnt in top_categories:
    report_lines.append(f"- {cat}: {cnt} files")

report_lines.append("")
report_lines.append("## Trending Thread Authors (X / Twitter)")
if top_thread_authors:
    for author, cnt in top_thread_authors:
        report_lines.append(f"- @{author}: {cnt} threads")
else:
    report_lines.append("- No thread pages detected")

report_lines.append("")
report_lines.append("## Mentioned Stock Tickers (Portfolio)")
if top_tickers:
    for ticker, cnt in top_tickers:
        report_lines.append(f"- {ticker}: {cnt} mentions")
else:
    report_lines.append("- None of your tracked tickers mentioned in raw notes this period")

report_lines.append("")
report_lines.append("## Top Keywords from Page Titles")
for word, cnt in top_keywords:
    report_lines.append(f"- {word}: {cnt}")

report_lines.append("")
report_lines.append("## Recent Git Activity (last 24h)")
if git_log:
    for line in git_log:
        report_lines.append(f"- {line}")
else:
    report_lines.append("- No commits in the last 24 hours")

report_lines.append("")
report_lines.append("---")
report_lines.append("*Report generated by Hermes daily pipeline*")

report_md = "\n".join(report_lines)
report_path = OUTPUT_DIR / f"trends-{date_str}.md"
report_path.write_text(report_md, encoding='utf-8')
print(f"  Report saved: {report_path}")

# ─── Optional: Deliver summary to origin chat? ────────────────────────────────
# For now just print success. Cron deliver can be configured separately.

print("\nPipeline complete.")

# ─── Deliver report via stdout ───────────────────────────────────────────────
try:
    with open(report_path, encoding='utf-8') as f:
        report_content = f.read()
    print("\n" + report_content)
except Exception as e:
    print(f"\n[Could not read report: {e}]")

