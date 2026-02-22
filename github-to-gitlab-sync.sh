#!/bin/bash
#
# GitHub → GitLab Sync Script
# Fetches latest from GitHub and pushes to GitLab on-prem
#
# Usage:  ./github-to-gitlab-sync.sh
#
# This is a TRANSITION tool. Once you fully migrate to GitLab,
# you won't need this script anymore — just push directly to GitLab
# and use dual-push (SOP Section 12) to keep GitHub as backup.
#

set -euo pipefail

# ============================================
# CONFIGURATION — Edit these as needed
# ============================================

GITLAB_HOST="gitlab.infra.gov.sa"
SYNC_DIR="/opt/github-sync"
TOKEN_FILE="${SYNC_DIR}/.gitlab_token"
REPOS_DIR="${SYNC_DIR}/repos"

# Repo mappings: GITHUB_SSH_URL  GITLAB_PROJECT_PATH
# Add or remove lines as needed
REPOS=(
  "git@github.com:AbdullahAlShamrani-DevOps/gitlab-onprem-sop.git  infrastructure/gitlab/gitlab"
  "git@github.com:AbdullahAlShamrani-DevOps/accesshub.git  infrastructure/accesshub/accesshub"
  "git@github.com:AbdullahAlShamrani-DevOps/OLAM.git  infrastructure/olam/olam"
)

# ============================================
# DO NOT EDIT BELOW THIS LINE
# ============================================

SUCCESS_COUNT=0
FAIL_COUNT=0
TOTAL=${#REPOS[@]}
RESULTS=()

echo ""
echo "============================================"
echo "  GitHub → GitLab Sync"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
echo ""

# ---- Pre-flight checks ----

# Check git
if ! command -v git &>/dev/null; then
  echo "[ERROR] git is not installed. Run: dnf install -y git"
  exit 1
fi

# Check SSH key
if [[ ! -f /root/.ssh/github_sync_key ]]; then
  echo "[ERROR] SSH key not found. Run github-ssh-setup.sh first."
  exit 1
fi

# Create directories
mkdir -p "$REPOS_DIR"

# ---- GitLab Token ----

if [[ -f "$TOKEN_FILE" ]]; then
  GITLAB_TOKEN=$(cat "$TOKEN_FILE")
else
  echo "GitLab Personal Access Token not found."
  echo "Generate one at: https://${GITLAB_HOST}/-/user_settings/personal_access_tokens"
  echo "Required scopes: api, write_repository"
  echo ""
  read -rsp "Enter GitLab PAT: " GITLAB_TOKEN
  echo ""

  if [[ -z "$GITLAB_TOKEN" ]]; then
    echo "[ERROR] Token cannot be empty."
    exit 1
  fi

  # Verify token works
  echo "[INFO] Verifying token..."
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "https://${GITLAB_HOST}/api/v4/user")

  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "[ERROR] Token verification failed (HTTP $HTTP_CODE). Check your token."
    exit 1
  fi

  # Save token
  echo "$GITLAB_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "[INFO] Token verified and saved to $TOKEN_FILE"
  echo ""
fi

# ---- Sync each repo ----

