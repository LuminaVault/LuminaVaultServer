#!/usr/bin/env python3
"""
Diagnostic helper for portfolio_threshold_alerts.py.

When the script exits 0 with empty stdout, use this to understand why:
  - Are there recent KG decisions?
  - Are thresholds defined for those tickers?
  - What's the deduplication state?
  - When will suppressed alerts become eligible again?
"""

import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
import subprocess

def _hermes_home() -> Path:
    """Resolve HERMES_HOME the same way the alert script does."""
    from_env = os.environ.get('HERMES_HOME', '/opt/data')
    return Path(from_env) / '.hermes'

def main() -> int:
    hhome = _hermes_home()
    portfolio = hhome / 'portfolio'
    kg = hhome / 'knowledge_graph'

    print("=== Hermes Portfolio Threshold Alert Diagnostics ===\n")

    # 1. KG decisions
    kg_file = kg / 'entities.json'
    print(f"KG entities: {kg_file}")
    if kg_file.exists():
        entities = json.loads(kg_file.read_text())
        decisions = [e for e in entities.values() if e.get('type') == 'decision']
        print(f"  Total decisions: {len(decisions)}")
        cutoff = (datetime.now(timezone.utc).date() - timedelta(days=90))
        recent = []
        tickers_recent = set()
        for d in decisions:
            date_str = d.get('properties', {}).get('date', '')
            try:
                dec_date = datetime.strptime(date_str, '%Y-%m-%d').date()
                if dec_date >= cutoff:
                    recent.append(d)
                    tickers_recent.update(d.get('properties', {}).get('tickers', []))
            except Exception:
                pass
        print(f"  Recent (90d): {len(recent)} decision(s)")
        print(f"  Tickers in recent decisions: {sorted(tickers_recent)}")
    else:
        print("  ❌ KG entities file NOT found")
        return 1

    # 2. Thresholds
    thresh_file = portfolio / 'portfolio_thresholds.json'
    print(f"\nThresholds: {thresh_file}")
    if thresh_file.exists():
        thresholds = json.loads(thresh_file.read_text())
        print(f"  Configured tickers: {list(thresholds.keys())}")
        for t, cfg in thresholds.items():
            print(f"    {t}: {cfg['condition']} at ${cfg['threshold']:.2f}")
    else:
        print("  ❌ Thresholds file NOT found")
        return 1

    # 3. Overlap
    print("\n=== Coverage Analysis ===")
    with_thresh = [t for t in tickers_recent if t in thresholds]
    missing = [t for t in tickers_recent if t not in thresholds]
    print(f"Tickers with thresholds: {with_thresh}")
    if missing:
        print(f"⚠️  Tickers MISSING thresholds: {missing}")

    # 4. Alert state (deduplication)
    state_file = portfolio / 'alert_state.json'
    print(f"\nDeduplication state: {state_file}")
    if state_file.exists():
        state = json.loads(state_file.read_text())
        now = datetime.now(timezone.utc)
        print(f"  Tracked tickers: {list(state.keys())}")
        for ticker, events in state.items():
            for key, ts in events.items():
                last = datetime.fromisoformat(ts.replace('Z', '+00:00'))
                eligible = last + timedelta(hours=24)
                remaining = eligible - now
                cond = 'buy' if 'buy' in key else 'trim'
                thr = key.split('_')[0]
                print(f"    {ticker} {cond} ${thr}: last sent {last} → next eligible {eligible} (in {remaining})")
    else:
        print("  No alert state yet (no alerts have been sent)")

    # 5. Log tail
    log_file = portfolio / 'threshold_alerts.log'
    print(f"\nRecent log ({log_file}):")
    if log_file.exists():
        result = subprocess.run(['tail', '-5', str(log_file)], capture_output=True, text=True)
        print(result.stdout if result.stdout else "(log empty)")
    else:
        print("  No log file")

    return 0

if __name__ == '__main__':
    sys.exit(main())
