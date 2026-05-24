#!/usr/bin/env python3
"""
Portfolio threshold alerts — quick health check.
Verifies KG decisions, thresholds, deduplication state, and log recency.
Use: python3 portfolio_threshold_healthcheck.py
"""
import json
import os
import sys
from datetime import datetime, timezone, timedelta

HERMES_HOME = os.path.expanduser('~/.hermes')
if not os.path.exists(HERMES_HOME):
    HERMES_HOME = '/opt/data/.hermes'  # fallback for this deployment

PATHS = {
    'kg': os.path.join(HERMES_HOME, 'knowledge_graph', 'entities.json'),
    'thresholds': os.path.join(HERMES_HOME, 'portfolio', 'portfolio_thresholds.json'),
    'state': os.path.join(HERMES_HOME, 'portfolio', 'alert_state.json'),
    'log': os.path.join(HERMES_HOME, 'portfolio', 'threshold_alerts.log'),
}

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:
        return {'__error__': str(e)}

def main():
    print("=" * 60)
    print("  Portfolio Threshold Alerts — Health Check")
    print("=" * 60)

    # 1. KG decisions (flat-dict structure!)
    kg = load_json(PATHS['kg'])
    if '__error__' in kg:
        print(f"❌ KG file unreadable: {kg['__error__']}")
        decisions = []
    else:
        # KG is a flat dict, not {"entities": [...]}
        decisions = [v for v in kg.values() if isinstance(v, dict) and v.get('type') == 'decision']
        print(f"✅ KG decisions (past 90d): {len(decisions)}")
        if decisions:
            # Sort by date descending
            sorted_dec = sorted(decisions, key=lambda d: d.get('properties', {}).get('date', ''), reverse=True)
            recent = sorted_dec[0]
            tickers = recent.get('properties', {}).get('tickers', [])
            print(f"   Most recent: {recent.get('properties',{}).get('date')} → {len(tickers)} tickers")
            print(f"   Sample tickers: {tickers[:10]}")

    # 2. Thresholds
    thresholds = load_json(PATHS['thresholds'])
    if '__error__' in thresholds:
        print(f"❌ Thresholds file unreadable: {thresholds['__error__']}")
        thr_list = []
    else:
        thr_list = [(t, c['condition'], c['threshold']) for t, c in thresholds.items()]
        print(f"✅ Configured thresholds: {len(thr_list)} tickers")
        for t, c, p in thr_list:
            print(f"   {t}: {c} ${p:.2f}")

    # 3. Alert state (deduplication)
    state = load_json(PATHS['state'])
    if '__error__' in state:
        print(f"❌ Alert state unreadable: {state['__error__']}")
    else:
        now = datetime.now(timezone.utc)
        suppressed = []
        eligible = []
        for ticker, conditions in state.items():
            for key, ts_str in conditions.items():
                ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
                remaining = (ts + timedelta(hours=24)) - now
                if remaining.total_seconds() > 0:
                    suppressed.append((ticker, key, remaining))
                else:
                    eligible.append((ticker, key))
        print(f"✅ Deduplication state: {len(suppressed)} suppressed, {len(eligible)} eligible")
        if suppressed:
            print("   Suppressed:")
            for ticker, key, rem in sorted(suppressed, key=lambda x: x[2])[:5]:
                hrs = int(rem.total_seconds() // 3600)
                mins = int((rem.total_seconds() % 3600) // 60)
                print(f"     {ticker} {key} → eligible in {hrs}h {mins}m")
        if eligible:
            print("   Eligible NOW:")
            for ticker, key in eligible:
                print(f"     {ticker} {key}")

    # 4. Intersection (monitored set)
    if decisions and thr_list:
        decision_tickers = set()
        for dec in decisions:
            decision_tickers.update(dec.get('properties', {}).get('tickers', []))
        thresholded_tickers = set(thresholds.keys())
        monitored = decision_tickers & thresholded_tickers
        print(f"✅ Monitored set (KG ∩ thresholds): {len(monitored)} tickers")
        inactive = thresholded_tickers - decision_tickers
        if inactive:
            print(f"   Inactive (threshold but no KG decision): {sorted(inactive)}")

    # 5. Log recency
    try:
        stat = os.stat(PATHS['log'])
        mtime = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc)
        age = datetime.now(timezone.utc) - mtime
        print(f"✅ Log file: {PATHS['log']}")
        print(f"   Last modified: {mtime.strftime('%Y-%m-%d %H:%M:%S UTC')} ({age.total_seconds():.0f}s ago)")
    except FileNotFoundError:
        print(f"❌ Log file not found: {PATHS['log']}")

    print("=" * 60)

if __name__ == '__main__':
    main()
