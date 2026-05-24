# Multi-Source Link Poller — Operational Patterns

**Skill:** `hermes-vault-pipeline`  
**Date:** 2026-05-03  
**Scripts covered:** `multi_link_poller.py`, `x_link_poller_v2.py`  
**Scope:** Running content ingestion scripts directly, argument parsing, vault path resolution, compile script discovery, and network resilience patterns

---

## Overview

The `multi_link_poller.py` script ingests X/Twitter and GitHub URLs into the vault's `Raw/` directory. When run manually (bypassing platform polling), it requires careful argument ordering and vault path awareness. This reference documents operational patterns discovered during a live run and content compilation.

---

## Script invocation — argparse gotcha

**Problem:** URLs placed immediately after `--limit` were rejected as "unrecognized arguments".

**Root cause:** The parser defines `--urls` as a positional argument *after* `--limit`. When URLs appear between `--limit` and `--urls`, argparse treats them as positional arguments not associated with any flag and fails.

**Correct invocation:**

```bash
# ✅ CORRECT — --limit flag, THEN --urls flag, THEN URLs
python3 multi_link_poller.py --limit 50 --urls https://x.com/foo https://github.com/bar/repo

# ❌ WRONG — URLs between --limit and --urls
python3 multi_link_poller.py --limit 50 https://x.com/foo --urls   # fails
```

The argparser expects:
```
usage: multi_link_poller.py [-h] [--urls URLS [URLS ...]] [--limit LIMIT]
```

So `--urls` is optional but when present must come *after* limit and *before* the URL list.

**Key takeaway:** When a script has `parser.add_argument("--urls", nargs="+")`, all values after the `--urls` flag are consumed as URL arguments. No other flags may follow.

---

## Vault path resolution — dual-location reality

**Observed behavior:**

| Script | VAULT_ROOT computed as |
|--------|------------------------|
| `multi_link_poller.py` | `Path.home() / "obsidian-vault" / "FACorreia"` → `/opt/data/home/obsidian-vault/FACorreia` |
| `compile_wiki.py` (skill version) | Called with `--root /opt/data/obsidian-vault/FACorreia` → `/opt/data/obsidian-vault/FACorreia` |

