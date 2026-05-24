#!/usr/bin/env python3
"""
Quick status summary for portfolio threshold alerts.
Shows current prices, suppression status, next eligibility times, and KG decision sources.
"""

import json
import os
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

# Resolve HERMES_HOME (same logic as main script)
_home_from_env = os.environ.get('HERMES_HOME')
if _home_from_env:
    HERMES_HOME = Path(_home_from_env) / ".hermes"
else:
    HERMES_HOME = Path.home() / ".hermes"

PORTFOLIO_DIR = HERMES_HOME / "portfolio"
THRESHOLDS_FILE = PORTFOLIO_DIR / "portfolio_thresholds.json"
ALERT_STATE_FILE = PORTFOLIO_DIR / "alert_state.json"
KG_ENTITIES_FILE = HERMES_HOME / "knowledge_graph" / "entities.json"

UA = "HermesAlertStatus/1.0"


def yahoo_price(ticker: str) -> float | None:
    import http.client
    url_path = f"/v8/finance/chart/{ticker}?range=1d&interval=1d"
    try:
        conn = http.client.HTTPSConnection("query1.finance.yahoo.com", timeout=10)
        conn.request("GET", url_path, headers={"User-Agent": UA})
        resp = conn.getresponse()
        body = resp.read().decode("utf-8", errors="replace")
        conn.close()
        data = json.loads(body)
        result = data.get("chart", {}).get("result", [])
        if not result:
            return None
        meta = result[0].get("meta", {})
        price = meta.get("regularMarketPrice")
        if price is None:
            price = meta.get("chartPreviousClose")
        return float(price) if price is not None else None
    except Exception:
        return None


def load_recent_ticker_decisions(days: int = 90) -> dict:
    if not KG_ENTITIES_FILE.exists():
        return {}
    with KG_ENTITIES_FILE.open("r", encoding="utf-8") as f:
        entities = json.load(f)
    cutoff = (datetime.now(timezone.utc).date() - timedelta(days=days))
    ticker_decisions = {}
    for entity_id, entity in entities.items():
        if entity.get("type") != "decision":
            continue
        props = entity.get("properties", {})
        date_str = props.get("date")
        tickers = props.get("tickers", [])
        if not date_str or not tickers:
            continue
        try:
            dec_date = datetime.strptime(date_str, "%Y-%m-%d").date()
        except ValueError:
            continue
        if dec_date < cutoff:
            continue
        dec_type = props.get("type", "decision")
        for ticker in tickers:
            existing = ticker_decisions.get(ticker)
            if existing is None or dec_date > datetime.strptime(existing["date"], "%Y-%m-%d").date():
                ticker_decisions[ticker] = {
                    "date": date_str,
                    "type": dec_type,
                    "id": entity_id,
                }
    return ticker_decisions


def load_thresholds() -> dict:
    if not THRESHOLDS_FILE.exists():
        return {}
    try:
        with THRESHOLDS_FILE.open("r", encoding="utf-8") as f:
            data = json.load(f)
        normalized = {}
        for ticker, cfg in data.items():
            if isinstance(cfg, dict) and "threshold" in cfg and "condition" in cfg:
                normalized[ticker] = {
                    "threshold": float(cfg["threshold"]),
                    "condition": cfg["condition"],
                }
        return normalized
    except Exception:
        return {}


def load_alert_state() -> dict:
    if not ALERT_STATE_FILE.exists():
        return {}
    try:
        with ALERT_STATE_FILE.open("r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def main() -> int:
    now = datetime.now(timezone.utc)
    print(f"=== Portfolio Threshold Alert Status ===")
    print(f"Time: {now.strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print()

    # Load data
    ticker_decisions = load_recent_ticker_decisions(days=90)
    thresholds = load_thresholds()
    alert_state = load_alert_state()

    if not ticker_decisions:
        print("No recent KG decisions found (past 90 days).")
        return 0

    # Determine monitored tickers
    tickers_with_thresholds = [t for t in ticker_decisions if t in thresholds]
    if not tickers_with_thresholds:
        print("Recent decision tickers have no threshold entries.")
        print(f"Decision tickers: {sorted(ticker_decisions.keys())}")
        print(f"Thresholds defined: {sorted(thresholds.keys())}")
        return 0

    print(f"Monitored: {len(tickers_with_thresholds)} ticker(s) from recent decisions")
    print()

    # Fetch prices
    prices = {}
    for ticker in tickers_with_thresholds:
        prices[ticker] = yahoo_price(ticker)

    # Build status table
    print(f"{'Ticker':6s} | {'Price':>8s} | {'Thr':>8s} | {'Cond':>5s} | {'Crossed?':>8s} | {'Last Alert':>19s} | {'Eligible In':>12s}")
    print("-" * 85)

    for ticker in sorted(tickers_with_thresholds):
        price = prices.get(ticker)
        cfg = thresholds[ticker]
        thr_val = cfg["threshold"]
        condition = cfg["condition"]
        price_str = f"${price:.2f}" if price is not None else "N/A"

        crossed = False
        if price is not None:
            if condition == "buy" and price <= thr_val:
                crossed = True
            elif condition == "trim" and price >= thr_val:
                crossed = True

        crossed_str = "YES" if crossed else "no"

        # Check suppression
        state_key = f"{thr_val:.2f}_{condition}"
        ticker_state = alert_state.get(ticker, {})
        last_iso = ticker_state.get(state_key)
        if last_iso:
            last = datetime.fromisoformat(last_iso.replace("Z", "+00:00"))
            remaining = timedelta(hours=24) - (now - last)
            if remaining.total_seconds() > 0:
                hrs = int(remaining.total_seconds() // 3600)
                mins = int((remaining.total_seconds() % 3600) // 60)
                eligible_str = f"{hrs}h {mins}m"
                last_str = last.strftime("%m-%d %H:%M UTC")
            else:
                eligible_str = "NOW"
                last_str = last.strftime("%m-%d %H:%M UTC")
        else:
            eligible_str = "never"
            last_str = "never"

        print(f"{ticker:6s} | {price_str:8s} | ${thr_val:7.2f} | {condition:5s} | {crossed_str:8s} | {last_str:19s} | {eligible_str:12s}")

    print()
    print("=== KG Decision Sources ===")
    for ticker in sorted(tickers_with_thresholds):
        dec = ticker_decisions.get(ticker)
        if dec:
            print(f"  {ticker:6s} → {dec.get('date')} ({dec.get('type')})")

    print()
    print("=== Alert State Summary ===")
    for ticker in sorted(alert_state.keys()):
        entries = alert_state[ticker]
        for key, ts in entries.items():
            last = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            remaining = timedelta(hours=24) - (now - last)
            if remaining.total_seconds() > 0:
                status = "SUPPRESSED"
            else:
                status = "ELIGIBLE"
            print(f"  {ticker:6s} | {key:12s} → {status}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
