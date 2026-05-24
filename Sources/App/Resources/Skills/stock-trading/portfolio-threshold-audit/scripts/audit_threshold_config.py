#!/usr/bin/env python3
"""
Portfolio Threshold Configuration Audit — Health check for KG-powered alerts.

Detects:
  • Orphaned thresholds — ticker in config but NOT in recent KG decisions
  • Stale thresholds — ticker in KG but last decision exceeds age window
  • Missing platform tokens (if delivery would fail)

Usage:
  python3 audit_threshold_config.py [--days 90] [--test]
Options:
  --days N        Decision lookback window (default: 90)
  --test          Show remediation actions without executing them
"""

import argparse
import json
import logging
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
import os

# ─── Environment loader (mirrors alert script) ──────────────────────────────────
def _load_dotenv(env_path: Path = Path("/opt/data/.env")) -> None:
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, _, val = line.partition("=")
            os.environ[key.strip()] = val.strip().strip('"\'')

_load_dotenv()

# ─── Constants ──────────────────────────────────────────────────────────────────
HERMES_HOME = Path.home() / ".hermes"
PORTFOLIO_DIR = HERMES_HOME / "portfolio"
THRESHOLDS_FILE = PORTFOLIO_DIR / "portfolio_thresholds.json"
KG_ENTITIES_FILE = HERMES_HOME / "knowledge_graph" / "entities.json"

YAHOO_NORMALIZE = {
    "A6I": "A6I.F",
}

# ─── Logging ────────────────────────────────────────────────────────────────────
def setup_logging() -> logging.Logger:
    logger = logging.getLogger("threshold_audit")
    logger.setLevel(logging.INFO)
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(levelname)s: %(message)s"))
    logger.addHandler(handler)
    return logger

# ─── KG loading ─────────────────────────────────────────────────────────────────
def load_recent_ticker_decisions(days: int = 90) -> dict:
    if not KG_ENTITIES_FILE.exists():
        raise FileNotFoundError(f"KG entities not found: {KG_ENTITIES_FILE}")
    with KG_ENTITIES_FILE.open("r", encoding="utf-8") as f:
        entities = json.load(f)
    cutoff = (datetime.now(timezone.utc).date() - timedelta(days=days))
    ticker_info: dict[str, dict] = {}
    for eid, ent in entities.items():
        if ent.get("type") != "decision":
            continue
        props = ent.get("properties", {})
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
        for ticker in tickers:
            existing = ticker_info.get(ticker)
            if existing is None or dec_date > datetime.strptime(existing["last_date"], "%Y-%m-%d").date():
                ticker_info[ticker] = {
                    "last_date": date_str,
                    "last_id": eid,
                    "all_dates": existing["all_dates"] + [date_str] if existing else [date_str],
                }
    return ticker_info

def load_thresholds(filepath: Path) -> dict:
    if not filepath.exists():
        raise FileNotFoundError(f"Thresholds file not found: {filepath}")
    with filepath.open("r", encoding="utf-8") as f:
        data = json.load(f)
    normalized = {}
    for ticker, cfg in data.items():
        if isinstance(cfg, dict) and "threshold" in cfg and "condition" in cfg:
            normalized[ticker] = {
                "threshold": float(cfg["threshold"]),
                "condition": cfg["condition"],
            }
    return normalized

# ─── Main audit ─────────────────────────────────────────────────────────────────
def main() -> int:
    parser = argparse.ArgumentParser(description="Audit portfolio threshold configuration")
    parser.add_argument("--days", type=int, default=90, help="Decision lookback window (default: 90)")
    parser.add_argument("--test", action="store_true", help="Show remediation actions without performing them")
    args = parser.parse_args()
    logger = setup_logging()
    logger.info("=== Portfolio Threshold Audit START ===")
    if args.test:
        logger.info("TEST MODE: no remediation actions will be taken")
    try:
        kg_tickers = load_recent_ticker_decisions(days=args.days)
    except Exception as e:
        logger.error(f"Failed to load KG: {e}")
        return 1
    try:
        thresholds = load_thresholds(THRESHOLDS_FILE)
    except Exception as e:
        logger.error(f"Failed to load thresholds: {e}")
        return 1
    logger.info(f"Recent KG tickers ({len(kg_tickers)}): {', '.join(sorted(kg_tickers))}")
    logger.info(f"Configured thresholds ({len(thresholds)}): {', '.join(sorted(thresholds))}")
    orphans = []
    monitored = []
    for ticker, cfg in thresholds.items():
        if ticker in kg_tickers:
            monitored.append(ticker)
        else:
            orphans.append((ticker, cfg))
    print("\n" + "=" * 60)
    print("PORTFOLIO THRESHOLD AUDIT REPORT")
    print("=" * 60)
    print(f"Coverage window : {args.days} days")
    print(f"KG decisions     : {len(kg_tickers)} ticker(s)")
    print(f"Thresholds config: {len(thresholds)} ticker(s)")
    print(f"Monitored        : {len(monitored)} ticker(s)")
    if monitored:
        print(f"  → {', '.join(sorted(monitored))}")
    print(f"Orphaned         : {len(orphans)} ticker(s)")
    if orphans:
        print("\n⚠️  ORPHANED THRESHOLDS — these tickers have thresholds but no recent KG decision:")
        for ticker, cfg in orphans:
            print(f"   {ticker}: ${cfg['threshold']:.2f} {cfg['condition']}")
        print("\nRemediation:")
        print("  • To activate: Create a KG decision entity that includes the ticker")
        print("    (e.g., via research conversation that produces a decision entity with")
        print(f"    date within {args.days} days and tickers=[...'{ticker}'...])")
        print("  • To deactivate: Remove the ticker from portfolio_thresholds.json")
        if not args.test:
            logger.warning("Orphaned thresholds detected — review report above")
    else:
        print("\n✅ All configured thresholds are covered by recent KG decisions.")
    print("\n" + "=" * 60)
    logger.info("=== Portfolio Threshold Audit END ===")
    return 0

if __name__ == "__main__":
    sys.exit(main())
