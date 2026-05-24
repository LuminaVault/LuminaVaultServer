# Hermes Venv Permissions & Layout

**Discovered:** 2026-05-02 during community skill dependency installation

## Venv Location

```
/opt/hermes/
├── .venv/
│   ├── bin/
│   │   ├── python3      ← Hermes Python interpreter
│   │   └── hermes       ← Hermes CLI
│   ├── lib/
│   │   └── python3.13/
│   │       └── site-packages/  ← **Read-only in production**
│   └── pyvenv.cfg
├── hermes_cli/
└── hermes/
```

## Key Constraints

| Constraint | Detail | Impact |
|---|---|---|
| **No pip** | `ensurepip` not included; `/opt/hermes/.venv/bin/pip` absent | Cannot use `pip install` inside venv |
| **Permission denied on site-packages** | `/opt/hermes/.venv/lib/python3.13/site-packages/` owned by root or read-only | Bootstrapping pip fails; wheel install blocked |
| **System Python separate** | `/usr/bin/python3` = system Python (3.13.x) | Install deps here with `--user` flag |
| **User site-packages path** | `~/.local/lib/python3.13/site-packages/` | Hermes venv may or may not include this in `sys.path` |
| **PYTHONPATH respected** | Hermes inherits env vars from launcher | Can add custom paths if needed |

## Workaround: Install Dependencies for Hermes Skills

### Method 1 — User Site-Packages (Safest)

```bash
# Install to ~/.local/ (no sudo needed, no venv write needed)
python3 -m pip install --user mido basic-pitch pyfluidsynth

# Verify visible to Hermes venv:
/opt/hermes/.venv/bin/python3 -c "import mido; print('OK')"
```

**Caveat:** Hermes venv must be configured to include user site-packages. Test with the verify command above.

### Method 2 — System Python Globally (Requires sudo)

```bash
sudo python3 -m pip install mido basic-pitch pyfluidsynth
```

**Caveat:** Installs globally; may conflict with system packages.

### Method 3 — Target Directory (No sys.path auto-add)

```bash
# Install to a specific dir, then add to PYTHONPATH
mkdir -p /opt/hermes/.venv/lib/python3.13/site-packages-custom
python3 -m pip install --target=/opt/hermes/.venv/lib/python3.13/site-packages-custom mido

# Export in Hermes env:
export PYTHONPATH="/opt/hermes/.venv/lib/python3.13/site-packages-custom:$PYTHONPATH"
```

**Caveat:** Requires write access to `/opt/hermes/` (often root-gated).

## Checking Hermes Venv Config

```bash
# See what Python paths Hermes sees
/opt/hermes/.venv/bin/python3 -c "import sys; print('\\n'.join(sys.path))"

# Check if user site-packages included
/opt/hermes/.venv/bin/python3 -c "import site; print(site.ENABLE_USER_SITE)"
```

## If All Else Fails — Manual Wheel Install

1. Download wheel files on another machine: `pip download --only-binary=:all: mido -d /tmp/wheels/`
2. Transfer wheels to server
3. Extract wheel contents directly into a directory on `sys.path`
4. Add that directory to `PYTHONPATH`

---

**See also:** `community-skill-installation` skill for full dependency resolution workflow.
