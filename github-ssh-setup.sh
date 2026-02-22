#!/bin/bash
#
# GitHub SSH Key Setup for GitLab Sync
# Run ONCE on nif-prod-gitlab-01 to generate SSH key for GitHub access
#

set -euo pipefail

KEY_PATH="/root/.ssh/github_sync_key"
SSH_CONFIG="/root/.ssh/config"

echo "============================================"
echo "  GitHub SSH Key Setup"
echo "============================================"
echo ""

# Check if key already exists
if [[ -f "$KEY_PATH" ]]; then
  echo "[INFO] SSH key already exists at $KEY_PATH"
  echo ""
  echo "Public key (add this as Deploy Key on each GitHub repo):"
  echo "--------------------------------------------"
  cat "${KEY_PATH}.pub"
  echo "--------------------------------------------"
  echo ""
  echo "Testing connection..."
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true
  exit 0
fi

# Create .ssh directory if needed
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Generate SSH key
echo "[1/3] Generating SSH key..."
ssh-keygen -t ed25519 -C "gitlab-sync-$(hostname)" -f "$KEY_PATH" -N ""
chmod 600 "$KEY_PATH"
echo "      Done."

# Add SSH config entry (only if not already present)
echo "[2/3] Configuring SSH for github.com..."
if ! grep -q "Host github.com" "$SSH_CONFIG" 2>/dev/null; then
  cat >> "$SSH_CONFIG" << 'EOF'

Host github.com
  HostName github.com
  IdentityFile /root/.ssh/github_sync_key
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
  chmod 600 "$SSH_CONFIG"
  echo "      SSH config updated."
else
  echo "      SSH config already has github.com entry — skipped."
fi

# Display public key
echo "[3/3] Setup complete!"
echo ""
echo "============================================"
echo "  COPY THE PUBLIC KEY BELOW"
echo "============================================"
echo ""
cat "${KEY_PATH}.pub"
echo ""
echo "============================================"
echo ""
echo "Add this key as a DEPLOY KEY on each GitHub repo:"
echo ""
echo "  1. Go to GitHub repo -> Settings -> Deploy keys"
echo "  2. Click 'Add deploy key'"
echo "  3. Title: gitlab-sync-$(hostname)"
echo "  4. Paste the key above"
echo "  5. Allow write access: UNCHECKED (read-only)"
echo "  6. Click 'Add key'"
echo ""
echo "Repos that need this key:"
echo "  - github.com/AbdullahAlShamrani-DevOps/gitlab-onprem-sop"
echo "  - github.com/AbdullahAlShamrani-DevOps/accesshub"
echo "  - github.com/AbdullahAlShamrani-DevOps/OLAM"
echo ""
echo "After adding the key, test with:"
echo "  ssh -T git@github.com"
echo ""