for ENTRY in "${REPOS[@]}"; do
  GITHUB_URL=$(echo "$ENTRY" | awk '{print $1}')
  GITLAB_PATH=$(echo "$ENTRY" | awk '{print $2}')
  REPO_NAME=$(basename "$GITHUB_URL" .git)
  BARE_DIR="${REPOS_DIR}/${REPO_NAME}.git"

  echo "--------------------------------------------"
  echo "[SYNC] ${REPO_NAME}"
  echo "       GitHub:  ${GITHUB_URL}"
  echo "       GitLab:  ${GITLAB_PATH}"
  echo "--------------------------------------------"

  # ---- Step 1: Clone or fetch from GitHub ----

  if [[ ! -d "$BARE_DIR" ]]; then
    echo "  [1/4] Cloning from GitHub (first run)..."
    if ! git clone --bare "$GITHUB_URL" "$BARE_DIR" 2>&1; then
      echo "  [FAIL] Clone failed. Check SSH key and repo access."
      FAIL_COUNT=$((FAIL_COUNT + 1))
      RESULTS+=("[FAIL] ${REPO_NAME} — clone failed")
      continue
    fi
    # Ensure fetch refspec is set (bare clones sometimes miss this)
    cd "$BARE_DIR"
    git config remote.origin.fetch "+refs/heads/*:refs/heads/*"
  else
    echo "  [1/4] Fetching latest from GitHub..."
    cd "$BARE_DIR"
    # Ensure fetch refspec is set (fix for older bare clones)
    git config remote.origin.fetch "+refs/heads/*:refs/heads/*"
    if ! git fetch --prune origin 2>&1; then
      echo "  [FAIL] Fetch failed. Check SSH key and network."
      FAIL_COUNT=$((FAIL_COUNT + 1))
      RESULTS+=("[FAIL] ${REPO_NAME} — fetch failed")
      continue
    fi
  fi

  # ---- Step 2: Get GitLab project ID ----

  echo "  [2/4] Looking up GitLab project..."

  # URL-encode the path (replace / with %2F)
  ENCODED_PATH=$(echo "$GITLAB_PATH" | sed 's|/|%2F|g')

  PROJECT_ID=$(curl -sk --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "https://${GITLAB_HOST}/api/v4/projects/${ENCODED_PATH}" 2>/dev/null | \
    python3 -c "import sys,json; data=json.load(sys.stdin); print(data.get('id',''))" 2>/dev/null)

  if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "None" ]]; then
    echo "  [FAIL] GitLab project '${GITLAB_PATH}' not found."
    echo "         Create it first in GitLab (group/subgroup/project)."
    FAIL_COUNT=$((FAIL_COUNT + 1))
    RESULTS+=("[FAIL] ${REPO_NAME} — GitLab project not found")
    continue
  fi

  echo "         Project ID: ${PROJECT_ID}"

  # ---- Step 3: Unprotect main branch ----

  echo "  [3/4] Unprotecting 'main' branch..."
  curl -sk --request DELETE --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/protected_branches/main" \
    -o /dev/null 2>/dev/null || true

  # ---- Step 4: Push to GitLab ----

  echo "  [4/4] Pushing to GitLab..."
  cd "$BARE_DIR"

  # Set up GitLab remote (fetch=never so it doesn't create tracking refs)
  GITLAB_PUSH_URL="https://sync-bot:${GITLAB_TOKEN}@${GITLAB_HOST}/${GITLAB_PATH}.git"
  git remote set-url gitlab "$GITLAB_PUSH_URL" 2>/dev/null || git remote add gitlab "$GITLAB_PUSH_URL"

  # Clean up any stale gitlab remote tracking refs (these cause "hidden ref" errors)
  git for-each-ref --format='%(refname)' refs/remotes/gitlab/ 2>/dev/null | while read ref; do
    git update-ref -d "$ref" 2>/dev/null || true
  done

  # Push all branches + tags (NOT --mirror, which tries to push
  # remote tracking refs like refs/remotes/gitlab/* that GitLab rejects)
  if git push --all --force gitlab 2>&1 && git push --tags --force gitlab 2>&1; then
    echo ""
    echo "  [OK] ${REPO_NAME} synced successfully."
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    RESULTS+=("[ OK ] ${REPO_NAME}")
  else
    echo ""
    echo "  [FAIL] Push to GitLab failed."
    FAIL_COUNT=$((FAIL_COUNT + 1))
    RESULTS+=("[FAIL] ${REPO_NAME} — push failed")
  fi

  # ---- Re-protect main branch ----

  echo "  [    ] Re-protecting 'main' branch..."
  curl -sk --request POST --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --data "name=main&push_access_level=40&merge_access_level=40" \
    "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/protected_branches" \
    -o /dev/null 2>/dev/null || true

  echo ""

done

# ---- Summary ----

echo "============================================"
echo "  SYNC SUMMARY"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
echo ""

for RESULT in "${RESULTS[@]}"; do
  echo "  ${RESULT}"
done

echo ""
echo "  Total: ${TOTAL}  |  Success: ${SUCCESS_COUNT}  |  Failed: ${FAIL_COUNT}"
echo ""
echo "============================================"

if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 1
fi
