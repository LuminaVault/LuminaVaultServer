#!/usr/bin/env python3
"""
Weekly Learning Digest — Hermes Agent

Every Sunday at 11 PM UTC, this script reviews:
  • Recent chat history (via session_search)
  • Persistent memory (user + agent)
  • Obsidian vault notes (if OBSIDIAN_VAULT_PATH is set)
  • User profile file (~/.hermes/user_profile.json, optional)

Then it posts a summary to Discord's home channel, answering:
  — What have I learned about you?
  — What are your interests and goals?
  — What have you saved/recently worked on?
  — What patterns are emerging?
"""

import os
import sys
import json
# yaml removed — using JSON profile
from datetime import datetime, timezone, timedelta
from collections import Counter
import re

# ── Constants ───────────────────────────────────────────────────────────────

HOME = os.path.expanduser("~")
HERMES_DIR = os.getenv("HERMES_DIR", os.path.join(HOME, ".hermes"))
PROFILE_PATH = os.path.join(HERMES_DIR, "user_profile.json")
LOG_PATH = os.path.join(HERMES_DIR, "logs", "weekly_digest.log")

# Discord target (falls back to home channel)
DISCORD_CHANNEL_ID = os.getenv("HERMES_DISCORD_CHANNEL_ID", "1498025894751768776")

# How many recent sessions to scan (placeholder for transcript cache)
SESSION_LOOKBACK_DAYS = 7

# ── Helpers ──────────────────────────────────────────────────────────────────

def log(msg: str):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    with open(LOG_PATH, "a") as f:
        f.write(line + "\n")

def safe_read(path: str, fallback: str = "[not found]") -> str:
    try:
        with open(path) as f:
            return f.read()
    except Exception as e:
        log(f"WARNING: cannot read {path}: {e}")
        return fallback

