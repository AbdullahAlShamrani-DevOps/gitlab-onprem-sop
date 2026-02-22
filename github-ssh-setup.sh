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
  echo "Public key (add this to your GitHub account):"
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
echo "Add this key to your GITHUB ACCOUNT (not per-repo deploy key):"
echo ""
echo "  1. Go to github.com -> click your avatar -> Settings"
echo "  2. Click 'SSH and GPG keys' (left sidebar)"
echo "  3. Click 'New SSH key'"
echo "  4. Title: gitlab-sync-$(hostname)"
echo "  5. Key type: Authentication Key"
echo "  6. Paste the public key above"
echo "  7. Click 'Add SSH key'"
echo ""
echo "This gives access to ALL repos on your account."
echo "(Deploy keys are per-repo and can't be reused — that's why we use account SSH keys.)"
echo ""
echo "After adding the key, test with:"
echo "  ssh -T git@github.com"
echo ""
