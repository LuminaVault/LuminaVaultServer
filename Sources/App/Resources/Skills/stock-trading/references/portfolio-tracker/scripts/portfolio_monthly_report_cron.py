#!/usr/bin/env python3
"""
Monthly portfolio review cron job — generates and delivers report.
1. Runs portfolio_monthly_review.py
2. Saves markdown to ~/.hermes/portfolio/reports/
3. Uses send_message tool via Hermes agent to deliver to Discord/Telegram
"""

import os, subprocess, sys, json
from datetime import datetime
from pathlib import Path

HOME = Path.home()
REVIEW_SCRIPT = HOME / ".hermes" / "scripts" / "portfolio_monthly_review.py"
REPORT_DIR    = HOME / ".hermes" / "portfolio" / "reports"

# Step 1: Generate report
result = subprocess.run([sys.executable, str(REVIEW_SCRIPT)], capture_output=True, text=True)
if result.returncode != 0:
    print("❌ Review generation failed:", result.stderr)
    sys.exit(1)

# Find latest report
reports = sorted(REPORT_DIR.glob("review-*.md"), reverse=True)
if not reports:
    print("❌ No report file found")
    sys.exit(1)
report_path = reports[0]
print(f"✅ Report: {report_path}")

# Step 2: Deliver via Hermes send_message
# We use the agent's send_message tool programmatically via a temporary dump
# Approach: write to a temp file and let the cron agent deliver it
# Cron jobs in Hermes run in fresh sessions — we can't call tools directly from here.
# Instead, we rely on the cron delivery mechanism (--deliver origin or platform)
#
# This script is designed to be called by a Hermes cron job with deliver='origin' or 'discord'
# and will simply output the report to stdout for the cron engine to route.
#
# Usage in Hermes CLI:
#   hermes cron create --name "Monthly Portfolio Review" \
#     --schedule "0 9 1 * *" \
#     --prompt "$(cat ~/.hermes/scripts/portfolio_monthly_report_cron.py)" \
#     --deliver origin
#
# The script below just reads and prints the generated report.

content = report_path.read_text()
print("\n" + "="*60)
print("📊 PORTFOLIO MONTHLY REVIEW — " + datetime.now().strftime("%B %Y"))
print("="*60 + "\n")
print(content)
print("\n" + "="*60)
print("End of report")