def extract_entities(text: str) -> dict:
    """Pull out tickers, projects, tech keywords from text with smart filtering."""
    
    # ── Known ticker whitelist (expanded) ──
    KNOWN_TICKERS = {
        "ABCL", "ZETA", "AMD", "OSCR", "ONDS", "KRKNF", "HIMS", "SMR", "FLNC", "SP500",
        "AAPL", "MSFT", "GOOGL", "AMZN", "META", "TSLA", "NVDA", "NFLX", "ADBE", "INTC",
        "CSCO", "ORCL", "CRM", "SAP", "IBM", "TXN", "AVGO", "QCOM", "TCEHY", "BABA",
        "PDD", "JD", "BIDU", "NIO", "XPEV", "LI", "RIVN", "LCID", "PLTR", "COIN",
        "HOOD", "SOFI", "UPST", "AFRM", "PYPL", "SQ", "ADYEY", "DASH", "UBER", "LYFT",
        "MELI", "SHOP", "ZM", "U", "COUR", "TWLO", "OKTA", "ZM", "TEAM", "DOCN", "DBX"
    }
    
    raw_tickers = re.findall(r'\b([A-Z]{2,5})\b', text)
    
    # Exclude obvious false positives
    EXCLUDE = {
        # English words
        "THE","AND","FOR","YOU","FROM","WITH","THIS","THAT","WAS","ARE","ALL","HAS","HAD",
        "WERE","THEY","THEM","OUR","YOUR","MY","HIS","HER","ITS","OURS","THEIRS","VERY",
        # Tech acronyms appearing in logs/code
        "SYS","ERR","OUT","EOF","API","URL","JSON","HTML","XML","HTTP","HTTPS","SSH","SHA",
        "RSA","ED25519","KEY","ID","USER","PASS","ERROR","SUCCESS","TRUE","FALSE","NULL",
        "NONE","PR","QA","IMAP","SMTP","YES","NO","ON","OFF","ONLY","NOT","AFTER","BEFORE",
        "DURING","ABOUT","INTO","FROM",
        # File formats / data types
        "RSS","WWR","YAML","CSV","TSV","PDF","PNG","JPG","GIF","SVG","DOC","DOCX","XLS",
        "XLSX","PPT","PPTX","ZIP","TAR","GZ","MD","TXT","LOG","CONF","CFG","INI","ENV",
        # HTTP methods / macOS product names
        "GET","POST","PUT","DELETE","PATCH","HEAD","OPTIONS","MACOS","IOS","IPADOS",
        "VISIONOS","WATCHOS","TVOS","IPHONE","IPAD",
        # Company / product shorthand not tickers
        "REST","GRAPHQL","GRPC","WEBSOCKET","SDK","CLI",
        # Git / devops
        "GIT","SVN","CI","CD","DEV","PROD","STAGING","TEST","LOCALHOST","SERVER","HOST",
        "PORT","CONN","TIMEOUT","RETRY","CACHE","SESSION","TOKEN",
        # Programming languages
        "PYTHON","JAVASCRIPT","TYPESCRIPT","JAVA","CSHARP","CPP","CXX","RUST","OBJECTIVE-C",
        "KOTLIN","SCALA","PERL","PHP","RUBY","LUA","HASKELL","CLOJURE","ELIXIR","ERLANG",
        # Databases / infra
        "SQL","NOSQL","POSTGRESQL","MONGODB","MYSQL","SQLITE","REDIS","MEMCACHED","KAFKA",
        "RABBITMQ","ELASTICSEARCH","S3","EC2","ECS","EKS","LAMBDA",
        # Security
        "TLS","SSL","JWT","OAUTH","SAML","MFA","2FA","TOTP","OTP",
        # Status / log levels
        "START","END","BEGIN","FINISH","RUNNING","STARTED","COMPLETED","FAILED","WARNING",
        "INFO","DEBUG","TRACE","FATAL","TRACE",
        # Single letters
        "A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T",
        "U","V","W","X","Y","Z"
    }
    
    tickers = [t for t in raw_tickers if t not in EXCLUDE and t in KNOWN_TICKERS]
    
    # ── Tech stack ──
    TECH_STACK = {
        "swift","swiftui","vapor","ios","macos","ipados","visionos","watchos","tvos",
        "python","javascript","typescript","go","golang","rust","java","kotlin","scala",
        "docker","kubernetes","cron","postgres","redis","mongodb","mysql","sqlite","mariadb",
        "huggingface","llama","vllm","transformers","pytorch","tensorflow","jax","onnx",
        "jupyter","obsidian","git","ssh","xcode","npm","yarn","brew","make","cmake","ninja",
        "aws","gcp","azure","cloudflare","digitalocean","linode","vultr","heroku","netlify",
        "vercel","nginx","apache","traefik","caddy","linux","bash","zsh","fish","powershell",
        "http","https","ssl","tls","oauth","jwt","rest","graphql","grpc","websocket","soap",
        "ci","cd","github","gitlab","bitbucket","vscode","vim","neovim","intellij","xcode",
        "sublime","atom","emacs"
    }
    words = re.findall(r'\b[a-z]{2,}\b', text.lower())
    tech_counts = Counter()
    for w in words:
        if w in TECH_STACK:
            tech_counts[w] += 1
    
    # ── Projects ──
    PROJECT_PATTERNS = [
        (r'StockPlan|stock[_-]?plan', 'StockPlan'),
        (r'\bHermes\b', 'Hermes'),
        (r'news[_\s-]?digest', 'news_digest'),
        (r'job[_\s-]?scraper', 'job_scraper'),
        (r'ios[_\s-]?jobs', 'ios_jobs'),
        (r'weekly[_\s-]?digest', 'weekly_digest'),
        (r'swiftui[_\s-]?app', 'swiftui_app'),
    ]
    proj_counts = Counter()
    for pat, name in PROJECT_PATTERNS:
        for _ in re.findall(pat, text, re.IGNORECASE):
            proj_counts[name] += 1
    
    # ── Sports ──
    SPORTS = {
        'NBA': r'\bNBA\b',
        'NFL': r'\bNFL\b',
        'Benfica': r'\bBenfica\b|\bSLB\b',
        'Soccer': r'\bSoccer\b|\bfootball\b(?! \w)',
        'F1': r'\bF1\b|\bFormula[ -]?1\b',
    }
    sports_counts = Counter()
    for team, pat in SPORTS.items():
        if re.search(pat, text, re.IGNORECASE):
            sports_counts[team] += 1
    
    return {
        "tickers": tickers,
        "tech": tech_counts,
        "projects": proj_counts,
        "sports": sports_counts
    }

