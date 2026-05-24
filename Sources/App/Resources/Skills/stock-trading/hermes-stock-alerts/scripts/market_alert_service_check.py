#!/usr/bin/env python3
"""
Market Alert Service Health Check
Checks the market alert service environment and reports status.
"""

import os
import sys
import json
from datetime import datetime

def main():
    SERVICE_DIR = os.path.expanduser("~/hermes/market-alerts")
    
    print("📊 Market Alert Service Health Check")
    print("=" * 60)
    print()
    
    # Check service directory
    if not os.path.isdir(SERVICE_DIR):
        print("❌ Service directory not found")
        print(f"   Expected: {SERVICE_DIR}")
        print("   The market alert service may not be installed.")
        sys.exit(1)
    
    print(f"✅ Service directory: {SERVICE_DIR}")
    
    # Check for required scripts
    required_scripts = [
        "market_alert_service.py",
        "service_core.py",
        "scripts/market_fetcher.py",
        "scripts/alert_engine.py"
    ]
    
    missing = []
    for script in required_scripts:
        path = os.path.join(SERVICE_DIR, script) if not script.startswith("scripts/") else os.path.join(SERVICE_DIR, script)
        if os.path.exists(path):
            print(f"✅ {script}")
        else:
            print(f"❌ Missing: {script}")
            missing.append(script)
    
    if missing:
        print(f"\n❌ {len(missing)} required file(s) missing")
        sys.exit(1)
    
    # Check data directory
    data_dir = os.path.join(SERVICE_DIR, "data")
    if os.path.isdir(data_dir):
        files = [f for f in os.listdir(data_dir) if f.endswith('.json')]
        print(f"✅ Data directory: {len(files)} files")
    else:
        print("⚠️  Data directory missing (may be okay if never run)")
    
    # Check alerts directory
    alerts_dir = os.path.join(SERVICE_DIR, "alerts")
    if os.path.isdir(alerts_dir):
        files = [f for f in os.listdir(alerts_dir) if f.endswith('.json')]
        print(f"✅ Alerts directory: {len(files)} files")
    else:
        print("⚠️  Alerts directory missing (may be okay if never run)")
    
    # Check configuration
    config_path = os.path.join(SERVICE_DIR, "config.json")
    if os.path.exists(config_path):
        print("✅ Config file exists")
        try:
            with open(config_path, 'r') as f:
                config = json.load(f)
            print(f"   Service name: {config.get('market_alert_agent', {}).get('name', 'N/A')}")
        except Exception as e:
            print(f"❌ Error reading config: {e}")
    else:
        print("❌ Config file missing")
    
    print()
    print("=" * 60)
    print("💡 To run a one-time check: python3 -c \"from service_core import MarketAlertService; MarketAlertService().process_cycle()\"")
    print("=" * 60)

if __name__ == "__main__":
    main()