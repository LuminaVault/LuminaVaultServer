# AI Cohort Scoreboard - Path Fix Reference

## Scripts and Paths

### Main Script: `ai_scoreboard.py`
**Location:** `/root/.hermes/home/.hermes/scripts/ai-scoreboard/ai_scoreboard.py`

**Fixes Applied:**
1. Line 22: Changed `VAULT_ROOT` path
   ```python
   # Before:
   VAULT_ROOT = '/opt/data/home/.hermes/obsidian-vault/FACorreia'
   # After:
   VAULT_ROOT = '/opt/data/home/obsidian-vault/FACorreia'
   ```

2. Line 23: Changed `load_config` default root path
   ```python
   # Before:
   def load_config(root='/opt/data/home/.hermes/scripts/ai-scoreboard'):
   # After:
   def load_config(root='/root/.hermes/home/.hermes/scripts/ai-scoreboard'):
   ```

3. Line 33: Changed `ArgumentParser` default root path
   ```python
   # Before:
   parser.add_argument('--root', default='/opt/data/home/.hermes/scripts/ai-scoreboard')
   # After:
   parser.add_argument('--root', default='/root/.hermes/home/.hermes/scripts/ai-scoreboard')
   ```

### Delivery Script: `ai_scoreboard_deliver.py`
**Location:** `/root/.hermes/home/.hermes/scripts/ai-scoreboard/ai_scoreboard_deliver.py`

**Fixes Applied:**
1. Line 33: Changed `SCRIPT` path
   ```python
   # Before:
   SCRIPT = '/opt/data/home/.hermes/scripts/ai-scoreboard/ai_scoreboard.py'
   # After:
   SCRIPT = '/root/.hermes/home/.hermes/scripts/ai-scoreboard/ai_scoreboard.py'
   ```

2. Line 34: Changed `--root` argument path
   ```python
   # Before:
   result = subprocess.run([sys.executable, SCRIPT, '--root', '/opt/data/home/.hermes/scripts/ai-scoreboard'],
   # After:
   result = subprocess.run([sys.executable, SCRIPT, '--root', '/root/.hermes/home/.hermes/scripts/ai-scoreboard'],
   ```

## Verification Steps
1. Run the main script directly to ensure it works:
   ```bash
   cd /root/.hermes/home/.hermes/scripts/ai-scoreboard && python3 ai_scoreboard.py
   ```

2. Run the delivery script to test:
   ```bash
   cd /root/.hermes/home/.hermes/scripts/ai-scoreboard && python3 ai_scoreboard_deliver.py
   ```

3. Check for any remaining `/opt/data/home/.hermes/` paths in the scripts.

## Dependencies
Install required packages if missing:
```bash
pip3 install yfinance pandas matplotlib pyyaml
```

## Cron Job
Add to crontab:
```bash
30 8 * * 1-5 cd /root/.hermes/home/.hermes/scripts/ai-scoreboard && /usr/bin/python3 ai_scoreboard_deliver.py
```

## Key Lessons
- Always verify filesystem paths match actual locations
- Check for both direct variable assignments and function defaults
- Test scripts manually before cron deployment
- The AI Cohort Scoreboard generates charts and insider data, not just a simple watchlist