# ── Data Collectors ──────────────────────────────────────────────────────────

def collect_chat_history() -> str:
    """Pull recent transcript summary from local cache (if available)."""
    transcripts_dir = os.path.join(HERMES_DIR, "transcripts")
    if os.path.exists(transcripts_dir):
        cutoff = datetime.now() - timedelta(days=SESSION_LOOKBACK_DAYS)
        sessions = []
        try:
            for fname in sorted(os.listdir(transcripts_dir)):
                if not fname.endswith(".json"):
                    continue
                fpath = os.path.join(transcripts_dir, fname)
                try:
                    mtime = datetime.fromtimestamp(os.path.getmtime(fpath))
                    if mtime < cutoff:
                        continue
                    with open(fpath) as f:
                        data = json.load(f)
                        sessions.append(data.get("summary", ""))
                except Exception as e:
                    log(f"  [skip {fname}: {e}]")
        except Exception as e:
            log(f"Error scanning transcripts: {e}")
        return "\n\n".join(sessions)
    return "[no transcript cache — transcripts will be added as this runs]"

def collect_memory() -> dict:
    """Read user + agent memory stores."""
    user_mem = {}
    agent_mem = {}
    
    for store, target in [("user", user_mem), ("memory", agent_mem)]:
        path = os.path.join(HERMES_DIR, store)
        if os.path.exists(path):
            try:
                with open(path) as f:
                    for line in f:
                        line = line.strip()
                        if not line or line.startswith("#"):
                            continue
                        if ":" in line:
                            k, v = line.split(":", 1)
                            target[k.strip()] = v.strip()
            except Exception as e:
                log(f"Error reading {store} memory: {e}")
    
    return {"user": user_mem, "agent": agent_mem}

def collect_obsidian_vault() -> dict:
    """Scan vault for recent notes, topics, and interests."""
    vault_path = os.getenv("OBSIDIAN_VAULT_PATH")
    if not vault_path:
        vault_path = os.path.join(HOME, "Documents", "Obsidian Vault")
    
    if not os.path.exists(vault_path):
        return {
            "enabled": False,
            "reason": "vault path not set or inaccessible"
        }
    
    notes = []
    topics = Counter()
    recent_notes = []
    cutoff = datetime.now() - timedelta(days=30)
    
    log(f"Scanning vault: {vault_path}")
    for root, dirs, files in os.walk(vault_path):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        
        for fname in files:
            if not fname.endswith(".md"):
                continue
            fpath = os.path.join(root, fname)
            rel = os.path.relpath(fpath, vault_path)
            
            try:
                mtime = datetime.fromtimestamp(os.path.getmtime(fpath))
                if mtime > cutoff:
                    recent_notes.append(rel)
                
                with open(fpath) as f:
                    content = f.read()
                    tags = re.findall(r'#([\w-]+)', content)
                    for tag in tags:
                        topics[tag] += 1
                    links = re.findall(r'\[\[([^\]]+)\]\]', content)
                    for link in links:
                        topics[f"→{link}"] += 1
                notes.append({"path": rel, "size": len(content), "tags": tags})
            except Exception as e:
                log(f"  [skip {rel}: {e}]")
    
    folders = Counter([os.path.dirname(n["path"]) or "/" for n in notes])
    
    return {
        "enabled": True,
        "vault_path": vault_path,
        "total_notes": len(notes),
        "recent_notes": recent_notes[:20],
        "top_tags": topics.most_common(15),
        "top_folders": folders.most_common(10)
    }


def collect_user_profile() -> dict:
    """Read optional user profile JSON."""
    if os.path.exists(PROFILE_PATH):
        try:
            import json
            with open(PROFILE_PATH) as f:
                return json.load(f) or {}
        except Exception as e:
            log(f"Error reading user profile: {e}")
    return {}

# ── Analysis ─────────────────────────────────────────────────────────────────

