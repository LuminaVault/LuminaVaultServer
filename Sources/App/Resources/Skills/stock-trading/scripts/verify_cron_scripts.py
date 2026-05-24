#!/usr/bin/env python3
"""
Verify cron script path resolution for all defined cron jobs.

Usage:
  python3 verify_cron_scripts.py            # check all jobs
  python3 verify_cron_scripts.py job_id     # check one job
  python3 verify_cron_scripts.py --fix      # create missing symlinks (if safe)

This script reads cron/jobs.json, resolves each job's script path the same way
Hermes does (via HERMES_HOME/scripts), and reports missing files. Optionally
creates symlinks from the expected location to ~/.hermes/scripts/ when a
script exists in the user's personal scripts dir but not in HERMES_HOME/scripts/.
"""

import json
import os
import sys
from pathlib import Path

HERMES_HOME = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes")).resolve()
SCRIPTS_DIR = (HERMES_HOME / "scripts").resolve()
USER_HERMES_SCRIPTS = (Path.home() / ".hermes" / "scripts").resolve()

def resolve_script_path(script_name: str) -> Path:
    """Resolve a cron job's script name the same way Hermes does."""
    return (SCRIPTS_DIR / script_name).resolve()

def check_job(job):
    job_id = job["id"]
    name = job["name"]
    script = job.get("script")
    if not script:
        return None  # no script configured

    expected = resolve_script_path(script)
    exists = expected.exists()
    status = "✅" if exists else "❌"

    details = {
        "job_id": job_id,
        "name": name,
        "script": script,
        "expected_path": str(expected),
        "exists": exists,
    }

    if not exists:
        # Suggest: does it exist in the user's personal Hermes scripts?
        alt = USER_HERMES_SCRIPTS / script
        if alt.exists():
            details["suggested_symlink"] = str(alt)
            details["fix_command"] = (
                f"ln -s {alt} {expected}"
            )

    return details

def main():
    jobs_path = Path("/opt/data/cron/jobs.json")
    if not jobs_path.exists():
        print(f"❌ Cron jobs config not found: {jobs_path}")
        sys.exit(1)

    with open(jobs_path) as f:
        data = json.load(f)

    jobs = data.get("jobs", [])
    target_job_id = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else None
    fix_mode = "--fix" in sys.argv

    print(f"HERMES_HOME   : {HERMES_HOME}")
    print(f"SCRIPTS_DIR   : {SCRIPTS_DIR}")
    print(f"USER_SCRIPTS  : {USER_HERMES_SCRIPTS}")
    print()

    missing = []
    for job in jobs:
        if target_job_id and job["id"] != target_job_id:
            continue
        result = check_job(job)
        if result is None:
            continue
        status = "✅" if result["exists"] else "❌"
        print(f"{status} {job['name']}  (ID: {job['id']})")
        print(f"     script : {result['script']}")
        print(f"     path   : {result['expected_path']}")
        if not result["exists"]:
            missing.append(result)
            if "suggested_symlink" in result:
                print(f"     found  : {result['suggested_symlink']}")
                if fix_mode:
                    src = result["suggested_symlink"]
                    dst = result["expected_path"]
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    os.symlink(src, dst)
                    print(f"     ✨ created symlink: {dst} -> {src}")
                else:
                    print(f"     fix    : {result['fix_command']}")
        print()

    if missing:
        print(f"‼️  {len(missing)} script(s) missing from HERMES_HOME/scripts/")
        if not fix_mode:
            print("   Run with --fix to create symlinks automatically.")
        sys.exit(1)
    else:
        print("✅ All configured cron scripts are accessible.")
        sys.exit(0)

if __name__ == "__main__":
    main()
