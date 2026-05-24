#!/usr/bin/env bash
# Encrypted backup of Hermes secrets (.env, .ssh)
# DO NOT commit these to GitHub - store encrypted

set -euo pipefail

BACKUP_DIR="/opt/data/secret_backups"
SECRETS_FILE="/tmp/hermes_secrets_$(date +%Y%m%d).tar.gz"
GPG_RECIPIENT=""  # Optional: for asymmetric encryption
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

echo "Creating encrypted backup of secrets..."

# Create tarball of sensitive files
tar -czf "$SECRETS_FILE"     -C /opt/data     .env     .ssh/

if [ -n "$GPG_RECIPIENT" ]; then
    # Asymmetric encryption (requires recipient's public key)
    gpg --encrypt --recipient "$GPG_RECIPIENT"         --output "$BACKUP_DIR/hermes_secrets_$DATE.tar.gz.gpg"         "$SECRETS_FILE"
else
    # Symmetric encryption (password-based)
    echo "Creating password-protected archive..."
    gpg --symmetric --cipher-algo AES256         --output "$BACKUP_DIR/hermes_secrets_$DATE.tar.gz.gpg"         "$SECRETS_FILE"
    echo "Remember this password - you'll need it to decrypt!"
fi

# Keep only last 12 encrypted backups
cd "$BACKUP_DIR"
ls -t hermes_secrets_*.gpg | tail -n +13 | xargs -r rm

echo "Encrypted backup saved to: $BACKUP_DIR/hermes_secrets_$DATE.tar.gz.gpg"
echo "Size: $(du -h "$BACKUP_DIR/hermes_secrets_$DATE.tar.gz.gpg" | cut -f1)"

# Cleanup plaintext
rm -f "$SECRETS_FILE"

echo ""
echo "IMPORTANT:"
echo "  - Store backups in at least 2 locations"
echo "  - Document the GPG password in your password manager"
echo "  - Test decryption periodically: gpg -d backup.tar.gz.gpg | tar xz -C /tmp"
