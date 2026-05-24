# Permission Error Case — 2026-05-02

**Pipeline:** `daily_vault_pipeline.py` (FACorreia vault)
**Failure:** PermissionError during compile step

## Full error

```
PermissionError: [Errno 13] Permission denied: '/opt/data/obsidian-vault/FACorreia/wiki/how-to-build-a-jarvis-inside-obsidian-with-claude-code-—-the-full-setup-from-scratch-(2).md'
  at compile_wiki.py line 151: old.unlink(missing_ok=True)
```

## Root cause analysis

| Check | Result |
|-------|--------|
| Agent UID/GID | `uid=1000 gid=1000` (non-root, not 'hermes') |
| Vault owner UID/GID | `uid=10000 gid=10000` (user 'hermes') |
| Wiki dir mode | `0755 drwxr-xr-x hermes hermes` |
| Agent write access to wiki/ | `False` (neither owner nor group-match) |
| Agent write access to vault root | `False` (owned by hermes:hermes 0755) |
| fs mount options | `rw,relatime` (writable) — no read-only issue |

**Conclusion:** The `unlink()` system call fails because the agent (UID 1000) is neither the owner (10000) nor in the owner group (10000), and directory mode `0755` denies write to "others".

## Reproduction steps

```bash
# 1. As the agent user (UID 1000), attempt compile
python3 /opt/data/skills/knowledge-base/scripts/kb-compile/compile_wiki.py --root /opt/data/obsidian-vault/FACorreia

# 2. Observe PermissionError on the first .md file in wiki/
```

## Diagnostic commands used

```python
import os, subprocess, pathlib

# Check ownership
subprocess.run(['ls', '-la', '/opt/data/obsidian-vault/FACorreia/wiki'])

# Check stat
st = os.stat('/opt/data/obsidian-vault/FACorreia/wiki')
print(f"uid={st.st_uid} gid={st.st_gid} mode={oct(stat.S_IMODE(st.st_mode))}")

# Write test
test = pathlib.Path('/opt/data/obsidian-vault/FACorreia/wiki') / '.perm_test.tmp'
test.write_text('x')
test.unlink()  # raises PermissionError

# Check if runuser/sudo available
import shutil
print('runuser:', shutil.which('runuser'))   # /usr/sbin/runuser (requires root)
print('sudo:', shutil.which('sudo'))         # None
```

## Environment facts

- `/opt/data/obsidian-vault` → UID 10000 `hermes`, GID 10000 `hermes`
- `/opt/data/home` (agent's homedir) → UID 1000, GID 1000
- Agent has no capability to change UID (not root; `CapEff: 0000000000000000`)
- No ACL tooling available (`getfacl`, `setfacl` missing)
- No `sudo` binary present

## Fix applied

**Status:** Not fixed during session — pipeline blocked.

**Recommended fix (pending execution):** Delegate to a root-capable agent or use Option B (shared group) from `hermes-vault-pipeline` skill:

```bash
# As root:
groupadd vaultops
usermod -aG vaultops hermes
usermod -aG vaultops <agent_uid_1000_user>
chgrp vaultops /opt/data/obsidian-vault/FACorreia/wiki
chmod 0775 /opt/data/obsidian-vault/FACorreia/wiki
chmod g+s /opt/data/obsidian-vault/FACorreia/wiki  # setgid for inheritance
```

Then re-run pipeline as agent user.

## Lessons learned

1. **Agent vs vault ownership mismatch** is the default failure mode on this deployment. The vault files live under a dedicated `hermes` user (UID 10000) while the agent runs as a lower-privilege user (UID 1000).
2. **Tool output truncation** can hide the actual traceback. Always use `subprocess.run(stdout=PIPE, stderr=STDOUT)` to capture full error text when debugging.
3. **`os.access()`** is unreliable for definitive permission checking; attempt a real write (`test.write_text()` + `unlink()`) to be sure.
4. **`runuser`** requires root; without it, elevation is impossible. The agent cannot self-resolve — an external operator or a separate privileged sub-agent is needed.
5. This is a **deployment configuration** issue, not a code bug. The fix belongs in the provisioning playbook, not the pipeline script.