def analyze_patterns(chat_text: str, memory: dict, vault: dict, profile: dict) -> dict:
    """Derive insights from all sources."""
    analysis = {
        "interests": [],
        "active_projects": [],
        "stock_focus": [],
        "tech_stack": [],
        "content_style": "",
        "goals": [],
        "learning_themes": [],
        "sports": [],
        "workstreams": []
    }
    
    # Build composite text for entity extraction
    full_text = chat_text + " " + str(memory) + " " + str(profile)
    
    
    entities = extract_entities(full_text)
    
    analysis["stock_focus"] = entities["tickers"][:20] if isinstance(entities["tickers"], list) else [t for t, c in entities["tickers"].most_common(20)]
    analysis["tech_stack"] = [t for t, c in entities["tech"].most_common(20)] if hasattr(entities["tech"], "most_common") else entities["tech"][:20]
    analysis["active_projects"] = [p for p, c in entities["projects"].most_common(10)] if hasattr(entities["projects"], "most_common") else entities["projects"][:10]
    analysis["sports"] = [s for s, c in entities["sports"].most_common(10)] if hasattr(entities["sports"], "most_common") else entities["sports"][:10]
    
    user_prefs = memory.get("user", {})
    if "preferences" in user_prefs:
        analysis["interests"].extend([p.strip() for p in user_prefs["preferences"].split(",")])
    
    if vault.get("enabled"):
        analysis["vault_topics"] = [tag for tag, count in vault["top_tags"][:10]]
        analysis["vault_folders"] = [folder for folder, count in vault["top_folders"][:5]]
    
    if profile:
        if "interests" in profile:
            analysis["interests"].extend(profile["interests"])
        if "goals" in profile:
            analysis["goals"] = profile["goals"]
        if "content_style" in profile:
            analysis["content_style"] = profile["content_style"]
    
    lines = [l for l in chat_text.split("\n") if l.strip()]
    avg_len = sum(len(l) for l in lines) / max(1, len(lines))
    if avg_len > 120:
        analysis["content_style"] = "detailed & technical"
    elif avg_len < 60:
        analysis["content_style"] = "concise & direct"
    else:
        analysis["content_style"] = "balanced"
    
    # Build user-message-only corpus from transcripts (remove HERMES lines)
    user_msgs_only = "\n".join(
        l for l in chat_text.split("\n") if l.startswith("USER:")
    ).lower()
    
    # Combined corpus for heuristic scoring
    corpus = full_text + " " + user_msgs_only
    
    themes = []
    
    # Workstream 1 — Job Board Aggregation (iOS/Swift/Vapor remote roles)
    job_signals = [
        'scrap', 'job', 'ios', 'swift', 'vapor', 'remoteok', 'remotive',
        'weworkremotely', 'hacker news', 'score_job', 'relevant listing',
        'daily ios', 'job scraper', 'remote roles'
    ]
    if sum(s in corpus for s in job_signals) >= 4:
        themes.append("job board aggregation (iOS/Swift/Vapor remote roles)")
        analysis["workstreams"].append("job_scraper")
    
    # Workstream 2 — News Digest (RSS-based, twice-daily)
    news_signals = [
        'news digest', 'twice-daily', 'rss', 'feed', 'nba.com', 'theverge',
        'ars technica', 'ai news', 'swift.org', 'kodeco', 'dev.to',
        'google news', 'beaten down', 'hot stocks', 'trendy', 'politics',
        'benfica', 'football', 'nba', 'nfl'
    ]
    if sum(s in corpus for s in news_signals) >= 4:
        themes.append("news aggregation (RSS-based multi-category digest)")
        analysis["workstreams"].append("news_digest")
    
    # Workstream 3 — X/Twitter Integration exploration
    x_signals = ['xurl', 'oauth', 'twitter', 'x.com', 'client-id', 'client-secret',
                 'redirect-uri', 'tweet.read', 'tweet.write', 'code_challenge']
    if sum(s in corpus for s in x_signals) >= 3:
        themes.append("X/Twitter API integration exploration")
        analysis["workstreams"].append("x_integration")
    
    # Workstream 4 — Server Deployment & SSH
    ssh_signals = ['ssh', 'root@', 'public key', 'github_actions_deploy',
                   'scp', '168.119.156.43', 'connect timeout', 'batchmode']
    if sum(s in corpus for s in ssh_signals) >= 2:
        themes.append("server deployment & SSH key management")
        analysis["workstreams"].append("server_ops")
    
    # Workstream 5 — Cron Automation & Scheduling
    cron_signals = ['cron', 'schedule', '9 am', '17 pm', '23:00', 'weekly',
                    'crontab', '0 9', '0 17']
    if sum(s in corpus for s in cron_signals) >= 2:
        themes.append("cron-based automation & scheduling")
        analysis["workstreams"].append("automation")
    
    # Workstream 6 — Knowledge Management (Obsidian Vault)
    vault_signals = ['obsidian', 'vault', 'wiki', 'tag:', '#', 'markdown', 'note']
    if sum(s in corpus for s in vault_signals) >= 3:
        themes.append("knowledge management (Obsidian vault integration)")
        analysis["workstreams"].append("knowledge_base")
    
    # Workstream 7 — StockPlan Product Development
    stockplan_signals = [
        'stockplan', 'vapor', 'swiftui', 'application.swift', 'routes.swift',
        'configure.swift', 'migration', 'model', 'controller', '@test',
        'health endpoint', 'openapi', 'docker', 'docker-compose', 'postgres',
        'redis', 'finnhub', 'resend', 'jwt', 'migration', '265 swift files',
        '236 tests'
    ]
    if sum(s in corpus for s in stockplan_signals) >= 5:
        themes.append("StockPlan product development (backend + frontend)")
        analysis["workstreams"].append("stockplan_product")
    
    # Workstream 8 — Testing & Quality Assurance
    test_signals = ['test', '@test', '236 tests', 'xctest', 'swift testing',
                    'coverage', 'migration', 'schema']
    if sum(s in corpus for s in test_signals) >= 2:
        themes.append("testing & quality assurance (236 test cases)")
        analysis["workstreams"].append("testing")
    
    # Workstream 9 — DevOps & Production Hardening
    devops_signals = ['docker', 'production', 'deploy', '.env', 'redis', 'postgres',
                      'finnhub', 'resend', 'jwt_secret', 'api key', 'environment']
    if sum(s in corpus for s in devops_signals) >= 3:
        themes.append("DevOps & production environment configuration")
        analysis["workstreams"].append("devops")
    
    # Workstream 10 — Marketing & Launch Preparation
    marketing_signals = ['marketing', 'reddit', 'x thread', 'promotional', 'launch',
                         'testflight', 'app store', 'announcement']
    if sum(s in corpus for s in marketing_signals) >= 2:
        themes.append("marketing content generation & launch preparation")
        analysis["workstreams"].append("marketing")
    
    # Workstream 11 — Skill Review & Systematization
    skill_signals = ['skill', 'save', 'review', 'update', 'procedure', 'workflow',
                     'pattern', 'systematic', 'capture', 'preserve']
    if sum(s in corpus for s in skill_signals) >= 3:
        themes.append("skill capture & systematic knowledge preservation")
        analysis["workstreams"].append("skill_systematization")
    
    # Deduplicate while preserving order
    seen = set()
    unique_themes = []
    for t in themes:
        if t not in seen:
            unique_themes.append(t)
            seen.add(t)
    
    analysis["learning_themes"] = unique_themes
    
    
    # Debug: print workstreams before returning
    # log(f"DEBUG workstreams: {analysis['workstreams']}")
    # log(f"DEBUG workstreams: {analysis['workstreams']}")
    return analysis

