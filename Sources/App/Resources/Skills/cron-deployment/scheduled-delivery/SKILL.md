---
name: scheduled-delivery
category: cron-deployment
description: Patterns and conventions for delivering content from scheduled cron jobs — platform integration (Discord/Telegram/Slack), message formatting, auto-delivery via origin, and multi-channel routing strategies
triggers:
  - scheduled job output delivery
  - cron job platform posting
  - deliver: origin vs direct platform delivery
  - multi-channel digest publishing
---

## Overview

Covers the complete lifecycle of getting content from scheduled/cron job scripts to messaging platforms (Discord, Telegram, Slack, email). Distinguishes between **auto-delivery via `origin`** (cron job context) and **explicit `send_message` tool calls** (interactive context), and provides patterns for each pathway.

**Core principle:** Cron jobs don't call `send_message` — they output to stdout and rely on the Hermes cron framework to capture and deliver via the job's `deliver` target.

## When to Use

Use this skill when:
- Setting up or debugging a new scheduled/cron job that needs to publish output
- Deciding between `deliver: origin` (auto-handled by cron framework) vs. `deliver: discord:CHANNEL_ID` (explicit routing)
- Formatting digests for multi-platform delivery (Discord/Telegram/Slack)
- Handling message size limits and batch splitting for large digests
- Troubleshooting 403 errors or missing messages from cron jobs
- Determining whether to use `send_message` tool vs. script stdout

## 0. Architecture Primer: Two Delivery Pathways

### Pathway A — Cron Auto-Delivery (Recommended for most scheduled jobs)
```
cron job runs → script writes markdown to stdout → Hermes cron captures → delivers via deliver target
```
- **No `send_message` calls inside the script**
- Delivery target is defined in the cron job config (`deliver` field)
- Standard targets: `origin`, `discord:CHANNEL_ID`, `telegram`, `slack`
- The agent framework handles actual platform delivery after script exits
- **Use when:** pure scheduled automation, no user interaction needed

### Pathway B — Explicit Tool Call (Interactive/scripted)
```
cron/interactive session → script calls send_message() → immediate platform delivery
```
- Script directly invokes messaging (via CLI, webhook, or tool call)
- Used when job needs conditional/dynamic channel selection
- Used for real-time alerts (stock thresholds, resource monitoring)
- **Use when:** dynamic routing, multi-target fan-out, or outside cron framework

## 1. Choosing a Delivery Target

| `deliver` value | Meaning | Auto-Delivered? | Typical Use |
|-----------------|---------|-----------------|-------------|
| `origin` | Back to Hermes host (cron stdout) | ✅ Yes (by framework) | Default for cron jobs; debugging |
| `discord` | Default Discord home channel (if configured) | ✅ Yes | General notifications |
| `discord:CHANNEL_ID` | Specific Discord channel | ✅ Yes | Targeted content streams |
| `telegram` | Default Telegram chat | ✅ Yes | Personal/team alerts |
| `telegram:CHAT_ID` | Specific Telegram chat | ✅ Yes | Private digests |
| `slack` | Default Slack channel | ✅ Yes | Workspace updates |
| `email` | Email via SMTP | ⚠️ Script must handle | Formal reports |

**Rule of thumb:** Start with `deliver: origin`. Only switch to explicit platform targets when you need guaranteed separation of content streams (e.g., stock alerts vs general news).

## 2. Implementation Pattern — Cron Auto-Delivery (Pathway A)

This is the **preferred pattern** for scheduled digest jobs (news, stock reports, weekly summaries).

**Step 1 — Script structure:**
```python
#!/usr/bin/env python3
\"\"\"Job description — brief.\"\"\"

import sys

def main():
    # 1. Fetch/process data
    content = generate_digest()  # returns markdown string
    
    # 2. Print ONLY digest to stdout (no extra logging)
    print(content)
    
    # 3. Exit 0 on success; non-zero on failure (framework captures stderr)
    sys.exit(0)

if __name__ == \"__main__\":
    main()
```

