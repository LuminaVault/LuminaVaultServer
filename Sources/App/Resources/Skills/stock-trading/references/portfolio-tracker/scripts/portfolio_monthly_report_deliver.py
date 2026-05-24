#!/usr/bin/env python3
"""
Portfolio Monthly Report → Discord/Telegram delivery
Wraps portfolio_monthly_review.py and sends the markdown via kb-report skill.
"""

import os, subprocess, sys, json
from datetime import datetime
from pathlib import Path

HOME = Path.home()
REVIEW_SCRIPT = HOME / ".hermes" / "scripts" / "portfolio_monthly_review.py"
REPORT_DIR    = HOME / ".hermes" / "portfolio" / "reports"
HERMES_BIN    = Path("/opt/hermes/bin/hermes")  # adjust if needed

# 1. Generate the review
result = subprocess.run([sys.executable, str(REVIEW_SCRIPT)], capture_output=True, text=True)
if result.returncode != 0:
    print("❌ Review generation failed:", result.stderr)
    sys.exit(1)

# Find the latest report
reports = sorted(REPORT_DIR.glob("review-*.md"), reverse=True)
if not reports:
    print("❌ No report generated")
    sys.exit(1)
latest = reports[0]
print(f"✅ Report generated: {latest}")

# 2. Optionally deliver to Discord/Telegram via Hermes skill
# Hermes skill invocation: `hermes skills run kb-report --args …`
# Our platform integration: send_message via the agent gateway
# Since we're inside a cron session, we use send_message tool directly
# But cron cannot use interactive tools — we shell out to `hermes` CLI

# Try local delivery first (prints to stdout of cron)
content = latest.read_text()
print("\n=== REPORT CONTENT ===\n")
print(content)
print("\n=== END REPORT ===\n")

# If HERMES_PATH is available, attempt platform delivery
if HERMES_BIN.exists():
    # Hermes skills run: kb-report takes --content or reads stdin
    # We'll try stdin approach
    proc = subprocess.Popen(
        [str(HERMES_BIN), "skills", "run", "kb-report", "--args", f'--from-stdin --title "📊 Monthly Portfolio Review — {datetime.now().strftime("%B %Y")}"'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    out, err = proc.communicate(content)
    print("kb-report stdout:", out[:300])
    print("kb-report stderr:", err[:300] if err else "")
else:
    print("(Hermes CLI not found at", HERMES_BIN, "— skipping platform delivery)")

