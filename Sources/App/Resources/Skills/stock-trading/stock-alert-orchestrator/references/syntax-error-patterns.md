# Python Syntax Error Patterns in Cron-Deployed Scripts

## Pattern: Unterminated Multi-line f-strings

### Symptom
```
SyntaxError: unterminated string literal (detected at line N)
```
The error points to a line containing an f-string, often near the end of a multi-line construct.

### Root Cause
File corruption or editor mishandling when splitting multi-line f-strings across physical lines. The f-string content spans multiple lines, but the closing quote is on a separate line with improper escaping.

#### Broken Example (what we found)
```python
formatted = (
    f"{direction} *{symbol}* {emoji}\n"
    f"💰 Price: *${price:,.2f}*\n"
    f"📊 Change: *{'+' if change_pct >= 0 else ''}{change_pct:.2f}%*\n"
)  # <- CORRECT: each line ends with \n" inside the quotes
```

When corrupted, the bytes may appear as:
```python
formatted = (
    f"{direction} *{symbol}* {emoji}\n"   # <- actual newline in source, not \n
    "                                        # next line starts with bare quote
    f"💰 Price: *${price:,.2f}*\n"
)
```
Or the closing quote may be on the next line with incorrect escaping, producing an unterminated string.

### Detection
Run against each script **before execution**:
```bash
python3 -m py_compile scripts/stock_alert_orchestrator.py
python3 -m py_compile scripts/deliver_telegram.py
```
This checks syntax without running the code. It catches unterminated strings, missing imports, and other compile-time errors.

### Fix Strategy
1. **Identify the exact function/section** containing the broken f-string.
2. **Replace the entire multi-line f-string block** with a clean version using proper continuation (each part ends with `\n"` inside the f-string).
3. **Verify with py_compile** after fixing.

#### Replacement Template
For Telegram message formatting (the common culprit):
```python
def build_telegram_text(alert: dict) -> str:
    symbol = alert.get("symbol", "??")
    price = alert.get("price", 0.0)
    change_pct = alert.get("change_pct", 0.0)
    message = alert.get("message", "")

    direction = "📈" if change_pct >= 0 else "📉"
    emoji = "🟢" if change_pct >= 0 else "🔴"

    formatted = (
        f"{direction} *{symbol}* {emoji}\n"
        f"💰 Price: *${price:,.2f}*\n"
        f"📊 Change: *{'+' if change_pct >= 0 else ''}{change_pct:.2f}%*\n"
    )
    if message:
        formatted += f"\n_{message}_\n"
    formatted += f"\n`{datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')}`"

    return formatted
```

## Pattern: Missing Imports

### Symptom
```
NameError: name 'os' is not defined
```
or similar for `json`, `datetime`, etc.

### Root Cause
File uses `os.getenv()`, `json.loads()`, or other module functions but forgot `import os` / `import json` at the top.

### Detection
- Python static analysis (`py_compile` will also flag this)
- Read error traceback to see which name is missing

### Fix
Add the missing import at the top with other imports:
```python
import json
import time
import datetime
import os  # <- added
from typing import Optional, Dict, Any
```

## General Verification Workflow

For any cron-deployed Python script bundle:
1. Compile-check every `.py` file: `python3 -m py_compile <file>`
2. Import-check modules to catch missing deps: `python3 -c "import stock_client"`
3. Run orchestrator with `PYTHONUNBUFFERED=1` to see live output
4. Check log directory exists and is writable before first run

## Why These Happen in This Project

- Scripts edited in different environments (terminal, IDE, web editors) with varying quote/newline handling
- Multi-line f-strings with embedded Unicode emojis and braces are particularly fragile in plain text editors
- Git history may show clean versions, but working copies can get corrupted by editor auto-formatting or copy-paste from chat/email

### Prevention
- Keep scripts under version control; diff after edits
- Use a consistent editor that shows invisible characters (newlines, spaces)
- Avoid manual re-formatting of f-strings; rewrite whole blocks when changing
