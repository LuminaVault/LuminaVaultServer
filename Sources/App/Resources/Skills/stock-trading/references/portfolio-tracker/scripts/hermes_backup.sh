#!/usr/bin/env bash
# Hermes Backup Script
# Backs up ~/.hermes (agent data, scripts, skills) to a private GitHub repository
# Secrets (.env, .ssh) are backed up separately via encrypted means

set -euo pipefail

BACKUP_DIR="/tmp/hermes_backup_$(date +%Y%m%d_%H%M%S)"
HERMES_HOME="/opt/data/home/.hermes"
GIT_REPO="git@github.com:YOUR_USERNAME/hermes-backup.git"  # CONFIGURE THIS
GIT_BRANCH="main"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

# Check prerequisites
for cmd in git ssh tar gzip; do
    if ! command -v $cmd &> /dev/null; then
        error "Required command missing: $cmd"
        exit 1
    fi
done

# Verify GitHub SSH key is available
if [ ! -f ~/.ssh/id_ed25519 ] && [ ! -f ~/.ssh/id_rsa ]; then
    error "No SSH key found in ~/.ssh/ (needed for GitHub)"
    exit 1
fi

log "Creating backup at $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"

# Copy directories to backup (excluding large/volatile data)
log "Copying Hermes home..."
rsync -av     --exclude='logs/*'     --exclude='tmp/*'     --exclude='output/*'     --exclude='__pycache__/*'     --exclude='.git'     "$HERMES_HOME/" "$BACKUP_DIR/home/"

# Optionally include a compressed state.db backup (if not too large)
if [ -f /opt/data/state.db ]; then
    DB_SIZE=$(du -m /opt/data/state.db | cut -f1)
    if [ "$DB_SIZE" -lt 100 ]; then  # Only if < 100MB
        log "Backing up state.db ($DB_SIZE MB)..."
        cp /opt/data/state.db "$BACKUP_DIR/state.db"
    else
        warn "state.db is $DB_SIZE MB, skipping (too large for regular backup)"
    fi
fi

# Create manifest
log "Creating backup manifest..."
cat > "$BACKUP_DIR/BACKUP_MANIFEST.txt" << EOF
Hermes Agent Backup
===================
Created: $(date -Iseconds)
Hostname: $(hostname)
Hermes Home: $HERMES_HOME
Backup Dir: $BACKUP_DIR

Contents:
  - scripts/ (custom automation scripts)
  - skills/ (custom skills)
  - user_profile.{json,yaml} (user preferences)
  - transcripts/ (conversation history - plain text)
  - weekly_digests/ (weekly summaries)
  - README files (documentation)

Excluded (already backed up elsewhere or volatile):
  - logs/ (log files - rotated separately)
  - tmp/ (temporary files)
  - output/ (generated artifacts)
  - __pycache__/ (compiled Python)

Secrets Backup (separate, encrypted):
  - /opt/data/.env  (API keys, tokens)
  - /opt/data/.ssh/ (SSH keys)
See: /opt/data/.secrets_backup_README.md
EOF

# Create tarball
log "Compressing backup..."
BACKUP_TAR="/tmp/hermes_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
tar -czf "$BACKUP_TAR" -C "$BACKUP_DIR" .

log "Backup created: $BACKUP_TAR ($(du -h "$BACKUP_TAR" | cut -f1))"

# Git operations (if configured)
if [ "$GIT_REPO" != "git@github.com:YOUR_USERNAME/hermes-backup.git" ]; then
    log "Initializing Git repository..."
    git init "$BACKUP_DIR/repo"
    cd "$BACKUP_DIR/repo"
    
    # Configure git
    git config user.name "Hermes Backup"
    git config user.email "hermes-backup@localhost"
    
    # Copy backup files into repo
    cp -r ../home/* .
    if [ -f ../state.db ]; then
        cp ../state.db .
        echo "state.db" >> .gitignore
    fi
    
    # Create gitignore for excluded paths
    cat > .gitignore << GITIGNORE
# Excluded volatile/generated data
logs/
tmp/
output/
__pycache__/
.git/
state.db (too large - separate encrypted backup)
*.log
GITIGNORE
    
    git add .
    git commit -m "Hermes backup $(date -I)"
    
    # Add remote if not already present
    if ! git remote | grep -q origin; then
        git remote add origin "$GIT_REPO"
    fi
    
    log "Pushing to GitHub ($GIT_REPO)..."
    git push -u origin "$GIT_BRANCH" --force
    log "Backup pushed to GitHub!"
else
    warn "GIT_REPO not configured. Edit the backup script and set your private repo URL."
fi

# Cleanup
log "Cleaning up temporary files..."
rm -rf "$BACKUP_DIR" "$BACKUP_TAR"

log "Backup complete!"
