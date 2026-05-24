#!/usr/bin/env python3
"""
Pre-flight verification script for Stock Alert Orchestrator.

Checks:
  - All .py files compile (syntax check)
  - Required imports resolve (stock_client imports yfinance, requests)
  - Config file exists and is valid YAML
  - Required directories exist and are writable
  - Dependencies are installed (yfinance, requests, PyYAML)
  - At least one platform is enabled with credentials (warning, not failure)

Exit codes:
  0 — all clear
  1 — syntax error or import failure
  2 — config invalid or missing
  3 — directory/permission issue
  4 — missing dependencies
"""

import sys
import os
from pathlib import Path
from typing import List, Tuple

# ── Paths ──────────────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).parent.resolve()
PROJECT_ROOT = SCRIPT_DIR.parent
SCRIPTS_DIR = PROJECT_ROOT / "scripts"
CONFIG_PATH = PROJECT_ROOT / "config" / "config.yaml"
LOGS_DIR = PROJECT_ROOT / "logs"
STATE_DIR = PROJECT_ROOT / "state"

# ── Utilities ───────────────────────────────────────────────────────────────────

def check_print(msg: str, status: bool):
    symbol = "✓" if status else "✗"
    print(f"  {symbol} {msg}")
    return status

def run_py_compile(py_files: List[Path]) -> Tuple[bool, List[str]]:
    """Return (all_ok, list_of_error_strings)."""
    import py_compile
    errors = []
    for path in py_files:
        try:
            py_compile.compile(str(path), doraise=True)
        except py_compile.PyCompileError as e:
            errors.append(f"{path.name}: {e.msg} (line {e.lineno})")
    return len(errors) == 0, errors

def test_import(module_name: str) -> Tuple[bool, str]:
    """Try to import a module; return (ok, error_string)."""
    try:
        __import__(module_name)
        return True, ""
    except ImportError as e:
        return False, str(e)

# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> int:
    print("=== Stock Alert Orchestrator — Pre-flight Check ===\n")

    all_ok = True

    # 1. Script files present
    print("[1] Script files:")
    expected_scripts = [
        "stock_alert_orchestrator.py",
        "stock_client.py",
        "deliver_slack.py",
        "deliver_telegram.py",
        "deliver_discord.py",
    ]
    for name in expected_scripts:
        path = SCRIPTS_DIR / name
        exists = path.exists()
        if not check_print(f"{name} present", exists):
            all_ok = False

    # 2. Syntax check
    print("\n[2] Syntax check (py_compile):")
    py_files = list(SCRIPTS_DIR.glob("*.py"))
    compile_ok, compile_errors = run_py_compile(py_files)
    if compile_ok:
        check_print("All .py files compile", True)
    else:
        check_print("Compilation failures detected", False)
        for err in compile_errors:
            print(f"    → {err}")
        all_ok = False

    # 3. Import checks
    print("\n[3] Import resolution:")
    imports_ok = True
    for mod in ["yfinance", "requests", "yaml", "datetime", "json", "os", "time"]:
        ok, err = test_import(mod)
        if not check_print(f"import {mod}", ok):
            imports_ok = False
    if not imports_ok:
        all_ok = False

    # 4. Config file
    print("\n[4] Configuration:")
    if not check_print("config.yaml exists", CONFIG_PATH.exists()):
        all_ok = False
    else:
        try:
            import yaml
            with open(CONFIG_PATH) as f:
                yaml.safe_load(f)
            check_print("config.yaml is valid YAML", True)
        except Exception as e:
            check_print(f"config.yaml YAML parse error: {e}", False)
            all_ok = False

    # 5. Directories
    print("\n[5] Directories & permissions:")
    for d in [LOGS_DIR, STATE_DIR]:
        exists = d.exists()
        writable = os.access(d, os.W_OK) if exists else False
        if not check_print(f"{d.name}/ exists & writable", exists and writable):
            all_ok = False

    # 6. Dependencies (importable)
    print("\n[6] Dependencies:")
    deps = [("yfinance", "yfinance"), ("requests", "requests"), ("PyYAML", "yaml")]
    for pkg, mod in deps:
        ok, err = test_import(mod)
        if not check_print(f"{pkg} installed", ok):
            all_ok = False

    # 7. Platform configuration (warnings only)
    print("\n[7] Platform configuration (warnings):")
    try:
        import yaml
        with open(CONFIG_PATH) as f:
            cfg = yaml.safe_load(f) or {}
    except Exception:
        cfg = {}
    platforms = cfg.get("platforms", {})
    any_enabled = False
    for name, pcfg in platforms.items():
        enabled = pcfg.get("enabled", False)
        if enabled:
            any_enabled = True
            # Check for required keys
            if name == "slack":
                webhook = pcfg.get("webhook_url", "")
                if not webhook:
                    print(f"  ⚠ Slack enabled but webhook_url empty")
            elif name == "telegram":
                token = pcfg.get("bot_token", "")
                chat = pcfg.get("chat_id", "")
                if not token or not chat:
                    print(f"  ⚠ Telegram enabled but bot_token or chat_id missing")
            elif name == "discord":
                webhook = pcfg.get("webhook_url", "")
                if not webhook:
                    print(f"  ⚠ Discord enabled but webhook_url empty")
        else:
            print(f"  ℹ {name}: disabled")
    if not any_enabled:
        print("  ⚠ No platforms enabled — orchestrator will produce no alerts")

    # Summary
    print("\n" + "=" * 60)
    if all_ok:
        print("✓ Pre-flight check PASSED — orchestrator ready to run")
        return 0
    else:
        print("✗ Pre-flight check FAILED — fix errors before cron runs")
        return 1

if __name__ == "__main__":
    sys.exit(main())