**Two distinct vault roots on this system:**
1. `/opt/data/home/obsidian-vault/FACorreia` — `$HOME`-relative (agent's home dir)
2. `/opt/data/obsidian-vault/FACorreia` — system data location (the canonical vault)

**Why both exist:**
- The agent user (`hermes` or similar) has `$HOME=/opt/data/home`
- Historical deployment split vault data into `/opt/data/obsidian-vault` for shared access
- Scripts that use `Path.home()` resolve to the first location; skill wrappers often pass the canonical root explicitly

**Diagnostic:** Check both locations when hunting for saved notes:

```bash
ls /opt/data/home/obsidian-vault/FACorreia/Raw/
ls /opt/data/obsidian-vault/FACorreia/Raw/
```

**Implication:** Content saved by `multi_link_poller.py` went to the `$HOME`-relative vault, not the canonical `/opt/data/obsidian-vault/` tree. The compile script found only 30 files (the canonical vault) and did not include the newly saved note.

**Workaround:** When manually running pollers, also run compile on both vault roots, or symlink one vault's `Raw/` into the other (not recommended — may cause duplicate filenames).

---

## Compile script discovery — fallback chain

`multi_link_poller.py` attempts to trigger a vault compile after saving content (lines 243–255):

```python
compile_script = VAULT_ROOT / "scripts" / "compile_wiki.py"
if not compile_script.exists():
    for cand in [HOME / ".hermes/scripts/compile_wiki.py",
                 Path("/opt/data/home/.hermes/scripts/compile_wiki.py")]:
        if cand.exists():
            compile_script = cand
            break
```

**Missing candidate:** The actual canonical vault's compile script at  
`/opt/data/obsidian-vault/FACorreia/scripts/compile_wiki.py` is **not** in the fallback list.

**Result:** The script reports "compile_wiki.py not found — will compile on next scheduled pipeline." even though a working compile script exists in the canonical vault.

**Fix options (choose one):**

1. **Add the canonical vault to the fallback list** (patch script):
   ```python
   for cand in [
       HOME / ".hermes/scripts/compile_wiki.py",
       Path("/opt/data/home/.hermes/scripts/compile_wiki.py"),
       Path("/opt/data/obsidian-vault/FACorreia/scripts/compile_wiki.py"),  # ← add
   ]:
   ```

2. **Run compile manually** after poller:
   ```bash
   python3 /opt/data/obsidian-vault/FACorreia/scripts/compile_wiki.py --root /opt/data/obsidian-vault/FACorreia
   ```

3. **Rely on scheduled pipeline** (cron) which already calls the canonical compile.

**Skill action:** The skill's "Related scripts" section should include both compile locations for clarity.

---

## Network resilience — timeouts and fallback sources

**Observed pattern:** GitHub API (`api.github.com`) experienced repeated connection timeouts (~30s) while X article fetch via `r.jina.ai/http://…` was reliable (200 OK, ~2s).

**Implication:** Network to GitHub can be flaky; poller should include retry logic with backoff or fall back to scraping `github.com` HTML directly if API fails (less complete metadata, but README still retrievable).

**Current script behavior:** On GitHub fetch failure, `fetch_github_repo()` returns `None` and the URL is skipped entirely — no retry, no fallback.

**Recommended improvement** (for future patch):
- Retry 2–3 times with exponential backoff (sleep 2s, 4s, 8s)
- On persistent failure, fall back to scraping `https://r.jina.ai/http://github.com/<owner>/<repo>` to extract README+description (partial metadata)
- Log failed URLs to a separate `failed_urls.log` for later re-play

**Script location to patch:** `/opt/data/scripts/multi_link_poller.py` (or better, copy to `$HOME/.hermes/scripts/` to avoid overwrites on updates).

---

## X/Twitter auth-wall detection threshold

**Rule in script** (`fetch_x_article()`, lines 132–142):

```python
auth_patterns = [...]  # 14 phrases like "Sign in to X", "Create account", etc.
hits = sum(1 for p in auth_patterns if p.lower() in body.lower())
if hits >= 2 or len(body) < 100:
    print(f"[skip] X auth wall/short: {url}")
    return None
```

**Interpretation:**
- **≥2 auth-phrase hits** → classify as auth wall, skip
- **<2 hits but body < 100 chars** → also skip (likely truncated)

**Observed case:** URL `https://x.com/ios_dev_alb/status/2050218951087362088` was skipped with body ~200 chars but ≥2 auth patterns matched — a classic "sign-in interstitial" page returned by X.

**Non-fixable via retry:** These are true auth walls; the content is behind login. No technical workaround without credentials (which would violate TOS). Flag as `auth_wall: true` in state to avoid re-polling.

---

## State deduplication — preventing duplicate saves

The poller persists processed URLs by SHA256 hash (first 16 hex chars) in `state['processed_urls']`. Before processing, it checks:

```python
url_h = hashlib.sha256(url.encode()).hexdigest()[:16]
if url_h in state.get("processed_urls", {}):
    return False  # skip
```

**Important nuance:** The hash truncation to 16 chars introduces a small collision probability (~1 in 2⁶⁴). Acceptable for deduplication but not cryptographic guarantee.

**Manual re-processing** (if you want to force a refetch):
```bash
# Edit state file, remove the hash entry for a given URL
jq 'del(.processed_urls["<16char-hash>"])' ~/.hermes/state/multi_link_poller_state.json > tmp && mv tmp ~/.hermes/state/multi_link_poller_state.json
```

---

## URLs found today (unprocessed → processed)

From vault `Raw/` files modified in the last 7 days, 26 URLs were identified. After feeding 10 to the poller manually:

| Status | Count | Examples |
|--------|-------|----------|
| ✅ Saved | 1 | `JohannesKaufmann/html-to-markdown` (Go, 3.6k stars) |
| ⏭️ Skipped — auth wall | 1 | `x.com/ios_dev_alb/status/...` |
| ⏭️ Skipped — GitHub timeout | 5 | `apple/containerization`, `apple/container`, `permissionlesstech/bitchat`, `manaflow-ai/cmux`, `steipete/CodexBar` |
| ⏭️ Skipped — GitHub timeout | 3 | `router-for-me/CLIProxyAPI`, `github/github-mcp-server` |

Network conditions to GitHub API were poor; jina.ai X-fetcher was reliable.

**Saved note location:** `Raw/Stocks/2026-05-03 — html-to-markdown.md` (10,544 bytes)

---

## Environment facts (deployment-specific)

| Fact | Value |
|------|-------|
| Agent HOME | `/opt/data/home` |
| Canonical vault root | `/opt/data/obsidian-vault/FACorreia` |
| Agent-relative vault root | `/opt/data/home/obsidian-vault/FACorreia` |
| Compile script (canonical) | `/opt/data/obsidian-vault/FACorreia/scripts/compile_wiki.py` |
| Compile script (skill) | `/opt/data/skills/knowledge-base/scripts/kb-compile/compile_wiki.py` |
| Vault state (home-relative) Persisted state file | `~/.hermes/state/multi_link_poller_state.json` |
| Raw/ topics observed | `Dev`, `Stocks`, `Movies`, `Anime`, `TV`, `Portfolio`, `Sports` |
| Total Raw/ markdown files (home vault) | 9 |
| Total Raw/ markdown files (canonical vault) | ~130 |
| Compile result (canonical vault, after run) | 30 pages compiled to `Wiki/` |

---

## Quick reference: multi_link_poller.py one-liners

```bash
# Run with explicit URLs (note flag order!)
python3 multi_link_poller.py --limit 50 --urls <url1> <url2> ...

# Ingest from recent vault content (helper script included with skill)
python3 /opt/data/skills/hermes-dev/hermes-vault-pipeline/scripts/extract_urls_from_vault.py --days 7 | \
  xargs -n1 -I{} python3 multi_link_poller.py --limit 50 --urls {}

# Manually compile both vault locations
python3 /opt/data/obsidian-vault/FACorreia/scripts/compile_wiki.py --root /opt/data/obsidian-vault/FACorreia
python3 /opt/data/home/.hermes/scripts/compile_wiki.py --root /opt/data/home/obsidian-vault/FACorreia

# Check state
python3 -c "import json; print(json.dumps(json.load(open('/opt/data/home/.hermes/state/multi_link_poller_state.json')), indent=2))"
```

---

## Related scripts added with this skill

- `scripts/extract_urls_from_vault.py` — extract unique X/Twitter and GitHub URLs from `Raw/` files modified within N days, deduplicated against poller state. Outputs one URL per line for piping to `multi_link_poller.py`.
- `scripts/compile_all_vaults.py` — compile both the canonical vault and the `$HOME`-relative vault sequentially; useful when different pollers write to different roots.
