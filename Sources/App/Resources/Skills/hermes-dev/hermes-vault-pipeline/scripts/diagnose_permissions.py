#!/usr/bin/env python3
"""Quick diagnostic for vault pipeline permission barriers."""

import os
import sys
import stat
import pathlib
import subprocess

VAULT_ROOT = pathlib.Path("/opt/data/obsidian-vault")
AGENT_VAULT = "FACorreia"


def check_vault_paths():
    print("=== Vault tree ownership ===")
    paths = [
        VAULT_ROOT,
        VAULT_ROOT / AGENT_VAULT,
        VAULT_ROOT / AGENT_VAULT / "wiki",
        VAULT_ROOT / AGENT_VAULT / "Raw",
    ]
    for p in paths:
        try:
            st = p.stat()
            print(
                f"  {p}  uid={st.st_uid}  gid={st.st_gid}  mode={oct(stat.S_IMODE(st.st_mode))}"
            )
        except Exception as e:
            print(f"  {p}: ERROR — {e}")


def check_agent_user():
    print("\n=== Agent user ===")
    print(f"  real UID: {os.getuid()}  GID: {os.getgid()}")
    try:
        import pwd

        print(f"  username: {pwd.getpwuid(os.getuid()).pw_name}")
    except Exception:
        print("  username: (unknown — uid not in /etc/passwd)")


def test_wiki_write():
    print("\n=== Wiki write test ===")
    wiki = VAULT_ROOT / AGENT_VAULT / "wiki"
    if not wiki.exists():
        print(f"  wiki dir does not exist: {wiki}")
        return
    test_file = wiki / ".permtest12345.tmp"
    try:
        test_file.write_text("x")
        test_file.unlink()
        print("  SUCCESS: can create and delete a file in wiki/")
    except PermissionError as e:
        print(f"  FAIL: PermissionError — {e}")
    except Exception as e:
        print(f"  FAIL: {type(e).__name__} — {e}")


def find_non_agent_files():
    print("\n=== Files not owned by agent user/writable group ===")
    # Look for files in wiki/ not matching agent UID
    agent_uid = os.getuid()
    wiki = VAULT_ROOT / AGENT_VAULT / "wiki"
    if not wiki.exists():
        return
    problems = []
    for f in wiki.rglob("*"):
        try:
            st = f.stat()
            if st.st_uid != agent_uid and not os.access(f, os.W_OK):
                problems.append(f)
        except Exception:
            continue
    if problems:
        for f in problems[:10]:
            print(f"  PROBLEM: {f}")
        if len(problems) > 10:
            print(f"  ... and {len(problems) - 10} more")
    else:
        print("  No obvious ownership problems found in wiki/")


def main():
    check_agent_user()
    check_vault_paths()
    test_wiki_write()
    find_non_agent_files()

    print("\n=== Next steps ===")
    print("If wiki/ is not writable, run as vault owner:")
    print("  sudo -u hermes python3 /opt/data/home/.hermes/scripts/daily_vault_pipeline.py")
    print("Or set up a shared group (see hermes-vault-pipeline skill, Option B).")


if __name__ == "__main__":
    main()
