#!/usr/bin/env python3
"""
Stock Threshold Alert — Hourly check for tickers breaching user-defined thresholds.

Compares live prices against hard-coded threshold levels and emits an alert
message if ANY ticker is at or below its threshold. All platforms (Discord,
Telegram, Slack) receive the same report via separate per-platform cron jobs.

Usage (cron): This script runs hourly. Output goes to stdout; cron gatekeeper
delivers to the assigned platform.
"""

import http.client, json, os, datetime, sys, re

# ─── Thresholds ────────────────────────────────────────────────────────────────
# "below X" → alert when current_price <= X
THRESHOLDS = {
    "ZETA":  15.00,
    "AMD":   200.00,
    "AMZN":  205.00,
    "HIMS":  25.00,
    "OSCR":  13.00,
    "SOFI":  16.00,
    "KRKNF": 5.50,
    "ONDS":   8.00,
    "ABCL":   4.00,
    "GRAB":   3.50,
    "ASTS":  60.00,
    "TE":     4.50,
    "UBER":  72.00,
    "NFLX":  80.00,
    "NVO":   40.00,
    "NKE":   40.00,
    "SIDU":   3.50,
    # New additions (2026-04-28)
    "SMR":   10.00,   # current ~$11.70 → alert if drops below $10
    "FLNC":  10.00,   # current ~$12.27 → alert if drops below $10
    "RDW":    7.00,   # current ~$8.96  → alert if drops below $7
}

# Yahoo Finance ticker normalization (for symbols that need suffixes)
YAHOO_NORMALIZE = {
    "KRKNF": "KRKNF",   # Karsi (KOSPI) — Yahoo lists KRKNF as is
    "ONDS":  "ONDS",    # Ondas Holdings — checks as ONDS
    "A6I":   "A6I.F",   # example for Frankfurt suffix if ever added
}

# ─── Helpers ───────────────────────────────────────────────────────────────────
UA = "HermesStockAlert/1.0 (+https://hermes.dev)"

def yahoo_price(ticker: str) -> float | None:
    """Fetch latest price from Yahoo Finance chart API (v8)."""
    yt = YAHOO_NORMALIZE.get(ticker, ticker)
    # Quick meta endpoint to avoid full chart download
    url = f"/v8/finance/chart/{yt}?range=1d&interval=1m"
    try:
        conn = http.client.HTTPSConnection("query1.finance.yahoo.com", timeout=15)
        conn.request("GET", url, headers={"User-Agent": UA})
        resp = conn.getresponse()
        body = resp.read().decode("utf-8", errors="replace")
        conn.close()
        data = json.loads(body)
        # Price in data.chart.result[0].meta.regularMarketPrice
        result = data.get("chart", {}).get("result", [])
        if not result:
            return None
        meta = result[0].get("meta", {})
        price = meta.get("regularMarketPrice")
        if price is None:
            # Fallback: last close
            price = meta.get("chartPreviousClose")
        return float(price) if price is not None else None
    except Exception as e:
        print(f"⚠  {ticker}: fetch error → {e}", file=sys.stderr)
        return None

def fmt_price(p: float | None) -> str:
    if p is None:
        return "N/A"
    return f"${p:,.2f}"

# ─── Main ──────────────────────────────────────────────────────────────────────
def main():
    now = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M UTC")
    below = []   # (ticker, current, threshold)
    errors = []  # tickers that failed to fetch

    for ticker, threshold in sorted(THRESHOLDS.items()):
        price = yahoo_price(ticker)
        if price is None:
            errors.append(ticker)
            continue
        if price <= threshold:
            below.append((ticker, price, threshold))

    # ── Build output ──────────────────────────────────────────────────────────
    if not below:
        # No breaches — print concise status for cron logs
        print(f"✅  Stock Threshold Check — {now}")
        print(f"All {len(THRESHOLDS)} tickers above thresholds.")
        if errors:
            print(f"⚠  Failed to fetch: {', '.join(errors)}", file=sys.stderr)
        sys.exit(0)

    # At least one ticker breached
    lines = [
        f"🚨 **Stock Threshold Alert** — {now}",
        "",
        f"_{len(below)} ticker(s) at or below threshold:_",
        "",
    ]
    for ticker, price, threshold in below:
        diff_pct = ((price - threshold) / threshold) * 100 if threshold else 0
        status = "⬇️" if diff_pct < 0 else "⚠️"
        lines.append(f"  {status} **{ticker}**: {fmt_price(price)} (threshold: {fmt_price(threshold)})")
    if errors:
        lines.append(f"\n_⚠ Could not fetch: {', '.join(errors)}_")
    lines.append("")  # trailing newline
    print("\n".join(lines).strip())

    # Exit 0 even on breaches — cron delivers whatever we print
    sys.exit(0)

if __name__ == "__main__":
    main()
