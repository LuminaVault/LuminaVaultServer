#!/usr/bin/env bash
# Create the private GitHub repository and push initial backup

# Configuration
REPO_NAME="hermes-backup"
GITHUB_USER="YOUR_USERNAME"  # <-- CHANGE THIS
DESCRIPTION="Hermes agent backup: scripts, skills, and configuration (non-secrets)"

# Check gh CLI
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) not installed."
    echo "Install: https://cli.github.com/"
    exit 1
fi

# Authenticate with GitHub
if ! gh auth status &> /dev/null; then
    echo "Logging into GitHub..."
    gh auth login
fi

# Create private repo
echo "Creating private GitHub repository..."
gh repo create "$GITHUB_USER/$REPO_NAME" \
    --private \
    --description "$DESCRIPTION" \
    --homepage "https://github.com/$GITHUB_USER/$REPO_NAME" \
    --clone

cd "$REPO_NAME"

# Copy backup files
echo "Copying files..."
cp -r /opt/data/home/.hermes/scripts ./scripts
cp -r /opt/data/home/.hermes/skills ./skills
cp /opt/data/home/.hermes/user_profile.* ./
cp /opt/data/home/.hermes/.gitignore . 2>/dev/null || true

# Create .gitignore if missing
if [ ! -f .gitignore ]; then
    cat > .gitignore << 'EOF'
# Secrets - NEVER commit
*.env
.ssh/
**/.ssh/
secrets/
credentials.json
*.pem
*.key
*.p12
*.pfx

# Large/generated
state.db
*.log
logs/
tmp/
output/
__pycache__/
*.pyc

# OS
.DS_Store
Thumbs.db

# Hermes cache
.cache/
EOF
fi

# Initial commit
git add .
git commit -m "Initial Hermes backup: scripts, skills, user profile"

# Push
git push -u origin main

echo "✅ Backup repository created: https://github.com/$GITHUB_USER/$REPO_NAME"
echo ""
echo "Next steps:"
echo "  1. Edit hermes_backup.sh and set GIT_REPO to this repo URL"
echo "  2. Run: /opt/data/home/.hermes/scripts/hermes_backup.sh"
echo "  3. Set up cron for daily automated backups"