# ── Report Generation ─────────────────────────────────────────────────────────

def generate_digest(chat_text: str, memory: dict, vault: dict, profile: dict, analysis: dict) -> str:
    date_str = datetime.now().strftime("%Y-%m-%d")
    
    # Build full corpus for entity extraction
    full_text = chat_text + " " + str(memory) + " " + str(profile)

    sections = []
    sections.append(f"📊 **Weekly Learning Digest** — {date_str}")
    sections.append(f"*What Hermes has learned about you this week*\n")
    
    sections.append("## 👤 Who You Are\n")
    user_prefs = memory.get("user", {})
    handle = user_prefs.get("handle", profile.get("handle", "[𝓓𝓻𝓪𝓬𝓪𝓻𝔂𝓼 𝓣𝓲𝓰𝓮𝓻]"))
    role = profile.get("role", user_prefs.get("role", "Founder / Developer"))
    sections.append(f"- **Handle**: {handle}")
    sections.append(f"- **Role**: {role}")
    sections.append(f"- **Primary Project**: StockPlan (SwiftUI + Vapor fintech)")
    
    if vault.get("enabled"):
        sections.append(f"- **Vault**: {vault['total_notes']} notes in Obsidian")
        if vault.get("recent_notes"):
            sections.append(f"  • Active notes: {', '.join(vault['recent_notes'][:5])}")
    else:
        sections.append(f"- **Vault**: Not connected (set OBSIDIAN_VAULT_PATH)")
    sections.append("")
    
    sections.append("## 🎯 What You Track & Follow\n")
    if analysis["stock_focus"]:
        tickers = ", ".join(analysis["stock_focus"][:15])
        sections.append(f"- **Stocks/ETFs**: {tickers}")
    if analysis["sports"]:
        sports = ", ".join(sorted(set(analysis["sports"])))
        sections.append(f"- **Sports**: {sports}")
    if analysis["tech_stack"]:
        tech = ", ".join(analysis["tech_stack"][:15])
        sections.append(f"- **Tech Stack**: {tech}")
    if analysis.get("vault_topics"):
        topics = ", ".join([f"#{tag}" for tag, cnt in analysis["vault_topics"][:12]])
        sections.append(f"- **Vault Topics**: {topics}")
    sections.append("")
    
    sections.append("## 🔨 Active Work & Current Focus\n")
    if analysis["active_projects"]:
        proj_list = ", ".join(analysis["active_projects"][:10])
        sections.append(f"- **Projects**: {proj_list}")
    if analysis.get("workstreams"):
        sections.append("- **Active Workstreams**:")
        for ws in analysis["workstreams"][:8]:
            sections.append(f"  • {ws}")
    elif analysis["learning_themes"]:
        sections.append("- **Themes**:")
        for theme in analysis["learning_themes"][:6]:
            sections.append(f"  • {theme}")
    sections.append("")
    
    sections.append("## 💬 Communication Style\n")
    sections.append(f"- Tone: {analysis.get('content_style', 'balanced')}")
    sections.append("- High-trust delegation, prefers systems over talk")
    sections.append("- Values automation > manual processes")
    sections.append("")
    
    if vault.get("enabled") and vault.get("top_tags"):
        sections.append("## 📁 Vault Highlights\n")
        for tag, count in vault["top_tags"][:10]:
            sections.append(f"- `#{tag}` ×{count}")
        sections.append("")
    
    if analysis["goals"] or profile.get("goals"):
        sections.append("## 🎯 Declared Goals\n")
        goals = analysis.get("goals", [])
        if not goals and profile:
            goals = profile.get("goals", [])
        for g in goals[:5]:
            sections.append(f"- {g}")
        sections.append("")
    
    sections.append("## 🤖 Your Toolbelt\n")
    sections.append("- Hermes agent (automation hub)")
    sections.append("- Cron-based daily reports & news digests")
    sections.append("- SSH + Docker + Vapor production stack")
    if vault.get("enabled"):
        sections.append("- Obsidian vault as knowledge base")
    sections.append("")
    
    sections.append("## 🔮 Next Week Focus (inferred)\n")
    next_week = []
    
    workstreams = analysis.get("workstreams", [])
    
    # Workstream-driven priorities
    if "stockplan_product" in workstreams:
        next_week.append("StockPlan frontend TestFlight build & production backend deploy")
    if "x_integration" in workstreams:
        next_week.append("X/Twitter OAuth completion (redirect URI & token storage setup)")
    if "news_digest" in workstreams:
        next_week.append("News digest content quality review & source expansion")
    if "job_scraper" in workstreams:
        next_week.append("iOS job scraper source reliability audit & scoring tune")
    if not vault.get("enabled", False) and "obsidian" in analysis["tech_stack"]:
        next_week.append("Connect Obsidian vault to Hermes (set OBSIDIAN_VAULT_PATH)")
    if "devops" in workstreams:
        next_week.append("Production Docker compose & .env configuration finalization")
    if "marketing" in workstreams:
        next_week.append("Reddit/X marketing content scheduling for StockPlan launch")
    if "skill_systematization" in workstreams:
        next_week.append("Weekly skill-review & procedure documentation capture")
    
    # Always keep the rhythm
    next_week.append("Sunday vault & week-preview review (11 PM UTC)")
    
    for nw in next_week[:6]:
        sections.append(f"- {nw}")
    sections.append("")

