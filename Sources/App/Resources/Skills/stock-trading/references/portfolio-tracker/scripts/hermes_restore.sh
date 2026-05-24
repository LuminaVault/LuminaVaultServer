#!/usr/bin/env bash
# Hermes Restore Script - Restores from GitHub backup

set -euo pipefail

BACKUP_FILE="${1:-/tmp/hermes_backup.tar.gz}"
HERMES_HOME="/opt/data/home/.hermes"

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup.tar.gz>"
    echo "   or: $0 latest  # fetch latest from GitHub"
    exit 1
fi

echo "Restoring Hermes from $BACKUP_FILE..."

# Safety check
if [ "$BACKUP_FILE" != "/tmp/hermes_backup.tar.gz" ]; then
    echo "WARNING: Only use backups you trust!"
    read -p "Continue? (yes/no): " confirm
    [ "$confirm" = "yes" ] || exit 1
fi

# Extract to temp
TMPDIR=$(mktemp -d)
tar -xzf "$BACKUP_FILE" -C "$TMPDIR"

# Stop hermes if running
if pgrep -f hermes > /dev/null; then
    echo "Stopping Hermes agent..."
    hermes stop 2>/dev/null || true
    sleep 2
fi

echo "Restoring files to $HERMES_HOME..."
rsync -av --delete "$TMPDIR/home/" "$HERMES_HOME/"

# Restore state.db if present (and not too large)
if [ -f "$TMPDIR/state.db" ]; then
    echo "Restoring state.db..."
    cp "$TMPDIR/state.db" /opt/data/state.db
fi

# Fix permissions
chown -R hermes:hermes "$HERMES_HOME" 2>/dev/null || true

# Cleanup
rm -rf "$TMPDIR"

echo "Restore complete!"
echo "Start Hermes: hermes start"