**Critical rules:**
- ✅ Print ONLY the final digest to `stdout` (no debug prints, no logging to stdout)
- ✅ Write logs to stderr or a file (cron captures stderr separately)
- ✅ Exit code 0 = success; non-zero = failure (framework won't deliver on failure)
- ✅ Digest should be Markdown with clear section headings (`## Category`)

**Step 2 — Cron job config:**
```json
{
  \"name\": \"twice-daily-news-digest\",
  \"script\": \"/opt/data/home/.hermes/scripts/news_digest.py\",
  \"deliver\": \"origin\",          // or \"discord:1499331939469889656\"
  \"schedule\": \"0 9,21 * * *\",  // 9 AM/9 PM daily
  \"enabled\": true
}
```

**Step 3 — Platform routing via `deliver`:**
- `origin` → Hermes host receives output in cron logs (accessible via `hermes cron logs <job>`)
- `discord:CHANNEL_ID` → Direct to that Discord channel (requires bot membership + permissions)
- Channel IDs come from `discord-bot-operations` skill reference `channel-id-mapping.md`

## 3. Implementation Pattern — Explicit Tool Call (Pathway B)

Use this **only when** the cron framework's `deliver` field is insufficient (dynamic/changing targets, conditional fan-out).

**When to use Pathway B:**
- Job posts to multiple different channels based on content (e.g., alerts: critical→alerts-channel, info→general)
- Job needs to post to a platform not supported by cron `deliver` field
- Job runs outside the cron framework (manual script, ad-hoc trigger)

## 3a. Self-Delivering Cron Jobs (Pathway B — Specialized Subpattern)

A common variant of Pathway B is the **self-delivering cron job with auto-generated status reporting**. These jobs:

- Handle their own platform delivery (direct HTTP API to Discord/Telegram)
- Produce **no stdout** (cron wrapper detects this and generates a status report)
- Maintain their own log files and state for deduplication
- Use `deliver: origin` so the wrapper captures the run

**Example:** `portfolio_threshold_alerts.py` — fetches prices, compares thresholds, sends alerts via Discord/Telegram webhooks, and writes to `~/.hermes/portfolio/threshold_alerts.log`. The cron wrapper reads this log and produces a rich markdown status report even though the script printed nothing.

**Benefits:**
- Real-time delivery (no cron framework queuing)
- Full control over retry logic, batching, and error handling per platform
- Independent of cron `deliver` target limitations
- Still visible in Hermes cron logs via auto-generated summary

- `references/self-delivering-cron-pattern.md` — full pattern guide, detection logic, troubleshooting, and transition strategies between self-delivering and auto-delivery patterns.
- `references/self-delivering-cron-alerts.md` — session notes and checks for alert scripts that self-post to Discord and intentionally exit 1.

**Pattern:**
```python
#!/usr/bin/env python3
\"\"\"Real-time alert script — uses explicit delivery.\"\"\"\"

import subprocess
import sys

def send_discord_webhook(content, webhook_url):
    \"\"\"Direct webhook POST (no hermes CLI needed).\"\"\"
    import urllib.request
    import json
    payload = {\"content\": content}
    req = urllib.request.Request(
        webhook_url,
        data=json.dumps(payload).encode(),
        headers={\"Content-Type\": \"application/json\"}
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status == 200
    except Exception as e:
        print(f\"[discord] failed: {e}\", file=sys.stderr)
        return False

def main():
    alert = generate_alert()
    
    # Option 1: Use webhook directly (no deps)
    webhook = fetch_webhook_from_config()
    if send_discord_webhook(alert, webhook):
        print(\"✅ Sent to Discord\")
    
    # Option 2: Shell to hermes CLI (if available and you need skill routing)
    # subprocess.run(['hermes', 'skills', 'run', 'discord-send', '--args', '--channel ID'])
    
    sys.exit(0)
```

**Important:** Cron jobs running Pathway B must handle their own retries, rate limiting, and error logging. The cron framework won't capture delivery failures.

## 4. Multi-Platform Digest Formatting

When a single digest must go to multiple platforms, use **platform-specific formatters**:

```
scripts/
├── news_digest.py          # Core logic → returns markdown
├── format_for_discord.py   # Adds Discord emojis, keeps under 2000 chars/batch
├── format_for_telegram.py  # Telegram MarkdownV2 escaping
└── format_for_slack.py     # Slack mrkdwn with attachments
```

**Discord specifics:**
- Max 2000 chars per message; use batch splitting for longer content
- Prefer multi-post sequential delivery over single-file attachments per skill guidance
- Final batch can include full digest as `.md` file attachment (`MEDIA:/path`)
- Use `batch_digest_for_discord.py` to split intelligently on section boundaries

**Cross-platform consistency:**
- **Identical structure** across all platforms (same headings, same order)
- Only adapt syntax (emoji ↔ plain text, Markdown flavor)
- Keep section order stable: `## Summary` → `## Ticker/ Category A` → `## Ticker/ Category B` …

## 5. Handling Large Digests (>2000 chars)

### Option A — Multi-Post Sequential Delivery (Preferred)
```python
# Use the batch_digest_for_discord.py utility
# It splits on H2 headings preserving section boundaries
# Output: batch_01.md, batch_02.md, …

# Then deliver as:
#   Message 1: \"📰 News Digest — Part 1 of 3\"
#   Message 2: batch_01 content
#   Message 3: batch_02 content
#   Message 4: \"Part 3 of 3 — summary [attached full digest]\"
```

### Option B — File Attachment Only
```python
# Write digest to temp file, send as single message with attachment
# Simpler but less readable in chat
```

### Option C — Truncate with Link (Not Recommended)
Truncate at ~1900 chars and add \"Full digest: URL\" — only if you have a persistent web location.

## 6. Troubleshooting

| Symptom | Likely Cause | Fix |\n|---------|--------------|-----|\n| No message appears in Discord | `deliver: origin` but cron framework not running | Check `hermes cron status`; ensure agent is online |\n| 403 error in cron logs | Bot not in guild or lacks channel permissions | Verify bot membership, channel overrides via `discord-bot-operations` |\n| 403 error with valid permissions | Invalid or malformed Discord bot token | Check token format (should be ~88 chars, base64-like) and ensure it's correctly loaded into `os.environ` |\n| Message truncated mid-sentence | Content > 2000 chars, no batching | Use `batch_digest_for_discord.py` before delivery |\n| No output in any channel | Script wrote to stdout but also printed debug logs | Remove debug prints; only print final digest |\n| Duplicate messages | Two cron jobs with same deliver target | Consolidate or change one job's `deliver` value |\n| Empty message (200 OK but blank) | Script crashed before printing; cron still delivered empty stdout | Check stderr logs; fix script; exit non-zero on failure |\n| Environment variables appear missing (403 on platform API) | Naive `.env` loader doesn't strip `export ` prefix, so tokens not in `os.environ` | Use robust dotenv parsing (see `dotenv-parsing` skill); ensure `SLACK_BOT_TOKEN` etc are set, not `export SLACK_BOT_TOKEN` |

### Diagnostic checklist:
```bash
# 1. Check cron job status
hermes cron status <job-id>

# 2. View recent runs
hermes cron logs <job-id> --tail 5

# 3. Test deliver target (if using discord:CHANNEL_ID)
hermes discord send --channel CHANNEL_ID --file /dev/stdin <<< \"test\"

# 4. Validate bot permissions (via discord-bot-operations skill)
# - Bot is guild member
# - View Channel allowed
# - Send Messages allowed
# - No channel override denies

# 5. Verify environment variables are loaded (especially for self-delivering jobs)
python3 -c \"import os; print('TOKEN' in os.environ)\"  # should print True
```

## 7. Channel ID Reference

Keep this mapping up to date in your local references:

| Channel ID | Guild | Purpose |
|------------|-------|---------|
| `1499331939469889656` | Guild A | Cinema + general digests |
| `1499338003334561843` | Guild A | Stock alerts |
| `1499908671847661578` | Guild B | Swift/iOS news |
| `1499908914500862123` | Guild B | Golang news |
| `1498811072155484330` | Guild A | Server monitoring alerts |
| `1498025894751768776` | Guild C | Weekly learning digest |

> Source: `discord-bot-operations` skill reference `channel-id-mapping.md`

## 8. State & Deduplication

For jobs that may re-post the same content (e.g., hourly stock alerts), implement deduplication:

```python
import hashlib
import json
from pathlib import Path

STATE_DIR = Path.home() / \".cache\" / \"hermes\" / \"job_state\"
STATE_DIR.mkdir(parents=True, exist_ok=True)
STATE_FILE = STATE_DIR / \"news_digest_seen.json\"

def already_sent(content):
    \"\"\"Check if this exact digest was already delivered.\"\"\"
    digest_hash = hashlib.sha256(content.encode()).hexdigest()[:16]
    try:
        with open(STATE_FILE) as f:
            seen = set(json.load(f))
        return digest_hash in seen
    except FileNotFoundError:
        return False

def mark_sent(content):
    \"\"\"Record that this digest was delivered.\"\"\"
    digest_hash = hashlib.sha256(content.encode()).hexdigest()[:16]
    try:
        with open(STATE_FILE) as f:
            seen = set(json.load(f))
    except FileNotFoundError:
        seen = set()
    seen.add(digest_hash)
    # Keep only last 100 entries
    if len(seen) > 100:
        seen = set(list(seen)[-100:])
    with open(STATE_FILE, 'w') as f:
        json.dump(list(seen), f)

# In main():
if already_sent(content):
    print(\"Duplicate digest — skipping delivery\", file=sys.stderr)
    sys.exit(0)
    
print(content)  # stdout for delivery
mark_sent(content)
```

**Note:** Cron framework captures stdout BEFORE your script exits; if you exit non-zero after printing, delivery still happens. Use deduplication inside the script to suppress duplicates.

## 9. Daily Briefing Systems

**Pattern Description**: Automated multi-topic briefings that aggregate content from various sources, score and prioritize stories, and deliver formatted digests 2-3 times daily. This pattern is ideal for users who need comprehensive daily updates across diverse interests (markets, tech, sports, personal projects) without manual curation.

**Trigger Conditions**:
- User requests automated daily/weekly summaries across multiple topics
- Need to aggregate from RSS feeds, social media, dashboards, or APIs
- Desire to score and prioritize content based on relevance
- Multi-platform delivery (Discord, Telegram, Slack, OpenWebUi)
- Content streams with varying update frequencies

**Key Components**:
1. **Multi-Topic Coverage**: Single script handling 4-6 distinct topic areas
2. **Scoring Algorithm**: Relevance scoring based on keywords, user interests, and ownership
3. **Top N Synthesis**: Curated top stories (typically Top 5) with priority indicators
4. **Consistent Formatting**: Standardized sections for easy scanning
5. **Scheduled Delivery**: 2-3x daily runs via cron with platform routing

### Implementation Pattern

#### 1. Script Structure
```python
#!/usr/bin/env python3
\"\"\"Comprehensive daily briefing generator — runs 3x daily.\"\"\"

import json
from datetime import datetime
import os
import sys

# Configuration
TOPICS = {
    'markets': ['SP500', 'Nasdaq', 'stock market', 'investing'],
    'tech': ['technology', 'AI', 'artificial intelligence', 'software'],
    'dev': ['Golang', 'Swift', 'DevOps', 'programming'],
    'sports': ['SL Benfica', 'NBA', 'San Antonio Spurs']
}

OWNED_STOCKS = ['AAPL', 'MSFT', 'GOOGL', 'AMZN', 'TSLA', 'META', 'NVDA', 'AMD', 'INTC', 'IBM']

SOURCES = {
    'news': [
        'https://news.google.com/topics/...',
        'https://news.yahoo.com/tech/',
        'https://www.bloomberg.com/technology'
    ],
    'sports': [
        'https://www.espn.com/nba/',
        'https://www.espn.com/soccer/club/benfica/1002'
    ]
}

# Scoring weights
SCORE_WEIGHTS = {
    'keyword_match': 2,      # Title contains topic keyword
    'summary_match': 1,      # Summary contains topic keyword
    'owned_stock': 3,        # Article mentions a stock you own
    'source_authority': 1    # Premium source gets slight boost
}
```

#### 2. Scoring Algorithm
```python
def score_article(article, topic):
    \"\"\"Score article relevance to topic and user interests.\"\"\"
    score = 0
    title = article['title'].lower()
    summary = article['summary'].lower()
    
    # Keyword matches
    for keyword in topic.split():
        if keyword.lower() in title:
            score += SCORE_WEIGHTS['keyword_match']
        if keyword.lower() in summary:
            score += SCORE_WEIGHTS['summary_match']
    
    # Owned stock boost
    for stock in OWNED_STOCKS:
        if stock in title or stock in summary:
            score += SCORE_WEIGHTS['owned_stock']
            break  # Only one boost per article
    
    return score
```

#### 3. Top 5 Synthesis
- Collect articles from all topics
- Score each article against its topic relevance
- Sort by score descending
- Select top 5 stories across all categories
- Add visual indicators: 🔥 for high-score (>5) articles, 📰 for regular

#### 4. Multi-Topic Sections
```python
def generate_markdown():
    sections = [
        '# 📋 Daily Briefing',
        f'**Generated:** {datetime.now().strftime(\"%Y-%m-%d %H:%M\")}',
        '**Delivered to:** Discord, Telegram, Slack, OpenWebUi',
        '---',
        '## 🏆 Top 5 Stories Today',
        *format_top5(top5),
        '---',
        '## 📈 Market Focus',
        *format_market_focus(),
        '---',
        '## 💻 Tech & Development',
        *format_tech_news(),
        '---',
        '## ⚽ Sports Roundup',
        *format_sports_news(),
        '---',
        '*' * 50,
        '**Want more details?** Let me know which stories interest you most!'
    ]
    return '\\n'.join(sections)
```

#### 5. Cron Job Configuration
```json
{
  \"name\": \"morning-briefing\",
  \"script\": \"daily_brief.py\",
  \"deliver\": \"origin\",  // Auto-delivery via cron framework
  \"schedule\": \"0 8 * * *\",  // 8 AM daily
  \"enabled\": true
}
```

**Delivery Targets:**
- `origin` — Hermes host (default for cron jobs)
- `discord:CHANNEL_ID` — Specific Discord channel
- `telegram` — Default Telegram chat
- `slack` — Default Slack channel

### 6. Platform Integration

**Discord/Telegram/Slack:**
- Use `deliver: origin` for auto-delivery via Hermes cron framework
- For direct channel posting, use `deliver: discord:CHANNEL_ID`
- Multi-platform: Set up separate cron jobs with different `deliver` values

**OpenWebUi:**
- Content appears in the Hermes TUI under \"Scheduled Jobs\" → \"Recent Runs\"
- Click any run to see full output

### Scoring Logic

**Base scoring:**
- Keyword in title: +2 points
- Keyword in summary: +1 point
- Owned stock mentioned: +3 points (stackable with above)

**Priority thresholds:**
- 🔥 High priority: Score ≥ 5
- 📰 Normal priority: Score < 5

### Content Sources

**News Aggregators:**
- Google News topic feeds
- Yahoo Finance/Tech
- Bloomberg Technology
- MarketWatch
- CNBC Stocks

**Sports Feeds:**
- ESPN NBA
- ESPN Soccer (SL Benfica)
- BasketballNews.com

**Custom Sources:**
- RSS feeds
- Twitter/X accounts
- Polymarket dashboards (via API)
- Custom web scrapers

### Best Practices

1. **Start Simple:** Begin with simulated/placeholder content, then integrate real scraping
2. **Consistent Format:** Keep section order and headings stable across all runs
3. **Platform Limits:** Respect Discord's 2000-char limit; use batch splitting if needed
4. **Error Handling:** Exit non-zero on failure; write errors to stderr, not stdout
5. **Deduplication:** Implement seen tracking for alerts to avoid duplicates
6. **Sample Data:** Create test data to verify scoring and formatting

### Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| No message appears | `deliver: origin` but cron not running | `hermes cron status` |
| 403 errors | Bot missing channel permissions | Verify via `discord-bot-operations` |
| Truncated messages | Content > 2000 chars | Use batch splitting script |
| Wrong channel | Incorrect `deliver` value | Check channel ID mapping |
| Low relevance | Scoring too lenient | Adjust weights in config |
| Missing owned stocks | Not checking `OWNED_STOCKS` | Add stock list to config |

### Related Skills
- `cron-deployment` — Cron job lifecycle management
- `scheduled-reports` — Visual report generation patterns
- `portfolio-threshold-alerts` — Real-time stock alerts
- `social-media-content-aggregation` — Multi-source content collection

### References
- `references/delivery-target-syntax.md` — Cron delivery syntax
- `references/cron-delivery-discord-mapping.md` — Channel ID reference
- `scripts/verify_cron_delivery.py` — Delivery validation script
- `templates/cron-job-template.md` — Boilerplate job config
- `discord-bot-operations` skill — Full Discord bot setup, permissions, guild membership troubleshooting
- `cron-deployment` skill — Cron job lifecycle, schedules, state management

---
**Note:** This pattern was successfully implemented for a user monitoring markets, tech, development, and sports with 3 daily briefings. See session logs for May 4, 2026 for complete implementation details.