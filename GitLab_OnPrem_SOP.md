# GitLab CE On-Premises Deployment — Standard Operating Procedure

**Platform:** Oracle Enterprise Linux 9 (OEL 9)
**Deployment Method:** Docker
**Edition:** GitLab Community Edition (CE) — Free
**Document Version:** 1.0
**Date:** 2026-02-21

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites & System Requirements](#2-prerequisites--system-requirements)
3. [Docker Installation](#3-docker-installation)
4. [Volume Preparation (Permissions & Ownership)](#4-volume-preparation-permissions--ownership)
5. [SSL Certificate Preparation (Internal CA)](#5-ssl-certificate-preparation-internal-ca)
6. [GitLab Container Deployment](#6-gitlab-container-deployment)
7. [GitLab Configuration (HTTPS, SSH, Backups)](#7-gitlab-configuration-https-ssh-backups)
8. [Firewall Configuration](#8-firewall-configuration)
9. [First Login & Initial Hardening](#9-first-login--initial-hardening)
10. [Client-Side CA Trust Configuration](#10-client-side-ca-trust-configuration)
11. [Dual Push: GitLab On-Prem + GitHub](#11-dual-push-gitlab-on-prem--github)
12. [Importing Projects from GitHub to GitLab](#12-importing-projects-from-github-to-gitlab)
13. [Backup Strategy](#13-backup-strategy)
14. [Updating GitLab](#14-updating-gitlab)
15. [Maintenance & Troubleshooting](#15-maintenance--troubleshooting)
16. [Quick Reference Card](#16-quick-reference-card)

---

## 1. Overview

### What This SOP Covers

Deployment of a self-hosted GitLab CE instance running in Docker on OEL 9, with:

- HTTPS using an internal/private CA certificate
- SSH access on a non-standard port (2222)
- Automated backups (with optional encryption)
- Dual-push mirroring to GitHub
- Migration path from GitHub SaaS to GitLab on-prem

### GitLab Self-Managed vs GitLab SaaS (Free Tier)

| Aspect                | GitLab SaaS (Free)               | GitLab Self-Managed (This SOP)     |
|-----------------------|----------------------------------|-------------------------------------|
| Hosting               | GitLab hosts it                  | You host on your own server         |
| Data control          | Data on GitLab servers           | Full control — data stays with you  |
| Storage               | 5 GB per project                 | Limited only by your disk           |
| CI/CD minutes         | 400 min/month (shared runners)   | Unlimited (your own runners)        |
| User limit            | 5 users per top-level namespace  | Unlimited                           |
| Customization         | None                             | Full (LDAP, SSO, branding, etc.)    |
| Updates               | Automatic                        | You manage updates                  |
| Backups               | GitLab handles it                | Your responsibility                 |
| Internet required     | Yes                              | No — can run fully offline          |

### Network Architecture

```
Developer Machine
    |
    |--- HTTPS (port 443) ---> GitLab (built-in NGINX with SSL termination)
    |--- SSH   (port 2222) --> GitLab (Git over SSH)
```

---

## 2. Prerequisites & System Requirements

### 2.1 Minimum Hardware

| Resource | Minimum  | Recommended         |
|----------|----------|---------------------|
| CPU      | 2 cores  | 4+ cores            |
| RAM      | 4 GB     | 8 GB+               |
| Disk     | 50 GB    | 100 GB+ (separate disk for /var/gitlab) |
| OS       | OEL 9.x  | OEL 9.x             |

### 2.2 Pre-Checks

Run the following commands to verify the server is ready:

```bash
# Verify OS version
cat /etc/os-release

# Check available memory
free -h

# Check available disk space
df -h

# Check CPU cores
nproc

# Verify current hostname
hostnamectl
```

### 2.3 Set Hostname

```bash
hostnamectl set-hostname gitlab.yourdomain.com
```

### 2.4 DNS / Host Resolution

If DNS is not available, add a local hosts entry:

```bash
echo "$(hostname -I | awk '{print $1}') gitlab.yourdomain.com" >> /etc/hosts
```

### 2.5 Required Files from Your CA

Before proceeding, ensure you have:

| File               | Description                           |
|--------------------|---------------------------------------|
| `your_domain.crt`  | Your server/domain certificate        |
| `your_domain.key`  | Your private key                      |
| `ca_bundle.crt`    | CA chain (intermediates + root CA)    |
| `your_ca_root.crt` | Your CA root certificate (standalone) |

---

## 3. Docker Installation

### 3.1 Remove Conflicting Packages

```bash
dnf remove -y \
  docker \
  docker-client \
  docker-client-latest \
  docker-common \
  docker-latest \
  docker-latest-logrotate \
  docker-logrotate \
  docker-engine \
  podman \
  runc \
  buildah
```

### 3.2 Install Prerequisites

```bash
dnf install -y dnf-utils
```

### 3.3 Add Docker Repository

```bash
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
```

### 3.4 Install Docker Engine

```bash
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

### 3.5 Start and Enable Docker

```bash
systemctl start docker
systemctl enable docker
```

### 3.6 Verify Installation

```bash
docker --version
docker run hello-world
```

Expected: `Hello from Docker!`

### 3.7 Clean Up Verification Container

```bash
docker rm $(docker ps -aq --filter ancestor=hello-world)
docker rmi hello-world
```

---

## 4. Volume Preparation (Permissions & Ownership)

> **IMPORTANT:** These directories must be created and configured BEFORE deploying the GitLab container.

### 4.1 Install Required Tools

```bash
dnf install -y policycoreutils-python-utils tree
```

### 4.2 Create Directory Structure

```bash
mkdir -p /var/gitlab/config/ssl
mkdir -p /var/gitlab/logs
mkdir -p /var/gitlab/data
mkdir -p /var/gitlab/backups
```

### 4.3 Set Ownership

```bash
chown -R root:root /var/gitlab
```

### 4.4 Set Permissions

```bash
# Parent directory
chmod 755 /var/gitlab

# Config — contains gitlab.rb and secrets
chmod 755 /var/gitlab/config

# SSL — contains private keys (most restrictive)
chmod 700 /var/gitlab/config/ssl

# Logs — readable for troubleshooting
chmod 755 /var/gitlab/logs

# Data — contains repositories, database, uploads
chmod 755 /var/gitlab/data

# Backups — restricted (contains full data dumps)
chmod 700 /var/gitlab/backups
```

### 4.5 Configure SELinux Context

OEL 9 has SELinux enforcing by default. Docker containers will fail to write to host volumes without the correct context.

```bash
# Verify SELinux status
getenforce
```

If output is `Enforcing`, apply the container context:

```bash
semanage fcontext -a -t container_file_t "/var/gitlab(/.*)?"
restorecon -Rv /var/gitlab
```

### 4.6 Verify SELinux Context

```bash
ls -ldZ /var/gitlab
ls -ldZ /var/gitlab/config
ls -ldZ /var/gitlab/config/ssl
ls -ldZ /var/gitlab/data
ls -ldZ /var/gitlab/logs
ls -ldZ /var/gitlab/backups
```

Every line should show `container_file_t` in the context.

### 4.7 Verify Final Structure

```bash
tree -pug /var/gitlab
```

Expected output:

```
/var/gitlab
├── [drwxr-xr-x root root] backups       (700 — will show drwx------)
├── [drwxr-xr-x root root] config
│   └── [drwx------ root root] ssl
├── [drwxr-xr-x root root] data
└── [drwxr-xr-x root root] logs
```

---

## 5. SSL Certificate Preparation (Internal CA)

### 5.1 Create the Full-Chain Certificate

The certificate file must contain: **server cert → intermediate(s) → root CA**, in that order.

```bash
cat your_domain.crt ca_bundle.crt > /var/gitlab/config/ssl/gitlab.yourdomain.com.crt
```

> **CRITICAL:** The filename MUST match the FQDN used in `external_url`.
> If your URL will be `https://gitlab.yourdomain.com`, the file must be named `gitlab.yourdomain.com.crt`.

### 5.2 Copy the Private Key

```bash
cp your_domain.key /var/gitlab/config/ssl/gitlab.yourdomain.com.key
```

### 5.3 Copy the CA Root Certificate

This is used so GitLab trusts its own certificate for internal calls (webhooks, API, etc.).

```bash
cp your_ca_root.crt /var/gitlab/config/ssl/your_ca_root.crt
```

### 5.4 Set Certificate Permissions

```bash
# Private key — most restrictive
chmod 600 /var/gitlab/config/ssl/gitlab.yourdomain.com.key

# Certificates — readable
chmod 644 /var/gitlab/config/ssl/gitlab.yourdomain.com.crt
chmod 644 /var/gitlab/config/ssl/your_ca_root.crt

# Ownership
chown root:root /var/gitlab/config/ssl/*
```

### 5.5 Verify Certificate and Key Match

```bash
# These two commands MUST produce the same MD5 hash
openssl x509 -noout -modulus -in /var/gitlab/config/ssl/gitlab.yourdomain.com.crt | md5sum
openssl rsa  -noout -modulus -in /var/gitlab/config/ssl/gitlab.yourdomain.com.key | md5sum
```

If the hashes do NOT match, the certificate and key do not belong together. Do not proceed.

### 5.6 Verify Certificate Details

```bash
# View certificate subject and issuer
openssl x509 -in /var/gitlab/config/ssl/gitlab.yourdomain.com.crt -text -noout | head -20

# Verify chain of trust
openssl verify -CAfile /var/gitlab/config/ssl/your_ca_root.crt \
  /var/gitlab/config/ssl/gitlab.yourdomain.com.crt
```

Expected output: `gitlab.yourdomain.com.crt: OK`

### 5.7 Verify Final SSL Directory

```bash
ls -la /var/gitlab/config/ssl/
```

Expected:

```
drwx------  root root  .
drwxr-xr-x  root root  ..
-rw-r--r--  root root  gitlab.yourdomain.com.crt
-rw-------  root root  gitlab.yourdomain.com.key
-rw-r--r--  root root  your_ca_root.crt
```

---

## 6. GitLab Container Deployment

### 6.1 Pull GitLab CE Image

```bash
docker pull gitlab/gitlab-ce:latest
```

### 6.2 Deploy the Container

```bash
docker run -d \
  --hostname gitlab.yourdomain.com \
  --name gitlab \
  --restart always \
  -p 443:443 \
  -p 80:80 \
  -p 2222:22 \
  --shm-size 256m \
  -v /var/gitlab/config:/etc/gitlab \
  -v /var/gitlab/logs:/var/log/gitlab \
  -v /var/gitlab/data:/var/opt/gitlab \
  gitlab/gitlab-ce:latest
```

**Port mapping explained:**

| Host Port | Container Port | Purpose                                    |
|-----------|---------------|--------------------------------------------|
| 443       | 443           | HTTPS                                      |
| 80        | 80            | HTTP (will redirect to HTTPS)              |
| 2222      | 22            | SSH (port 22 is used by host SSH service)  |

### 6.3 Verify Container is Running

```bash
docker ps --filter name=gitlab
```

### 6.4 Wait for Initial Configuration

First boot takes **3–5 minutes**. Watch the logs:

```bash
docker logs -f gitlab
```

Wait until you see `gitlab Reconfigured!`, then press `Ctrl+C`.

---

## 7. GitLab Configuration (HTTPS, SSH, Backups)

### 7.1 Edit GitLab Configuration File

```bash
vi /var/gitlab/config/gitlab.rb
```

### 7.2 Configuration Block

Add or modify the following sections in `gitlab.rb`:

```ruby
##############################################
# EXTERNAL URL
##############################################
external_url 'https://gitlab.yourdomain.com'

##############################################
# NGINX / SSL CONFIGURATION
##############################################
nginx['ssl_certificate']           = "/etc/gitlab/ssl/gitlab.yourdomain.com.crt"
nginx['ssl_certificate_key']       = "/etc/gitlab/ssl/gitlab.yourdomain.com.key"
nginx['redirect_http_to_https']    = true
nginx['ssl_protocols']             = "TLSv1.2 TLSv1.3"
nginx['ssl_ciphers']               = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
nginx['ssl_prefer_server_ciphers'] = "on"

##############################################
# INTERNAL CA TRUST
# Required for GitLab to trust its own cert
# for internal API calls and webhooks
##############################################
gitlab_workhorse['env'] = {
  'SSL_CERT_FILE' => '/etc/gitlab/ssl/your_ca_root.crt'
}

##############################################
# SSH PORT
# Must match the host port mapped to container port 22
##############################################
gitlab_rails['gitlab_shell_ssh_port'] = 2222

##############################################
# TIMEZONE
##############################################
gitlab_rails['time_zone'] = 'Asia/Riyadh'

##############################################
# BACKUP CONFIGURATION
##############################################
gitlab_rails['backup_path']       = "/var/opt/gitlab/backups"
gitlab_rails['backup_keep_time']  = 604800
```

> **Note:** Backups are unencrypted by default. See [Section 13.5](#135-optional-enable-backup-encryption) to enable encryption.

### 7.3 Apply Configuration

```bash
docker exec -it gitlab gitlab-ctl reconfigure
```

Wait for: `gitlab Reconfigured!`

### 7.4 Verify HTTPS

```bash
# Quick test from the server
curl -k https://localhost

# Test with CA verification
curl --cacert /var/gitlab/config/ssl/your_ca_root.crt https://gitlab.yourdomain.com
```

### 7.5 Verify All Services Are Running

```bash
docker exec -it gitlab gitlab-ctl status
```

All services should show `run`.

---

## 8. Firewall Configuration

```bash
# HTTPS
firewall-cmd --permanent --add-service=https

# HTTP (for redirect)
firewall-cmd --permanent --add-service=http

# GitLab SSH
firewall-cmd --permanent --add-port=2222/tcp

# Apply rules
firewall-cmd --reload

# Verify
firewall-cmd --list-all
```

---

## 9. First Login & Initial Hardening

### 9.1 Retrieve Initial Root Password

```bash
docker exec -it gitlab grep 'Password:' /etc/gitlab/initial_root_password
```

> This file is automatically deleted after 24 hours.

### 9.2 First Login

1. Open browser: `https://gitlab.yourdomain.com`
2. Accept the certificate warning (if your CA is not yet trusted by the browser)
3. Username: **root**
4. Password: *(from command above)*

### 9.3 Immediate Hardening Steps

Perform these actions immediately after first login:

| #  | Action                     | Path                                                                                    |
|----|----------------------------|-----------------------------------------------------------------------------------------|
| 1  | Change root password       | Click avatar (top-left) → **Edit Profile** → **Password**                               |
| 2  | Disable public sign-up     | **Admin Area** → **Settings** → **General** → **Sign-up restrictions** → Uncheck **Sign-up enabled** → Save |
| 3  | Set default visibility     | **Admin Area** → **Settings** → **General** → **Visibility and access controls** → Set to **Private** → Save |
| 4  | Create your personal admin | **Admin Area** → **Overview** → **Users** → **New User** (grant Admin role)             |
| 5  | Create first group         | **Groups** → **New Group**                                                              |
| 6  | Login as new admin         | Log out of root, log in as your new admin user                                          |

---

## 10. Client-Side CA Trust Configuration

Every developer machine that connects to GitLab must trust your internal CA.

### 10.1 Linux (RHEL/OEL/CentOS/Fedora)

```bash
# Copy CA root to system trust store
sudo cp your_ca_root.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust

# Configure Git
git config --global http.sslCAInfo /etc/pki/ca-trust/source/anchors/your_ca_root.crt
```

### 10.2 Linux (Ubuntu/Debian)

```bash
sudo cp your_ca_root.crt /usr/local/share/ca-certificates/your_ca_root.crt
sudo update-ca-certificates

git config --global http.sslCAInfo /usr/local/share/ca-certificates/your_ca_root.crt
```

### 10.3 macOS

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain your_ca_root.crt

git config --global http.sslCAInfo /path/to/your_ca_root.crt
```

### 10.4 Windows

```
1. Double-click your_ca_root.crt
2. Click "Install Certificate"
3. Select "Local Machine" → Next
4. Select "Place all certificates in the following store"
5. Browse → "Trusted Root Certification Authorities" → OK
6. Next → Finish
```

Then configure Git:

```cmd
git config --global http.sslCAInfo "C:\path\to\your_ca_root.crt"
```

### 10.5 SSH Configuration for Git (All Platforms)

Each developer adds to `~/.ssh/config`:

```
Host gitlab.yourdomain.com
    HostName gitlab.yourdomain.com
    Port 2222
    User git
    IdentityFile ~/.ssh/id_rsa
```

This allows standard Git SSH commands:

```bash
git clone git@gitlab.yourdomain.com:group/project.git
```

---

## 11. Dual Push: GitLab On-Prem + GitHub

Push to both GitLab and GitHub simultaneously so both repos are always in sync.

### 11.1 Configure Multi-Push on an Existing Repo

```bash
cd /path/to/your/project

# View current remotes
git remote -v

# Add GitLab as a second push URL on the "origin" remote
git remote set-url --add --push origin ssh://git@gitlab.yourdomain.com:2222/group/project.git

# Keep the GitHub push URL as well
git remote set-url --add --push origin git@github.com:user/project.git

# Verify — should show TWO push URLs
git remote -v
```

Expected output:

```
origin  git@github.com:user/project.git (fetch)
origin  git@github.com:user/project.git (push)
origin  ssh://git@gitlab.yourdomain.com:2222/group/project.git (push)
```

### 11.2 Usage

```bash
# Single push goes to BOTH remotes
git push origin main
```

### 11.3 Alternative: Separate Remotes (More Control)

If you want to push selectively:

```bash
# Add GitLab as a named remote
git remote add gitlab ssh://git@gitlab.yourdomain.com:2222/group/project.git

# Push individually
git push origin main     # → GitHub only
git push gitlab main     # → GitLab only

# Or push to both via shell alias (~/.bashrc)
alias gpush='git push origin main && git push gitlab main'
```

---

## 12. Importing Projects from GitHub to GitLab

### 12.1 Method A: GitLab Built-in GitHub Importer (Full Import)

This imports repos, issues, PRs (as merge requests), labels, milestones, and wiki.

1. Log into GitLab
2. Click **New Project** → **Import Project** → **GitHub**
3. Enter a GitHub **Personal Access Token** (generate at https://github.com/settings/tokens with `repo` scope)
4. Select repositories to import
5. Click **Import**

### 12.2 Method B: Git Mirror (Code Only)

For a simple code-only migration:

```bash
# Clone from GitHub (mirror includes all branches + tags)
git clone --mirror https://github.com/user/project.git
cd project.git

# Create the target project in GitLab first (via UI or API)

# Push to GitLab
git remote set-url origin ssh://git@gitlab.yourdomain.com:2222/group/project.git
git push --mirror
```

### 12.3 Method B Batch Script (Multiple Repos)

```bash
#!/bin/bash
# migrate_repos.sh
# Usage: ./migrate_repos.sh

GITHUB_USER="your-github-username"
GITLAB_URL="ssh://git@gitlab.yourdomain.com:2222"
GITLAB_GROUP="your-group"

REPOS=(
  "repo1"
  "repo2"
  "repo3"
)

for REPO in "${REPOS[@]}"; do
  echo "=== Migrating: $REPO ==="
  git clone --mirror "https://github.com/${GITHUB_USER}/${REPO}.git"
  cd "${REPO}.git"
  git remote set-url origin "${GITLAB_URL}/${GITLAB_GROUP}/${REPO}.git"
  git push --mirror
  cd ..
  rm -rf "${REPO}.git"
  echo "=== Done: $REPO ==="
  echo ""
done
```

> **Note:** Target projects must already exist in GitLab before running the mirror push.

---

## 13. Backup Strategy

### 13.1 What Gets Backed Up

GitLab has **two separate backup scopes**:

| Scope | Includes | Command |
|-------|----------|---------|
| **Application backup** | Repositories, database, uploads, CI/CD artifacts, LFS objects | `gitlab-backup create` |
| **Configuration backup** | `gitlab.rb`, secrets, SSL certificates | Manual `tar` (see below) |

> **IMPORTANT:** The application backup does **NOT** include `gitlab.rb` or the secrets file. You must back up configuration separately.

### 13.2 Default Backup Behavior

By default, GitLab backups are **plain, unencrypted `.tar` files**. Anyone with access to the backup file can extract and read all contents including source code, database, and user data.

For many on-prem environments behind a secured network, this is acceptable. If your backups leave the server or are stored on shared storage, consider enabling encryption (see [Section 13.5](#135-optional-enable-backup-encryption)).

### 13.3 Manual Backup

```bash
# Application backup (output goes to /var/gitlab/data/backups/)
docker exec -t gitlab gitlab-backup create

# Configuration backup (separate — always do this alongside application backup)
tar czf /var/gitlab/backups/gitlab_config_$(date +%Y%m%d_%H%M%S).tar.gz \
  -C /var/gitlab config/
```

### 13.4 Automated Daily Backup Script

Create the backup script:

```bash
cat > /var/gitlab/backup-gitlab.sh << 'SCRIPT'
#!/bin/bash
#
# GitLab Automated Backup Script
# Runs via cron — backs up application data + configuration
#

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/var/gitlab/backups"
LOG="${LOG_DIR}/backup_${TIMESTAMP}.log"

echo "=== GitLab Backup Started: $(date) ===" >> "$LOG"

# --- Application Backup ---
echo "[1/3] Running GitLab application backup..." >> "$LOG"
docker exec -t gitlab gitlab-backup create >> "$LOG" 2>&1

# --- Configuration Backup ---
# gitlab.rb and secrets are NOT included in the application backup
echo "[2/3] Backing up GitLab configuration..." >> "$LOG"
tar czf "${LOG_DIR}/gitlab_config_${TIMESTAMP}.tar.gz" \
  -C /var/gitlab config/ >> "$LOG" 2>&1

# --- Cleanup old backups (older than 7 days) ---
echo "[3/3] Cleaning up old backups..." >> "$LOG"
find "$LOG_DIR" -name "*.tar"    -mtime +7  -delete >> "$LOG" 2>&1
find "$LOG_DIR" -name "*.tar.gz" -mtime +7  -delete >> "$LOG" 2>&1
find "$LOG_DIR" -name "backup_*.log" -mtime +30 -delete >> "$LOG" 2>&1

echo "=== GitLab Backup Completed: $(date) ===" >> "$LOG"
SCRIPT
```

Set permissions and schedule:

```bash
chmod 700 /var/gitlab/backup-gitlab.sh

# Schedule daily at 2:00 AM
(crontab -l 2>/dev/null; echo "0 2 * * * /var/gitlab/backup-gitlab.sh") | crontab -

# Verify cron
crontab -l
```

### 13.5 OPTIONAL: Enable Backup Encryption

> **This section is optional.** Enable encryption if backups are stored on shared/remote storage, transferred off-server, or if your security policy requires it.

#### 13.5.1 Enable Application Backup Encryption

Edit `gitlab.rb`:

```bash
vi /var/gitlab/config/gitlab.rb
```

Add the following:

```ruby
##############################################
# BACKUP ENCRYPTION (OPTIONAL)
##############################################
gitlab_rails['backup_encryption']     = 'AES256'
gitlab_rails['backup_encryption_key'] = 'CHANGE-THIS-TO-A-STRONG-KEY-MIN-32-CHARACTERS!!'
```

Apply the configuration:

```bash
docker exec -it gitlab gitlab-ctl reconfigure
```

From this point forward, all application backups created by `gitlab-backup create` will be AES-256 encrypted.

#### 13.5.2 Enable Configuration Backup Encryption

Replace the config backup line in the backup script (`/var/gitlab/backup-gitlab.sh`) with:

```bash
# --- Configuration Backup (encrypted) ---
echo "[2/3] Backing up GitLab configuration (encrypted)..." >> "$LOG"
tar cz -C /var/gitlab config/ | \
  openssl enc -aes-256-cbc -salt -pbkdf2 \
  -pass pass:"YOUR-STRONG-CONFIG-BACKUP-PASSWORD" \
  -out "${LOG_DIR}/gitlab_config_${TIMESTAMP}.tar.gz.enc" >> "$LOG" 2>&1
```

Also update the cleanup section to match:

```bash
find "$LOG_DIR" -name "*.tar.gz.enc" -mtime +7 -delete >> "$LOG" 2>&1
```

#### 13.5.3 Decrypting an Encrypted Config Backup

```bash
openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass pass:'YOUR-STRONG-CONFIG-BACKUP-PASSWORD' \
  -in /var/gitlab/backups/gitlab_config_20260221_020000.tar.gz.enc \
  -out gitlab_config_decrypted.tar.gz

tar xzf gitlab_config_decrypted.tar.gz
```

#### 13.5.4 Encryption Key Management — CRITICAL

> **WARNING: READ THIS CAREFULLY BEFORE ENABLING ENCRYPTION**

**Where to store your encryption keys:**

| Storage Method | Suitability |
|---|---|
| Password manager (1Password, BitWarden, KeePass) | Recommended |
| Hardware Security Module (HSM) | Enterprise-grade |
| Sealed envelope in a physical safe | Acceptable for small teams |
| Separate secured server / vault (HashiCorp Vault) | Recommended |

**Where NOT to store your encryption keys:**

| Bad Practice | Why |
|---|---|
| On the same GitLab server only | If the server dies, both backups AND key are lost |
| In the GitLab repository itself | Defeats the purpose of encryption |
| In an email or chat message | Can be compromised or lost |
| Nowhere (memorized only) | Human memory is not reliable |

**What happens if you lose the encryption key:**

- All encrypted application backups (`.tar`) become **permanently unrecoverable**
- All encrypted configuration backups (`.tar.gz.enc`) become **permanently unrecoverable**
- There is **NO backdoor, NO recovery mechanism, NO way to decrypt** without the original key
- You would need to rebuild GitLab from scratch and lose all data that was not backed up elsewhere
- AES-256 encryption is mathematically infeasible to brute-force — the data is gone forever

**Best practice:** Store the key in **at least two separate secure locations** and test decryption periodically to confirm the key works.

### 13.6 Restoring from Backup

```bash
# Stop processes that connect to the database
docker exec -it gitlab gitlab-ctl stop puma
docker exec -it gitlab gitlab-ctl stop sidekiq

# Verify they are stopped
docker exec -it gitlab gitlab-ctl status

# Restore (use the backup timestamp — e.g., 1708473600_2026_02_21_16.8.1)
docker exec -it gitlab gitlab-backup restore BACKUP=<timestamp>

# Restart GitLab
docker exec -it gitlab gitlab-ctl restart

# Run integrity check
docker exec -it gitlab gitlab-rake gitlab:check SANITIZE=true
```

> **Note:** If restoring an encrypted backup, GitLab will use the encryption key from `gitlab.rb` to decrypt automatically. The same key that was used to create the backup **must** be present in `gitlab.rb` at restore time.

---

## 14. Updating GitLab

### 14.1 Pre-Update Checklist

```bash
# 1. Check current version
docker exec -it gitlab gitlab-rake gitlab:env:info

# 2. Create a backup before updating
docker exec -t gitlab gitlab-backup create

# 3. Backup the configuration
tar czf /var/gitlab/backups/pre_update_config_$(date +%Y%m%d).tar.gz \
  -C /var/gitlab config/
```

### 14.2 Perform the Update

```bash
# Pull latest image
docker pull gitlab/gitlab-ce:latest

# Stop and remove the container (DATA IS SAFE in /var/gitlab)
docker stop gitlab
docker rm gitlab

# Deploy with the new image (same command as original deployment)
docker run -d \
  --hostname gitlab.yourdomain.com \
  --name gitlab \
  --restart always \
  -p 443:443 \
  -p 80:80 \
  -p 2222:22 \
  --shm-size 256m \
  -v /var/gitlab/config:/etc/gitlab \
  -v /var/gitlab/logs:/var/log/gitlab \
  -v /var/gitlab/data:/var/opt/gitlab \
  gitlab/gitlab-ce:latest
```

### 14.3 Post-Update Verification

```bash
# Watch startup logs
docker logs -f gitlab

# Once started, verify version
docker exec -it gitlab gitlab-rake gitlab:env:info

# Run health check
docker exec -it gitlab gitlab-rake gitlab:check SANITIZE=true
```

---

## 15. Maintenance & Troubleshooting

### 15.1 Container Management

```bash
# Check container status
docker ps --filter name=gitlab

# Stop GitLab
docker stop gitlab

# Start GitLab
docker start gitlab

# Restart GitLab
docker restart gitlab

# View logs (last 100 lines, follow)
docker logs -f gitlab --tail 100

# Check resource usage
docker stats gitlab --no-stream
```

### 15.2 GitLab Internal Services

```bash
# Check all service statuses
docker exec -it gitlab gitlab-ctl status

# Restart a specific service
docker exec -it gitlab gitlab-ctl restart nginx
docker exec -it gitlab gitlab-ctl restart puma
docker exec -it gitlab gitlab-ctl restart sidekiq
docker exec -it gitlab gitlab-ctl restart postgresql

# Reconfigure (after editing gitlab.rb)
docker exec -it gitlab gitlab-ctl reconfigure

# Tail specific logs
docker exec -it gitlab gitlab-ctl tail nginx
docker exec -it gitlab gitlab-ctl tail puma
```

### 15.3 Health Checks

```bash
# Full system check
docker exec -it gitlab gitlab-rake gitlab:check SANITIZE=true

# Check HTTPS certificate from outside
openssl s_client -connect gitlab.yourdomain.com:443 -showcerts </dev/null 2>/dev/null | \
  openssl x509 -noout -dates

# Check GitLab version and environment
docker exec -it gitlab gitlab-rake gitlab:env:info
```

### 15.4 Common Issues

#### Container won't start — port conflict

```bash
# Check what is using a port
ss -tlnp | grep ':80\|:443\|:2222'

# Fix: stop the conflicting service or change port mapping
```

#### SELinux denying access

```bash
# Check for SELinux denials
ausearch -m avc -ts recent

# Re-apply context if needed
restorecon -Rv /var/gitlab
```

#### GitLab is slow / unresponsive

```bash
# Check memory
docker stats gitlab --no-stream

# Check if swap is being used heavily
free -h

# Check disk space
df -h /var/gitlab
```

#### HTTPS certificate errors

```bash
# Verify certificate is valid and not expired
openssl x509 -in /var/gitlab/config/ssl/gitlab.yourdomain.com.crt -noout -dates

# Verify certificate matches key
openssl x509 -noout -modulus -in /var/gitlab/config/ssl/gitlab.yourdomain.com.crt | md5sum
openssl rsa  -noout -modulus -in /var/gitlab/config/ssl/gitlab.yourdomain.com.key | md5sum

# Reload NGINX after certificate replacement
docker exec -it gitlab gitlab-ctl restart nginx
```

#### Need to reset root password

```bash
docker exec -it gitlab gitlab-rake "gitlab:password:reset[root]"
```

---

## 16. Quick Reference Card

### Essential Commands

| Task                  | Command                                                              |
|-----------------------|----------------------------------------------------------------------|
| Start GitLab          | `docker start gitlab`                                                |
| Stop GitLab           | `docker stop gitlab`                                                 |
| Restart GitLab        | `docker restart gitlab`                                              |
| View logs             | `docker logs -f gitlab --tail 100`                                   |
| Reconfigure           | `docker exec -it gitlab gitlab-ctl reconfigure`                      |
| Service status        | `docker exec -it gitlab gitlab-ctl status`                           |
| Manual backup         | `docker exec -t gitlab gitlab-backup create`                         |
| Check version         | `docker exec -it gitlab gitlab-rake gitlab:env:info`                 |
| Health check          | `docker exec -it gitlab gitlab-rake gitlab:check SANITIZE=true`      |
| Reset root password   | `docker exec -it gitlab gitlab-rake "gitlab:password:reset[root]"`   |
| Restart NGINX         | `docker exec -it gitlab gitlab-ctl restart nginx`                    |

### Key Paths on Host

| Path                          | Contents                        |
|-------------------------------|---------------------------------|
| `/var/gitlab/config/`         | gitlab.rb, secrets, SSL certs   |
| `/var/gitlab/config/ssl/`     | TLS certificates and keys       |
| `/var/gitlab/data/`           | Repositories, DB, uploads       |
| `/var/gitlab/logs/`           | All GitLab logs                 |
| `/var/gitlab/backups/`        | Backup archives and logs        |
| `/var/gitlab/backup-gitlab.sh`| Automated backup script         |

### Key URLs

| URL                                        | Purpose            |
|--------------------------------------------|--------------------|
| `https://gitlab.yourdomain.com`            | Web UI             |
| `https://gitlab.yourdomain.com/admin`      | Admin Area         |
| `https://gitlab.yourdomain.com/-/health`   | Health check endpoint |

### Ports

| Port | Service                 |
|------|-------------------------|
| 443  | HTTPS (Web UI + API)    |
| 80   | HTTP (redirects to 443) |
| 2222 | Git over SSH            |

---

*End of SOP*
