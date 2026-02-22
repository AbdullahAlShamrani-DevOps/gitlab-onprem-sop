# GitLab CE On-Premises Deployment — Standard Operating Procedure

**Platform:** Oracle Enterprise Linux 9 (OEL 9)
**Deployment Method:** Docker Compose
**Edition:** GitLab Community Edition (CE) — Free
**Document Version:** 1.4
**Date:** 2026-02-21

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites & System Requirements](#2-prerequisites--system-requirements)
3. [Docker Installation](#3-docker-installation)
4. [Volume Preparation (Permissions & Ownership)](#4-volume-preparation-permissions--ownership)
5. [SSL Certificate Preparation](#5-ssl-certificate-preparation)
6. [GitLab Container Deployment](#6-gitlab-container-deployment)
7. [GitLab Configuration (HTTPS, SSH, Backups)](#7-gitlab-configuration-https-ssh-backups)
8. [Firewall Configuration](#8-firewall-configuration)
9. [First Login & Initial Hardening](#9-first-login--initial-hardening)
10. [Microsoft Entra ID SSO Integration (OIDC)](#10-microsoft-entra-id-sso-integration-oidc)
11. [Client-Side CA Trust Configuration](#11-client-side-ca-trust-configuration)
12. [Dual Push: GitLab On-Prem + GitHub](#12-dual-push-gitlab-on-prem--github)
13. [Importing Projects from GitHub to GitLab](#13-importing-projects-from-github-to-gitlab)
14. [Backup Strategy](#14-backup-strategy)
15. [Updating GitLab](#15-updating-gitlab)
16. [Maintenance & Troubleshooting](#16-maintenance--troubleshooting)
17. [Quick Reference Card](#17-quick-reference-card)
18. [SMTP / Email Notification Configuration](#18-smtp--email-notification-configuration)
19. [Essential Git Commands Reference](#19-essential-git-commands-reference)
20. [Monitoring with Site24x7](#20-monitoring-with-site24x7)
21. [User & Group Management Best Practices](#21-user--group-management-best-practices)

---

## 1. Overview

### What This SOP Covers

Deployment of a self-hosted GitLab CE instance running in Docker on OEL 9, with:

- HTTPS using self-signed or CA-signed certificate (internal or public CA)
- SSH access on a non-standard port (2222)
- SSO authentication via Microsoft Entra ID (OpenID Connect)
- Automated backups (with optional encryption)
- Dual-push mirroring to GitHub
- Migration path from GitHub SaaS to GitLab on-prem
- SMTP email notification setup (Office 365, Gmail, generic SMTP)
- Essential Git commands reference for developers
- Monitoring integration with Site24x7
- User and group management with role-based access

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

### 2.5 SSL Certificate Files

Choose your SSL approach (detailed in [Section 5](#5-ssl-certificate-preparation)):

**Option A — Self-Signed:** No files needed; you will generate them in Section 5.

**Option B — CA-Signed:** Before proceeding, ensure you have:

| File               | Description                           | Required?                    |
|--------------------|---------------------------------------|------------------------------|
| `your_domain.crt`  | Your server/domain certificate        | Yes                          |
| `your_domain.key`  | Your private key                      | Yes                          |
| `ca_bundle.crt`    | CA chain (intermediates + root CA)    | Yes (if provided by your CA) |
| `your_ca_root.crt` | Your CA root certificate (standalone) | Internal CA only             |

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

### 3.6 Fix Docker Socket Path (OEL 9)

On some OEL 9 installations, the Docker CLI expects the socket at `/var/run/docker.sock` but the daemon creates it at `/run/docker.sock`. If you get `dial unix /var/run/docker.sock: connect: no such file or directory` even though Docker is running, fix it:

```bash
# Check if docker commands work
docker info > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Fixing Docker socket context..."
  docker context update default --docker "host=unix:///run/docker.sock"
fi

# Verify fix
docker info | head -5
```

### 3.7 Verify Installation

```bash
docker --version
docker compose version
docker run hello-world
```

Expected: `Hello from Docker!` and Docker Compose version output (v2.x).

### 3.8 Clean Up Verification Container

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

## 5. SSL Certificate Preparation

Choose one of the two options below based on your environment:

| Option | Best For | Browser Trust | Client-Side Setup |
|---|---|---|---|
| **A — Self-Signed** | Lab, testing, internal-only with no CA | No — browsers show warning | Must install cert on every client |
| **B — CA-Signed Certificate** | Production, any environment with a CA (internal or public) | Yes (if CA is trusted) | Only needed for internal/private CAs |

---

### Option A: Self-Signed Certificate

> **Use this if** you don't have a Certificate Authority and need a quick, working HTTPS setup. Browsers will show a security warning, and developers will need to install the certificate or configure Git to trust it.

#### 5A.1 Generate Self-Signed Certificate

```bash
openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
  -keyout /var/gitlab/config/ssl/gitlab.yourdomain.com.key \
  -out /var/gitlab/config/ssl/gitlab.yourdomain.com.crt \
  -subj "/C=SA/ST=Riyadh/L=Riyadh/O=YourOrganization/CN=gitlab.yourdomain.com" \
  -addext "subjectAltName=DNS:gitlab.yourdomain.com,IP:YOUR.SERVER.IP"
```

**Replace:**
- `gitlab.yourdomain.com` with your actual FQDN
- `YOUR.SERVER.IP` with your server's IP address
- `/C=SA/ST=Riyadh/L=Riyadh/O=YourOrganization` with your details

> **CRITICAL:** The filename MUST match the FQDN used in `external_url`.
> If your URL is `https://gitlab.yourdomain.com`, the files must be named `gitlab.yourdomain.com.crt` and `gitlab.yourdomain.com.key`.

#### 5A.2 Set Permissions

```bash
chmod 600 /var/gitlab/config/ssl/gitlab.yourdomain.com.key
chmod 644 /var/gitlab/config/ssl/gitlab.yourdomain.com.crt
chown root:root /var/gitlab/config/ssl/*
```

#### 5A.3 Verify the Certificate

```bash
# View certificate details
openssl x509 -in /var/gitlab/config/ssl/gitlab.yourdomain.com.crt -text -noout | head -15

# Verify cert and key match
openssl x509 -noout -modulus -in /var/gitlab/config/ssl/gitlab.yourdomain.com.crt | md5sum
openssl rsa  -noout -modulus -in /var/gitlab/config/ssl/gitlab.yourdomain.com.key | md5sum
```

Both md5sums must match.

#### 5A.4 Certificate Renewal

Self-signed certificates expire (365 days with the command above). To renew, re-run the `openssl req` command from Step 5A.1 and then restart NGINX:

```bash
docker exec -it gitlab gitlab-ctl restart nginx
```

#### 5A.5 Client-Side Trust for Self-Signed

Since there is no CA, every client must trust the certificate directly. See [Section 11](#11-client-side-ca-trust-configuration) — use the `gitlab.yourdomain.com.crt` file instead of a CA root certificate.

Developer Git configuration:

```bash
# Trust the self-signed cert for Git operations
git config --global http.sslCAInfo /path/to/gitlab.yourdomain.com.crt
```

#### 5A.6 gitlab.rb Configuration (Self-Signed)

When configuring `gitlab.rb` in [Section 7](#7-gitlab-configuration-https-ssh-backups), use:

```ruby
##############################################
# NGINX / SSL CONFIGURATION (Self-Signed)
##############################################
nginx['ssl_certificate']           = "/etc/gitlab/ssl/gitlab.yourdomain.com.crt"
nginx['ssl_certificate_key']       = "/etc/gitlab/ssl/gitlab.yourdomain.com.key"
nginx['redirect_http_to_https']    = true
nginx['ssl_protocols']             = "TLSv1.2 TLSv1.3"
nginx['ssl_ciphers']               = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
nginx['ssl_prefer_server_ciphers'] = "on"

##############################################
# INTERNAL TRUST (Self-Signed)
# Required for GitLab to trust its own cert
##############################################
gitlab_workhorse['env'] = {
  'SSL_CERT_FILE' => '/etc/gitlab/ssl/gitlab.yourdomain.com.crt'
}
```

> **Note:** For self-signed, the `SSL_CERT_FILE` points to the certificate itself since there is no separate CA root.

#### 5A.7 Final SSL Directory (Self-Signed)

```bash
ls -la /var/gitlab/config/ssl/
```

Expected:

```
drwx------  root root  .
drwxr-xr-x  root root  ..
-rw-r--r--  root root  gitlab.yourdomain.com.crt
-rw-------  root root  gitlab.yourdomain.com.key
```

---

### Option B: CA-Signed Certificate (Internal or Public CA)

> **Use this if** you have a Certificate Authority — either an internal/private CA (e.g., Active Directory Certificate Services, HashiCorp Vault) or a public CA (e.g., DigiCert, Let's Encrypt, Sectigo).

#### 5B.1 Identify Your Certificate Type

| Type | Issuer Example | Browser Trust | Client CA Setup |
|---|---|---|---|
| **Public CA** | DigiCert, Let's Encrypt, Sectigo, GoDaddy | Trusted automatically | Not needed |
| **Internal/Private CA** | AD CS, internal PKI, custom OpenSSL CA | Not trusted by default | Required (see Section 11) |

#### 5B.2 Required Files

You should have the following from your CA:

| File | Description |
|---|---|
| `your_domain.crt` | Your server/domain certificate |
| `your_domain.key` | Your private key |
| `ca_bundle.crt` | CA chain (intermediates + root) — may not be needed for some public CAs |
| `your_ca_root.crt` | CA root certificate (for internal CAs only) |

#### 5B.3 Create the Full-Chain Certificate

The certificate file must contain: **server cert → intermediate(s) → root CA**, in that order.

```bash
cat your_domain.crt ca_bundle.crt > /var/gitlab/config/ssl/gitlab.yourdomain.com.crt
```

> **CRITICAL:** The filename MUST match the FQDN used in `external_url`.
> If your URL is `https://gitlab.yourdomain.com`, the file must be named `gitlab.yourdomain.com.crt`.

> **Public CA note:** If your public CA (e.g., DigiCert) provides a separate intermediate certificate, download it from the CA's website and include it in the chain. Example for DigiCert:
> ```bash
> curl -o digicert_intermediate.crt \
>   https://cacerts.digicert.com/DigiCertGlobalG2TLSRSASHA2562020CA1-1.crt.pem
> cat your_domain.crt digicert_intermediate.crt > /var/gitlab/config/ssl/gitlab.yourdomain.com.crt
> ```

#### 5B.4 Copy the Private Key

```bash
cp your_domain.key /var/gitlab/config/ssl/gitlab.yourdomain.com.key
```

#### 5B.5 Copy the CA Root Certificate (Internal CA Only)

This is used so GitLab trusts its own certificate for internal calls (webhooks, API, etc.).

```bash
# Only needed for internal/private CAs
cp your_ca_root.crt /var/gitlab/config/ssl/your_ca_root.crt
```

> **Public CA:** Skip this step. Public CA roots are already in the system trust store.

#### 5B.6 Set Certificate Permissions

```bash
# Private key — most restrictive
chmod 600 /var/gitlab/config/ssl/gitlab.yourdomain.com.key

# Certificates — readable
chmod 644 /var/gitlab/config/ssl/gitlab.yourdomain.com.crt

# CA root (if present)
[ -f /var/gitlab/config/ssl/your_ca_root.crt ] && chmod 644 /var/gitlab/config/ssl/your_ca_root.crt

# Ownership
chown root:root /var/gitlab/config/ssl/*
```

#### 5B.7 Verify Certificate and Key Match

```bash
# These two commands MUST produce the same MD5 hash
openssl x509 -noout -modulus -in /var/gitlab/config/ssl/gitlab.yourdomain.com.crt | md5sum
openssl rsa  -noout -modulus -in /var/gitlab/config/ssl/gitlab.yourdomain.com.key | md5sum
```

If the hashes do NOT match, the certificate and key do not belong together. Do not proceed.

#### 5B.8 Verify Certificate Details

```bash
# View certificate subject and issuer
openssl x509 -in /var/gitlab/config/ssl/gitlab.yourdomain.com.crt -text -noout | head -20

# Verify chain of trust (internal CA)
openssl verify -CAfile /var/gitlab/config/ssl/your_ca_root.crt \
  /var/gitlab/config/ssl/gitlab.yourdomain.com.crt

# Verify chain of trust (public CA — uses system trust store)
openssl verify /var/gitlab/config/ssl/gitlab.yourdomain.com.crt
```

Expected output: `gitlab.yourdomain.com.crt: OK`

#### 5B.9 gitlab.rb Configuration (CA-Signed)

When configuring `gitlab.rb` in [Section 7](#7-gitlab-configuration-https-ssh-backups), use:

**For Internal/Private CA:**

```ruby
##############################################
# NGINX / SSL CONFIGURATION (Internal CA)
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
##############################################
gitlab_workhorse['env'] = {
  'SSL_CERT_FILE' => '/etc/gitlab/ssl/your_ca_root.crt'
}
```

**For Public CA (DigiCert, Let's Encrypt, etc.):**

```ruby
##############################################
# NGINX / SSL CONFIGURATION (Public CA)
##############################################
nginx['ssl_certificate']           = "/etc/gitlab/ssl/gitlab.yourdomain.com.crt"
nginx['ssl_certificate_key']       = "/etc/gitlab/ssl/gitlab.yourdomain.com.key"
nginx['redirect_http_to_https']    = true
nginx['ssl_protocols']             = "TLSv1.2 TLSv1.3"
nginx['ssl_ciphers']               = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
nginx['ssl_prefer_server_ciphers'] = "on"

# No gitlab_workhorse SSL_CERT_FILE needed — public CAs are already trusted
```

> **Client-side:** Internal/private CA requires client-side trust setup (see [Section 11](#11-client-side-ca-trust-configuration)). Public CA does not.

#### 5B.10 Final SSL Directory (CA-Signed)

```bash
ls -la /var/gitlab/config/ssl/
```

**Internal CA — expected:**

```
drwx------  root root  .
drwxr-xr-x  root root  ..
-rw-r--r--  root root  gitlab.yourdomain.com.crt
-rw-------  root root  gitlab.yourdomain.com.key
-rw-r--r--  root root  your_ca_root.crt
```

**Public CA — expected:**

```
drwx------  root root  .
drwxr-xr-x  root root  ..
-rw-r--r--  root root  gitlab.yourdomain.com.crt
-rw-------  root root  gitlab.yourdomain.com.key
```

---

## 6. GitLab Container Deployment

### 6.1 Create Docker Compose File

```bash
cat > /var/gitlab/docker-compose.yml << 'EOF'
services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: gitlab
    hostname: gitlab.yourdomain.com
    restart: always
    shm_size: '256m'
    ports:
      - "443:443"
      - "80:80"
      - "2222:22"
    volumes:
      - /var/gitlab/config:/etc/gitlab
      - /var/gitlab/logs:/var/log/gitlab
      - /var/gitlab/data:/var/opt/gitlab
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://gitlab.yourdomain.com'
EOF
```

> **Replace** `gitlab.yourdomain.com` with your actual FQDN (appears twice in the file).

**Port mapping explained:**

| Host Port | Container Port | Purpose                                    |
|-----------|---------------|--------------------------------------------|
| 443       | 443           | HTTPS                                      |
| 80        | 80            | HTTP (will redirect to HTTPS)              |
| 2222      | 22            | SSH (port 22 is used by host SSH service)  |

### 6.2 Deploy GitLab

```bash
cd /var/gitlab
docker compose up -d
```

### 6.3 Verify Container is Running

```bash
docker compose -f /var/gitlab/docker-compose.yml ps
```

### 6.4 Wait for Initial Configuration

First boot takes **3–5 minutes**. Watch the logs:

```bash
docker compose -f /var/gitlab/docker-compose.yml logs -f
```

Wait until you see `gitlab Reconfigured!`, then press `Ctrl+C`.

> **How to know GitLab is ready:** After the initial `Reconfigured!` message, the logs will show repeating health-check entries (e.g., `GET /database`, `GET /sidekiq`, `GET /ruby`, `GET /-/metrics`). This is **normal steady-state behavior** — it means all services are running and GitLab is ready to use. Press `Ctrl+C` to exit the log view.

---

## 7. GitLab Configuration (HTTPS, SSH, Backups)

### 7.1 Edit GitLab Configuration File

```bash
vi /var/gitlab/config/gitlab.rb
```

### 7.2 Configuration Block

Add or modify the following sections in `gitlab.rb`. **Choose the correct SSL trust block based on your certificate type:**

> **IMPORTANT — Read Before Configuring:**
>
> | Certificate Type | `gitlab_workhorse` SSL_CERT_FILE | Action |
> |---|---|---|
> | **Self-Signed** (Option A) | Point to the `.crt` file itself | **Required** |
> | **Internal/Private CA** (Option B) | Point to your CA root cert | **Required** |
> | **Public CA** — DigiCert, Let's Encrypt, etc. (Option B) | **DO NOT ADD this block** | **Skip it entirely** |
>
> Public CAs (DigiCert, Let's Encrypt, Sectigo, GoDaddy, etc.) are already in the system trust store. Adding `gitlab_workhorse SSL_CERT_FILE` is unnecessary and can cause issues.

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
# INTERNAL CA / SELF-SIGNED TRUST
#
# >>> PUBLIC CA (DigiCert, Let's Encrypt, etc.):
#     DO NOT add this block. Delete or skip it.
#     Public CAs are already trusted by the system.
#
# >>> SELF-SIGNED CERTIFICATE:
#     Uncomment and point to the .crt file:
#     gitlab_workhorse['env'] = {
#       'SSL_CERT_FILE' => '/etc/gitlab/ssl/gitlab.yourdomain.com.crt'
#     }
#
# >>> INTERNAL/PRIVATE CA:
#     Uncomment and point to your CA root cert:
#     gitlab_workhorse['env'] = {
#       'SSL_CERT_FILE' => '/etc/gitlab/ssl/your_ca_root.crt'
#     }
##############################################

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
# MONITORING — Health Endpoint Access
# By default, /-/health, /-/readiness, /-/liveness
# are restricted to localhost only.
# Uncomment and add IPs/CIDRs that need access
# (e.g., Site24x7 probes, load balancers).
# Use '0.0.0.0/0' to allow all (less secure).
##############################################
gitlab_rails['monitoring_whitelist'] = ['127.0.0.0/8', '::1/128', '0.0.0.0/0']

##############################################
# BACKUP CONFIGURATION
##############################################
gitlab_rails['backup_path']       = "/var/opt/gitlab/backups"
gitlab_rails['backup_keep_time']  = 604800
```

> **Note:** Backups are unencrypted by default. See [Section 14.5](#145-optional-enable-backup-encryption) to enable encryption.

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

## 10. Microsoft Entra ID SSO Integration (OIDC)

GitLab CE (free, self-managed) **fully supports SSO** via OpenID Connect (OIDC) with Microsoft Entra ID (formerly Azure AD). No paid GitLab license is required.

> **Why OIDC over SAML?** OIDC is the recommended approach for Entra ID integration. It uses the modern Microsoft identity platform (v2.0) endpoint and is simpler to configure than SAML.

### 10.1 What You Get with SSO

| Feature | Supported in CE (Free)? |
|---|---|
| Instance-level SSO via OIDC | Yes |
| Instance-level SSO via SAML | Yes |
| Login with Microsoft Entra ID | Yes |
| Auto-create users on first login | Yes |
| Group-level SAML SSO | No (Premium only) |
| SCIM provisioning (auto user sync) | No (Premium only) |

### 10.2 Step 1: Create App Registration in Entra ID

1. Go to **Microsoft Entra admin center** → **Identity** → **Applications** → **App registrations**
2. Click **New registration**
3. Fill in:
   - **Name:** `GitLab SSO`
   - **Supported account types:** "Accounts in this organizational directory only" (single tenant)
   - **Redirect URI:** Select **Web** and enter:
     ```
     https://gitlab.yourdomain.com/users/auth/openid_connect/callback
     ```
4. Click **Register**

### 10.3 Step 2: Create Client Secret

1. In your new app registration, go to **Certificates & secrets**
2. Click **New client secret**
3. Add a description (e.g., `GitLab OIDC`) and select expiration (recommended: 24 months)
4. Click **Add**
5. **Copy the secret Value immediately** — it will not be shown again

### 10.4 Step 3: Configure API Permissions

1. Go to **API permissions**
2. Click **Add a permission** → **Microsoft Graph** → **Delegated permissions**
3. Add the following permissions:
   - `email`
   - `openid`
   - `profile`
4. Click **Add permissions**
5. Click **Grant admin consent for [your organization]**
6. Verify all permissions show a green checkmark under "Status"

### 10.5 Step 4: Gather Required Values

From the app registration **Overview** page, record these values:

| Value | Where to Find | Used As |
|---|---|---|
| **Application (client) ID** | Overview page | `identifier` in gitlab.rb |
| **Directory (tenant) ID** | Overview page | Part of `issuer` URL in gitlab.rb |
| **Client secret value** | Certificates & secrets (copied in Step 2) | `secret` in gitlab.rb |

### 10.6 Step 5: Configure GitLab

Edit the GitLab configuration:

```bash
vi /var/gitlab/config/gitlab.rb
```

Add the following block (replace the placeholder values):

```ruby
##############################################
# MICROSOFT ENTRA ID SSO (OpenID Connect)
##############################################

# Allow users to sign in via Entra ID
gitlab_rails['omniauth_enabled'] = true

# Allow first-time SSO users to be created automatically
gitlab_rails['omniauth_allow_single_sign_on'] = ['openid_connect']

# Automatically link Entra ID accounts to existing GitLab accounts
# if the email matches (set to false if you want manual linking)
gitlab_rails['omniauth_auto_link_user'] = ['openid_connect']

# Block login via password for SSO users (optional — set true to enforce SSO-only)
gitlab_rails['omniauth_block_auto_created_users'] = false

gitlab_rails['omniauth_providers'] = [
  {
    name: "openid_connect",
    label: "Microsoft Entra ID",
    args: {
      name: "openid_connect",
      scope: ["openid", "profile", "email"],
      response_type: "code",
      issuer: "https://login.microsoftonline.com/YOUR-TENANT-ID/v2.0",
      discovery: true,
      client_auth_method: "query",
      uid_field: "sub",
      send_scope_to_token_endpoint: "false",
      pkce: true,
      client_options: {
        identifier: "YOUR-CLIENT-ID",
        secret: "YOUR-CLIENT-SECRET",
        redirect_uri: "https://gitlab.yourdomain.com/users/auth/openid_connect/callback"
      }
    }
  }
]
```

**Replace the following placeholders:**

| Placeholder | Replace With |
|---|---|
| `YOUR-TENANT-ID` | Directory (tenant) ID from Entra ID |
| `YOUR-CLIENT-ID` | Application (client) ID from Entra ID |
| `YOUR-CLIENT-SECRET` | Client secret value from Step 2 |
| `gitlab.yourdomain.com` | Your actual GitLab FQDN |

### 10.7 Step 6: Apply Configuration

```bash
docker exec -it gitlab gitlab-ctl reconfigure
```

Wait for: `gitlab Reconfigured!`

### 10.8 Step 7: Verify SSO

1. Open `https://gitlab.yourdomain.com` in a browser
2. You should see a **"Microsoft Entra ID"** button on the login page below the standard username/password fields
3. Click it — you will be redirected to Microsoft login
4. After authenticating, you will be redirected back to GitLab and logged in
5. The user account is auto-created on first login (if `omniauth_allow_single_sign_on` is enabled)

### 10.9 Optional: Enforce SSO-Only Login

To **disable password login** and force all users through Entra ID:

```bash
vi /var/gitlab/config/gitlab.rb
```

```ruby
# Disable password-based sign-in for all users except root
gitlab_rails['gitlab_signin_enabled'] = false
```

```bash
docker exec -it gitlab gitlab-ctl reconfigure
```

> **WARNING:** Always keep the `root` account accessible via password as a break-glass emergency login. If Entra ID is down, you need a way to access GitLab. The root account can still log in via `https://gitlab.yourdomain.com/users/sign_in?auto_sign_in=false`

### 10.10 Optional: Restrict Access to Specific Entra ID Groups

If you only want members of certain Entra ID groups to access GitLab:

**In Entra ID:**

1. Go to your app registration → **Token configuration**
2. Click **Add groups claim**
3. Select **Security groups**
4. Under "ID" token type, select **Group ID**
5. Click **Add**

**In gitlab.rb**, add `allowed_groups` to the provider config:

```ruby
# Inside the args: { ... } block, add:
allowed_groups: ["YOUR-ENTRA-GROUP-ID-1", "YOUR-ENTRA-GROUP-ID-2"]
```

> The group IDs are UUIDs from Entra ID (e.g., `55db8574-c392-4e8b-892d-1e086394be9c`). Find them under **Entra ID** → **Groups** → click the group → copy the **Object ID**.

Then reconfigure:

```bash
docker exec -it gitlab gitlab-ctl reconfigure
```

### 10.11 Troubleshooting SSO

#### "Redirect URI mismatch" error

The redirect URI in Entra ID must **exactly** match the one in `gitlab.rb`:

```
https://gitlab.yourdomain.com/users/auth/openid_connect/callback
```

Check for trailing slashes, http vs https, and FQDN mismatches.

#### "SSL certificate problem" during SSO

If GitLab cannot reach `login.microsoftonline.com` due to SSL inspection or proxy:

```bash
# Add your corporate proxy CA to GitLab's trusted certs
cp your_proxy_ca.crt /var/gitlab/config/trusted-certs/
docker exec -it gitlab gitlab-ctl reconfigure
```

#### SSO button does not appear on login page

```bash
# Verify OmniAuth is enabled
docker exec -it gitlab grep -i omniauth /etc/gitlab/gitlab.rb

# Check GitLab logs for OIDC errors
docker exec -it gitlab gitlab-ctl tail puma
```

#### User gets "Forbidden" after SSO login

Check if `omniauth_block_auto_created_users` is set to `true`. If so, an admin must manually approve the user in **Admin Area** → **Users** → **Pending approval**.

#### Check OIDC discovery endpoint

Verify GitLab can reach the Entra ID OIDC discovery URL:

```bash
docker exec -it gitlab curl -s \
  "https://login.microsoftonline.com/YOUR-TENANT-ID/v2.0/.well-known/openid-configuration" | head -5
```

If this fails, check outbound internet/firewall rules from the GitLab server.

---

## 11. Client-Side CA Trust Configuration

> **When is this section needed?**
>
> | Certificate Type | Client-Side Setup Required? |
> |---|---|
> | Self-Signed (Option A) | Yes — install the `.crt` file on every client |
> | Internal/Private CA (Option B) | Yes — install the CA root cert on every client |
> | Public CA — DigiCert, Let's Encrypt, etc. (Option B) | No — skip this section entirely |

Every developer machine that connects to GitLab must trust the certificate. For **self-signed**, distribute the `gitlab.yourdomain.com.crt` file. For **internal CA**, distribute the `your_ca_root.crt` file.

### 11.1 Linux (RHEL/OEL/CentOS/Fedora)

```bash
# Copy CA root to system trust store
sudo cp your_ca_root.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust

# Configure Git
git config --global http.sslCAInfo /etc/pki/ca-trust/source/anchors/your_ca_root.crt
```

### 11.2 Linux (Ubuntu/Debian)

```bash
sudo cp your_ca_root.crt /usr/local/share/ca-certificates/your_ca_root.crt
sudo update-ca-certificates

git config --global http.sslCAInfo /usr/local/share/ca-certificates/your_ca_root.crt
```

### 11.3 macOS

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain your_ca_root.crt

git config --global http.sslCAInfo /path/to/your_ca_root.crt
```

### 11.4 Windows

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

### 11.5 SSH Configuration for Git (All Platforms)

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

## 12. Dual Push: GitLab On-Prem + GitHub

Push to both GitLab and GitHub simultaneously so both repos are always in sync.

### 12.1 Configure Multi-Push on an Existing Repo

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

### 12.2 Usage

```bash
# Single push goes to BOTH remotes
git push origin main
```

### 12.3 Alternative: Separate Remotes (More Control)

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

## 13. Importing Projects from GitHub to GitLab

### 13.1 Method A: GitLab Built-in GitHub Importer (Full Import)

This imports repos, issues, PRs (as merge requests), labels, milestones, and wiki.

1. Log into GitLab
2. Click **New Project** → **Import Project** → **GitHub**
3. Enter a GitHub **Personal Access Token** (generate at https://github.com/settings/tokens with `repo` scope)
4. Select repositories to import
5. Click **Import**

### 13.2 Method B: Git Mirror (Code Only)

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

### 13.3 Method B Batch Script (Multiple Repos)

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

## 14. Backup Strategy

### 14.1 What Gets Backed Up

GitLab has **two separate backup scopes**:

| Scope | Includes | Command |
|-------|----------|---------|
| **Application backup** | Repositories, database, uploads, CI/CD artifacts, LFS objects | `gitlab-backup create` |
| **Configuration backup** | `gitlab.rb`, secrets, SSL certificates | Manual `tar` (see below) |

> **IMPORTANT:** The application backup does **NOT** include `gitlab.rb` or the secrets file. You must back up configuration separately.

### 14.2 Default Backup Behavior

By default, GitLab backups are **plain, unencrypted `.tar` files**. Anyone with access to the backup file can extract and read all contents including source code, database, and user data.

For many on-prem environments behind a secured network, this is acceptable. If your backups leave the server or are stored on shared storage, consider enabling encryption (see [Section 14.5](#145-optional-enable-backup-encryption)).

### 14.3 Manual Backup

```bash
# Application backup (output goes to /var/gitlab/data/backups/)
docker exec -t gitlab gitlab-backup create

# Configuration backup (separate — always do this alongside application backup)
tar czf /var/gitlab/backups/gitlab_config_$(date +%Y%m%d_%H%M%S).tar.gz \
  -C /var/gitlab config/
```

### 14.4 Automated Daily Backup Script

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

### 14.5 OPTIONAL: Enable Backup Encryption

> **This section is optional.** Enable encryption if backups are stored on shared/remote storage, transferred off-server, or if your security policy requires it.

#### 14.5.1 Enable Application Backup Encryption

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

#### 14.5.2 Enable Configuration Backup Encryption

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

#### 14.5.3 Decrypting an Encrypted Config Backup

```bash
openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass pass:'YOUR-STRONG-CONFIG-BACKUP-PASSWORD' \
  -in /var/gitlab/backups/gitlab_config_20260221_020000.tar.gz.enc \
  -out gitlab_config_decrypted.tar.gz

tar xzf gitlab_config_decrypted.tar.gz
```

#### 14.5.4 Encryption Key Management — CRITICAL

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

### 14.6 Restoring from Backup

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

## 15. Updating GitLab

### 15.1 Pre-Update Checklist

```bash
# 1. Check current version
docker exec -it gitlab gitlab-rake gitlab:env:info

# 2. Create a backup before updating
docker exec -t gitlab gitlab-backup create

# 3. Backup the configuration
tar czf /var/gitlab/backups/pre_update_config_$(date +%Y%m%d).tar.gz \
  -C /var/gitlab config/
```

### 15.2 Perform the Update

```bash
cd /var/gitlab

# Pull latest image
docker compose pull

# Recreate the container with the new image (DATA IS SAFE in /var/gitlab)
docker compose up -d
```

> Docker Compose will automatically stop the old container and start a new one with the updated image. Your data is safe because it is stored in host-mounted volumes.

### 15.3 Post-Update Verification

```bash
# Watch startup logs
docker compose -f /var/gitlab/docker-compose.yml logs -f

# Once started, verify version
docker exec -it gitlab gitlab-rake gitlab:env:info

# Run health check
docker exec -it gitlab gitlab-rake gitlab:check SANITIZE=true
```

---

## 16. Maintenance & Troubleshooting

### 16.1 Container Management

```bash
# Check container status
docker compose -f /var/gitlab/docker-compose.yml ps

# Stop GitLab
docker compose -f /var/gitlab/docker-compose.yml stop

# Start GitLab
docker compose -f /var/gitlab/docker-compose.yml start

# Restart GitLab
docker compose -f /var/gitlab/docker-compose.yml restart

# View logs (last 100 lines, follow)
docker compose -f /var/gitlab/docker-compose.yml logs -f --tail 100

# Check resource usage
docker stats gitlab --no-stream
```

### 16.2 GitLab Internal Services

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

### 16.3 Health Checks

```bash
# Full system check
docker exec -it gitlab gitlab-rake gitlab:check SANITIZE=true

# Check HTTPS certificate from outside
openssl s_client -connect gitlab.yourdomain.com:443 -showcerts </dev/null 2>/dev/null | \
  openssl x509 -noout -dates

# Check GitLab version and environment
docker exec -it gitlab gitlab-rake gitlab:env:info
```

### 16.4 Common Issues

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

## 17. Quick Reference Card

### Essential Commands

| Task                  | Command                                                              |
|-----------------------|----------------------------------------------------------------------|
| Start GitLab          | `docker compose -f /var/gitlab/docker-compose.yml start`             |
| Stop GitLab           | `docker compose -f /var/gitlab/docker-compose.yml stop`              |
| Restart GitLab        | `docker compose -f /var/gitlab/docker-compose.yml restart`           |
| View logs             | `docker compose -f /var/gitlab/docker-compose.yml logs -f --tail 100`|
| Update GitLab         | `cd /var/gitlab && docker compose pull && docker compose up -d`      |
| Reconfigure           | `docker exec -it gitlab gitlab-ctl reconfigure`                      |
| Service status        | `docker exec -it gitlab gitlab-ctl status`                           |
| Manual backup         | `docker exec -t gitlab gitlab-backup create`                         |
| Check version         | `docker exec -it gitlab gitlab-rake gitlab:env:info`                 |
| Health check          | `docker exec -it gitlab gitlab-rake gitlab:check SANITIZE=true`      |
| Reset root password   | `docker exec -it gitlab gitlab-rake "gitlab:password:reset[root]"`   |
| Restart NGINX         | `docker exec -it gitlab gitlab-ctl restart nginx`                    |
| Test email delivery   | `docker exec -it gitlab gitlab-rails console` then `Notify.test_email('user@example.com','Test','Body').deliver_now` |

### Key Paths on Host

| Path                           | Contents                        |
|--------------------------------|---------------------------------|
| `/var/gitlab/docker-compose.yml`| Docker Compose deployment file  |
| `/var/gitlab/config/`          | gitlab.rb, secrets, SSL certs   |
| `/var/gitlab/config/ssl/`      | TLS certificates and keys       |
| `/var/gitlab/data/`            | Repositories, DB, uploads       |
| `/var/gitlab/logs/`            | All GitLab logs                 |
| `/var/gitlab/backups/`         | Backup archives and logs        |
| `/var/gitlab/backup-gitlab.sh` | Automated backup script         |

### Key URLs

| URL                                        | Purpose            |
|--------------------------------------------|--------------------|
| `https://gitlab.yourdomain.com`            | Web UI             |
| `https://gitlab.yourdomain.com/admin`      | Admin Area         |
| `https://gitlab.yourdomain.com/-/health`   | Health check endpoint |
| `https://gitlab.yourdomain.com/-/readiness`| Readiness probe       |
| `https://gitlab.yourdomain.com/-/liveness` | Liveness probe        |

### Ports

| Port | Service                 |
|------|-------------------------|
| 443  | HTTPS (Web UI + API)    |
| 80   | HTTP (redirects to 443) |
| 2222 | Git over SSH            |

---

## 18. SMTP / Email Notification Configuration

GitLab sends email notifications for merge requests, CI/CD pipeline results, mentions, password resets, and more. SMTP must be explicitly configured — GitLab does not send emails out of the box.

### 18.1 Sender Identity Configuration

Edit `gitlab.rb`:

```bash
vi /var/gitlab/config/gitlab.rb
```

Add the sender identity block:

```ruby
##############################################
# EMAIL SENDER IDENTITY
##############################################
gitlab_rails['gitlab_email_enabled'] = true
gitlab_rails['gitlab_email_from']    = 'gitlab@yourdomain.com'
gitlab_rails['gitlab_email_display_name'] = 'GitLab'
gitlab_rails['gitlab_email_reply_to'] = 'noreply@yourdomain.com'
```

> **Replace** `yourdomain.com` with your actual domain.

### 18.2 SMTP Configuration — Office 365 / Exchange Online

```ruby
##############################################
# SMTP — OFFICE 365 / EXCHANGE ONLINE
##############################################
gitlab_rails['smtp_enable']               = true
gitlab_rails['smtp_address']              = "smtp.office365.com"
gitlab_rails['smtp_port']                 = 587
gitlab_rails['smtp_user_name']            = "gitlab@yourdomain.com"
gitlab_rails['smtp_password']             = "YOUR-SMTP-PASSWORD"
gitlab_rails['smtp_domain']               = "yourdomain.com"
gitlab_rails['smtp_authentication']       = "login"
gitlab_rails['smtp_enable_starttls_auto'] = true
gitlab_rails['smtp_tls']                  = false
gitlab_rails['smtp_openssl_verify_mode']  = 'peer'
```

**Replace:**

| Placeholder | Replace With |
|---|---|
| `gitlab@yourdomain.com` | Your Office 365 mailbox/service account |
| `YOUR-SMTP-PASSWORD` | The mailbox password or app password |
| `yourdomain.com` | Your email domain |

> **Note:** If your organization uses MFA (Multi-Factor Authentication), you must generate an **App Password** in the Microsoft 365 portal: **My Account** -> **Security info** -> **App passwords**. Regular passwords will not work with MFA enabled.

### 18.3 SMTP Configuration — Gmail

```ruby
##############################################
# SMTP — GMAIL
##############################################
gitlab_rails['smtp_enable']               = true
gitlab_rails['smtp_address']              = "smtp.gmail.com"
gitlab_rails['smtp_port']                 = 587
gitlab_rails['smtp_user_name']            = "your-email@gmail.com"
gitlab_rails['smtp_password']             = "YOUR-APP-PASSWORD"
gitlab_rails['smtp_domain']               = "gmail.com"
gitlab_rails['smtp_authentication']       = "login"
gitlab_rails['smtp_enable_starttls_auto'] = true
gitlab_rails['smtp_tls']                  = false
gitlab_rails['smtp_openssl_verify_mode']  = 'peer'
```

> **WARNING:** Gmail requires an **App Password** — your regular Gmail password will not work. To generate one: enable 2-Step Verification on your Google account, then go to **myaccount.google.com** -> **Security** -> **App passwords** -> generate a password for "Mail".

### 18.4 SMTP Configuration — Generic SMTP Server

```ruby
##############################################
# SMTP — GENERIC SMTP SERVER
##############################################
gitlab_rails['smtp_enable']               = true
gitlab_rails['smtp_address']              = "mail.yourdomain.com"
gitlab_rails['smtp_port']                 = 587
gitlab_rails['smtp_user_name']            = "gitlab@yourdomain.com"
gitlab_rails['smtp_password']             = "YOUR-SMTP-PASSWORD"
gitlab_rails['smtp_domain']               = "yourdomain.com"
gitlab_rails['smtp_authentication']       = "login"
gitlab_rails['smtp_enable_starttls_auto'] = true
gitlab_rails['smtp_tls']                  = false
gitlab_rails['smtp_openssl_verify_mode']  = 'peer'
```

**Full SMTP parameter reference:**

| Parameter | Description | Common Values |
|---|---|---|
| `smtp_address` | SMTP server hostname | `smtp.office365.com`, `smtp.gmail.com` |
| `smtp_port` | SMTP port | `587` (STARTTLS), `465` (implicit TLS), `25` (no encryption) |
| `smtp_user_name` | Authentication username | Usually the full email address |
| `smtp_password` | Authentication password | App password if MFA is enabled |
| `smtp_domain` | HELO domain | Your email domain |
| `smtp_authentication` | Auth method | `login`, `plain`, `cram_md5` |
| `smtp_enable_starttls_auto` | Upgrade to TLS | `true` for port 587 |
| `smtp_tls` | Force implicit TLS | `true` for port 465, `false` for 587 |
| `smtp_openssl_verify_mode` | SSL verification | `peer` (verify), `none` (skip — not recommended) |

### 18.5 Apply Configuration

```bash
docker exec -it gitlab gitlab-ctl reconfigure
```

Wait for: `gitlab Reconfigured!`

> **IMPORTANT:** The SMTP password is stored in plaintext in `gitlab.rb`. Restrict file permissions:
> ```bash
> chmod 600 /var/gitlab/config/gitlab.rb
> ```

### 18.6 Test Email Delivery

**Method 1 — Rails Console:**

```bash
docker exec -it gitlab gitlab-rails console
```

In the Rails console, run:

```ruby
Notify.test_email('recipient@example.com', 'GitLab Test Email', 'This is a test email from GitLab.').deliver_now
```

Expected output: a delivery confirmation with no errors. Check the recipient's inbox (and spam folder).

Type `exit` to leave the console.

**Method 2 — Trigger via UI:**

1. Log into GitLab as admin
2. Go to **Admin Area** -> **Settings** -> **General** -> **Sign-up restrictions**
3. Ensure "Send confirmation email on sign-up" is enabled
4. Create a test user with a valid email — they should receive a confirmation email

### 18.7 Troubleshooting Email Issues

#### Emails not sending

```bash
# Check Sidekiq logs (Sidekiq processes email jobs)
docker exec -it gitlab gitlab-ctl tail sidekiq | grep -i mail

# Check production logs for email errors
docker exec -it gitlab gitlab-ctl tail puma | grep -i smtp
```

#### SMTP authentication failure

- Verify credentials are correct in `gitlab.rb`
- If using MFA, ensure you are using an **App Password**, not your regular password
- Test SMTP connectivity from inside the container:

```bash
docker exec -it gitlab openssl s_client -starttls smtp \
  -connect smtp.office365.com:587
```

#### SSL/TLS errors

| Port | Setting | Use Case |
|---|---|---|
| 587 | `smtp_enable_starttls_auto = true`, `smtp_tls = false` | STARTTLS (most common) |
| 465 | `smtp_enable_starttls_auto = false`, `smtp_tls = true` | Implicit TLS |
| 25 | Both `false` | No encryption (not recommended) |

> **CRITICAL:** Do not set both `smtp_tls` and `smtp_enable_starttls_auto` to `true` — they are mutually exclusive.

#### Emails going to spam

- Configure **SPF** DNS record: `v=spf1 include:spf.protection.outlook.com ~all`
- Configure **DKIM** if your mail server supports it
- Configure **DMARC** DNS record: `v=DMARC1; p=quarantine; rua=mailto:dmarc@yourdomain.com`
- Ensure `gitlab_email_from` domain matches the SMTP user domain

---

## 19. Essential Git Commands Reference

A quick reference for developers working with this GitLab instance, covering the most common Git operations.

### 19.1 Initial Git Configuration

Run these once on each developer machine:

```bash
git config --global user.name "Your Full Name"
git config --global user.email "your.email@yourdomain.com"
git config --global init.defaultBranch main
```

### 19.2 Clone a Repository

| Method | URL Format | Requires |
|---|---|---|
| **SSH** | `ssh://git@gitlab.yourdomain.com:2222/group/project.git` | SSH key configured |
| **HTTPS** | `https://gitlab.yourdomain.com/group/project.git` | Password or personal access token |

```bash
# SSH clone (uses port 2222)
git clone ssh://git@gitlab.yourdomain.com:2222/group/project.git

# HTTPS clone
git clone https://gitlab.yourdomain.com/group/project.git
```

> **Note:** For SSH, configure `~/.ssh/config` to use the short clone URL format. See [Section 11.5](#115-ssh-configuration-for-git-all-platforms).

### 19.3 Everyday Commands

| Command | Description |
|---|---|
| `git status` | Show changed/staged/untracked files |
| `git add .` | Stage all changes |
| `git add <file>` | Stage a specific file |
| `git commit -m "message"` | Commit staged changes with a message |
| `git push origin main` | Push commits to remote |
| `git pull origin main` | Pull and merge latest changes |
| `git fetch --all` | Fetch from all remotes without merging |

### 19.4 Branching & Merging

| Command | Description |
|---|---|
| `git branch` | List local branches |
| `git branch -a` | List all branches (local + remote) |
| `git checkout -b feature/my-feature` | Create and switch to a new branch |
| `git switch feature/my-feature` | Switch to an existing branch (Git 2.23+) |
| `git merge feature/my-feature` | Merge a branch into the current branch |
| `git branch -d feature/my-feature` | Delete a local branch (merged only) |
| `git push origin --delete feature/my-feature` | Delete a remote branch |

### 19.5 Stash, Log & Diff

| Command | Description |
|---|---|
| `git stash` | Temporarily save uncommitted changes |
| `git stash pop` | Restore the most recent stash |
| `git stash list` | List all stashes |
| `git log --oneline -20` | Show last 20 commits (compact view) |
| `git log --graph --oneline --all` | Visual branch graph |
| `git diff` | Show unstaged changes |
| `git diff --staged` | Show staged changes |
| `git diff main..feature/branch` | Compare two branches |

### 19.6 Undoing Changes

| Command | Description |
|---|---|
| `git restore <file>` | Discard unstaged changes to a file |
| `git restore --staged <file>` | Unstage a file (keep changes) |
| `git reset --soft HEAD~1` | Undo last commit, keep changes staged |
| `git reset --hard HEAD~1` | Undo last commit and discard all changes |
| `git revert <commit-hash>` | Create a new commit that reverses a previous one |

> **WARNING:** `git reset --hard` permanently discards changes and cannot be undone. Use `git revert` on shared branches to preserve history for other team members.

### 19.7 Working with Merge Requests from CLI

GitLab supports push options that let you create merge requests directly from `git push`:

```bash
# Push and create a merge request
git push -o merge_request.create \
         -o merge_request.target=main \
         -o merge_request.title="Add new feature" \
         origin feature/my-feature
```

**Available push options:**

| Option | Description |
|---|---|
| `-o merge_request.create` | Create a new merge request |
| `-o merge_request.target=main` | Set the target branch |
| `-o merge_request.title="Title"` | Set the MR title |
| `-o merge_request.description="Desc"` | Set the MR description |
| `-o merge_request.remove_source_branch` | Auto-delete branch after merge |
| `-o merge_request.assign="username"` | Assign the MR to a user |
| `-o merge_request.merge_when_pipeline_succeeds` | Auto-merge when CI passes |

### 19.8 .gitignore Best Practices

Create a `.gitignore` file in your project root to exclude files that should not be committed:

```
# IDE files
.idea/
.vscode/
*.swp

# OS files
.DS_Store
Thumbs.db

# Environment and secrets
.env
.env.local
*.pem
*.key
credentials.json

# Build artifacts
node_modules/
dist/
build/
__pycache__/
*.pyc

# Logs
*.log

# Terraform
.terraform/
*.tfstate
*.tfstate.backup
```

> **Tip:** Use [https://gitignore.io](https://gitignore.io) to generate `.gitignore` files tailored to your tech stack.

---

## 20. Monitoring with Site24x7

Site24x7 is a cloud-based monitoring platform. This section covers what to monitor for a self-hosted GitLab instance and how to configure each monitor.

### 20.1 GitLab Built-in Health Endpoints

GitLab provides built-in endpoints for monitoring:

| Endpoint | URL | Purpose | Expected Response |
|---|---|---|---|
| **Health** | `/-/health` | Basic health check | `GitLab OK` (text) |
| **Readiness** | `/-/readiness` | All sub-services ready | JSON with component status |
| **Liveness** | `/-/liveness` | Process is alive (not deadlocked) | JSON `{"status":"ok"}` |

Test from the server:

```bash
# Basic health
curl -k https://localhost/-/health

# Readiness (checks PostgreSQL, Redis, Gitaly, Sidekiq)
curl -k https://localhost/-/readiness

# Liveness
curl -k https://localhost/-/liveness
```

> **Note:** The readiness endpoint checks all sub-services (PostgreSQL, Redis, Gitaly, Sidekiq). If any sub-service is down, readiness returns a non-200 response — making it the best endpoint for comprehensive monitoring.

> **Important:** By default, health endpoints are restricted to **localhost only**. To allow external monitoring (e.g., Site24x7, load balancers), you **must** configure `monitoring_whitelist` in `gitlab.rb` — see [Section 7.2](#72-edit-gitlabrb). Without this, external requests to `/-/health` will return "not found".

### 20.2 Site24x7 — HTTPS URL Monitor

Monitor GitLab's availability via HTTPS:

1. Log into **Site24x7** dashboard
2. Navigate to **Web** -> **Website Monitor** -> **Add Monitor**
3. Configure:

| Setting | Value |
|---|---|
| Display Name | `GitLab - HTTPS Health` |
| URL | `https://gitlab.yourdomain.com/-/health` |
| Check Frequency | Every 5 minutes |
| HTTP Method | GET |
| Expected Status Code | 200 |
| Expected Content String | `GitLab OK` |

4. Set alert thresholds:

| Condition | Severity |
|---|---|
| Response time > 5 seconds | Warning |
| Response time > 10 seconds | Critical |
| HTTP status != 200 | Critical |
| Content string not found | Critical |

> **Self-signed certificate note:** If using a self-signed certificate, enable "Skip SSL validation" in the monitor settings, or upload your CA certificate to Site24x7 under **Admin** -> **Certificate Store**.

### 20.3 Site24x7 — Port Monitoring

Monitor critical service ports:

| Port | Service | Protocol | Alert If |
|---|---|---|---|
| 443 | HTTPS (Web UI + API) | TCP | Connection refused or timeout |
| 80 | HTTP (redirect to HTTPS) | TCP | Connection refused |
| 2222 | Git over SSH | TCP | Connection refused or timeout |

Configure in Site24x7: **Network** -> **Port Monitor** -> **Add Monitor** for each port.

### 20.4 Site24x7 — SSL Certificate Expiry

Monitor your SSL certificate expiration:

1. Site24x7: **Web** -> **SSL/TLS Certificate Monitor** -> **Add Monitor**
2. Configure:

| Setting | Value |
|---|---|
| Host | `gitlab.yourdomain.com` |
| Port | `443` |
| Warning threshold | 30 days before expiry |
| Critical threshold | 14 days before expiry |

> See [Section 5A.4](#5a4-certificate-renewal) for self-signed certificate renewal steps.

### 20.5 Site24x7 — Server Resource Monitoring

Install the Site24x7 Linux agent on the GitLab host to monitor system resources:

```bash
# Download and install the Site24x7 Linux agent
# Get the install command from: Site24x7 -> Agents -> Add Server Monitor -> Linux
# It will look like:
bash -c "$(curl -sL https://staticdownloads.site24x7.com/server/Site24x7InstallScript.sh)" \
  readlink -i -key=YOUR-DEVICE-KEY
```

**Recommended alert thresholds:**

| Metric | Warning | Critical | Why |
|---|---|---|---|
| Disk usage (`/var/gitlab`) | > 80% | > 90% | Repos, DB, and backups grow over time |
| CPU utilization | > 80% for 5 min | > 95% for 5 min | GitLab is CPU-intensive during CI/CD |
| Memory utilization | > 85% | > 95% | GitLab requires minimum 4 GB RAM |
| Swap usage | > 50% | > 80% | Heavy swap causes severe performance issues |

### 20.6 Docker Container Health Monitoring

Add a healthcheck to your `docker-compose.yml`:

```bash
vi /var/gitlab/docker-compose.yml
```

Add the `healthcheck` block under the `gitlab` service:

```yaml
    healthcheck:
      test: ["CMD", "curl", "-f", "-k", "https://localhost/-/health"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 300s
```

Apply the change:

```bash
cd /var/gitlab && docker compose up -d
```

Check container health status:

```bash
# Check health status
docker inspect --format='{{.State.Health.Status}}' gitlab

# Expected output: healthy

# View detailed health check history
docker inspect --format='{{json .State.Health}}' gitlab | python3 -m json.tool
```

### 20.7 Backup Job Monitoring

Monitor that daily backups complete successfully by adding a Site24x7 heartbeat to the backup script.

1. Create a **Heartbeat Monitor** in Site24x7: **Web** -> **Cron/Heartbeat Monitor** -> **Add Monitor**
2. Set check interval to **24 hours**
3. Copy the heartbeat URL provided by Site24x7

Add to the end of `/var/gitlab/backup-gitlab.sh` (before the final log line):

```bash
# --- Heartbeat: Notify Site24x7 backup completed ---
curl -s "https://api.site24x7.com/heartbeat/YOUR-HEARTBEAT-ID" > /dev/null 2>&1
```

If the heartbeat is not received within 24 hours, Site24x7 will alert that the backup job has failed.

### 20.8 Prometheus Metrics (Built-in)

GitLab CE bundles Prometheus for internal metrics collection. It runs inside the container on port 9090.

Verify Prometheus is enabled:

```bash
docker exec -it gitlab grep prometheus /etc/gitlab/gitlab.rb
```

To enable (if disabled), add to `gitlab.rb`:

```ruby
##############################################
# PROMETHEUS MONITORING
##############################################
prometheus_monitoring['enable'] = true
```

Then reconfigure:

```bash
docker exec -it gitlab gitlab-ctl reconfigure
```

**Useful Prometheus queries (accessible at `http://localhost:9090` inside the container):**

| Query | What It Shows |
|---|---|
| `gitlab_sql_duration_seconds` | Database query performance |
| `ruby_gc_duration_seconds` | Ruby garbage collection time |
| `sidekiq_jobs_processed_total` | Total background jobs processed |
| `gitlab_transaction_duration_seconds` | Web request latency |
| `process_resident_memory_bytes` | Memory usage per process |

> **Note:** Prometheus data can be scraped by an external Prometheus or Grafana instance for centralized dashboarding.

### 20.9 Alerting Recommendations Summary

| Alert | Monitor Type | Severity | Notification |
|---|---|---|---|
| HTTPS endpoint down | URL monitor | Critical | SMS + Email |
| SSL certificate expiry < 14 days | SSL monitor | Critical | Email |
| SSL certificate expiry < 30 days | SSL monitor | Warning | Email |
| SSH port 2222 unreachable | Port monitor | Warning | Email |
| Disk usage > 90% | Server monitor | Critical | SMS + Email |
| CPU > 95% sustained (5 min) | Server monitor | Critical | Email |
| Memory > 95% | Server monitor | Critical | Email |
| Backup job not completed | Heartbeat monitor | Critical | SMS + Email |
| Health endpoint not returning OK | URL monitor | Critical | SMS + Email |
| Container unhealthy | Docker healthcheck | Critical | Email |

---

## 21. User & Group Management Best Practices

GitLab uses a hierarchy of **Groups**, **Subgroups**, and **Projects**. Settings, permissions, and members defined at higher levels are automatically inherited by lower levels. This section provides a recommended structure based on departmental organization.

> **Key Concept — Project vs Repository:**
> In GitLab, **1 Project = 1 Git Repository**. A project is the container that holds a single Git repo plus its issue tracker, CI/CD pipelines, merge requests, wiki, and container registry. Because each project can only hold one repository, we use **sub-groups** to organize multiple projects that belong to the same team. Even if a team has only one project today (e.g., `bms`), the sub-group allows adding more projects in the future (e.g., `bms-frontend`, `bms-backend`, `bms-docs`) without restructuring permissions or hierarchy.

### 21.1 Recommended Hierarchy

```
GitLab Instance
│
├── business-technology/          (Top-Level Group — Department)
│   ├── bms/                      (Sub-group — BMS Team only)
│   │   └── bms                   (Project = 1 Git repo)
│   ├── itsm/                     (Sub-group — ITSM Team only)
│   │   └── itsm                  (Project = 1 Git repo)
│   ├── erp/                      (Sub-group — ERP Team only)
│   │   └── erp                   (Project = 1 Git repo)
│   └── .../                      (additional sub-groups per team)
│
├── infrastructure/               (Top-Level Group — Department)
│   ├── cloud/                    (Sub-group — Cloud Team)
│   │   └── cloud                 (Project)
│   ├── dr/                       (Sub-group — DR Team)
│   │   └── dr                    (Project)
│   ├── olam/                     (Sub-group)
│   │   └── olam                  (Project)
│   ├── satellite/                (Sub-group)
│   │   └── satellite             (Project)
│   ├── access-hub/               (Sub-group)
│   │   └── access-hub            (Project)
│   └── .../                      (additional sub-groups per team)
│
└── (additional departments as needed)
```

> **Why sub-groups?** Members added at a group level inherit access to **all** projects inside that group. If BMS and ITSM projects sit directly under `business-technology`, any member added to the group sees both projects — breaking team isolation. Sub-groups solve this:
> - **Department Head** added at `business-technology` (top-level group) → sees **all** teams' projects
> - **BMS developer** added at `business-technology/bms` (sub-group) → sees **only** BMS projects
>
> Even if each team has just one project today, the sub-group structure provides **future scalability** — new repos can be added under the same sub-group without restructuring.

### 21.2 Naming Conventions

| Level | Convention | Example | Avoid |
|---|---|---|---|
| Top-level group | Lowercase, hyphenated | `business-technology` | `Business Technology`, `BT` |
| Subgroup | Lowercase, hyphenated | `cloud-team` | `Cloud_Team`, `CloudTeam` |
| Project | Lowercase, hyphenated | `access-hub` | `AccessHub`, `access hub` |

> **Why?** GitLab generates URLs from names. Clean naming produces clean URLs:
> `https://gitlab.infra.gov.sa/business-technology/bms/bms` (group / sub-group / project)

### 21.3 Permission Roles

| Role | Can Do | Cannot Do |
|---|---|---|
| **Owner** | Full control: manage settings, members, delete group/project, manage billing | N/A — highest role |
| **Maintainer** | Merge to protected branches, manage CI/CD, push tags, manage project members | Delete group, change group settings |
| **Developer** | Push to non-protected branches, create merge requests, run CI/CD pipelines | Merge to protected branches, manage members |
| **Reporter** | View code, create and comment on issues, generate reports | Push code, merge, manage CI/CD |
| **Guest** | View issues and wiki (no code access in private repos) | Push, view code in private projects |

### 21.4 Suggested Role Assignments

| Person / Role | GitLab Role | Assigned At | Sees |
|---|---|---|---|
| IT Admin (you) | **Admin** (instance-wide) | Instance | Everything |
| Department Head | **Owner** | Top-level group (e.g., `business-technology`) | All teams in the department |
| Team Lead / Senior Engineer | **Maintainer** | Sub-group (e.g., `business-technology/bms`) | Only their team's projects |
| Developer / Engineer | **Developer** | Sub-group (e.g., `business-technology/bms`) | Only their team's projects |
| Project Manager / QA | **Reporter** | Sub-group | Only their team's projects |
| External Auditor / Stakeholder | **Guest** | Specific project only | Only that one project |

> **Best Practice:** Assign roles at the **sub-group level** for team isolation — members only see their own team's projects. Only assign at the top-level group when someone needs department-wide visibility (e.g., Department Head). Avoid project-level assignments except for cross-team exceptions.

### 21.5 Creating the Structure via Web UI

#### Step 1 — Create Top-Level Groups (Departments)

1. Log into GitLab as admin
2. Click **Groups** (left sidebar) -> **New Group** -> **Create group**
3. Configure:
   - **Group name:** `Business Technology`
   - **Group URL (slug):** `business-technology` (auto-generated)
   - **Visibility level:** **Private**
   - **Description:** `Business Technology department projects`
4. Click **Create group**
5. Repeat for **Infrastructure** group

#### Step 2 — Create Sub-groups (Teams)

1. Navigate to the top-level group (e.g., click **Business Technology**)
2. Click **New subgroup**
3. Configure:
   - **Subgroup name:** `BMS`
   - **Subgroup URL (slug):** `bms` (auto-generated)
   - **Visibility level:** **Private**
   - **Description:** `BMS team projects`
4. Click **Create subgroup**
5. Repeat for each team: **ITSM**, **ERP** (under Business Technology), **Cloud**, **DR**, **OLAM**, **Satellite**, **Access Hub** (under Infrastructure)

#### Step 3 — Create Projects Under Sub-groups

1. Navigate to the sub-group (e.g., **Business Technology** -> **BMS**)
2. Click **New project** -> **Create blank project**
3. Configure:
   - **Project name:** `BMS`
   - **Project URL:** `business-technology/bms/bms` (auto-generated)
   - **Visibility level:** **Private**
   - **Initialize repository with a README:** Yes (recommended)
4. Click **Create project**
5. Repeat for each team's project(s)

#### Step 4 — Add Department Head to Top-Level Group

1. Navigate to the top-level group (e.g., **Business Technology**)
2. Click **Manage** -> **Members**
3. Click **Invite members**
4. Enter the Department Head's username or email
5. Select role: **Owner**
6. Click **Invite**

> **Result:** The Department Head inherits access to **all sub-groups and projects** in the department.

#### Step 5 — Add Team Members to Sub-groups

1. Navigate to the sub-group (e.g., **Business Technology** -> **BMS**)
2. Click **Manage** -> **Members**
3. Click **Invite members**
4. Enter team member's username or email
5. Select role: **Maintainer** (team lead) / **Developer** (engineer) / **Reporter** (PM/QA)
6. Optional: set an expiration date for temporary access
7. Click **Invite**

> **Result:** Team members only see projects within their sub-group. BMS developers cannot see ITSM projects and vice versa.

### 21.6 Creating the Structure via API (Automation)

For bulk setup, use the GitLab API:

```bash
# Set your GitLab URL and admin personal access token
GITLAB_URL="https://gitlab.yourdomain.com"
TOKEN="your-admin-personal-access-token"
```

**Step 1 — Create top-level groups (departments):**

```bash
# Create Business Technology group
curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
  --data "name=Business Technology&path=business-technology&visibility=private&description=Business Technology department projects" \
  "${GITLAB_URL}/api/v4/groups"

# Create Infrastructure group
curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
  --data "name=Infrastructure&path=infrastructure&visibility=private&description=Infrastructure department projects" \
  "${GITLAB_URL}/api/v4/groups"
```

**Step 2 — Create sub-groups (teams) under each department:**

```bash
# Get the group ID for Business Technology
BT_GROUP_ID=$(curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
  "${GITLAB_URL}/api/v4/groups?search=business-technology" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

# Create sub-groups under Business Technology
for TEAM in bms itsm erp; do
  curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
    --data "name=${TEAM}&path=${TEAM}&visibility=private&parent_id=${BT_GROUP_ID}&description=${TEAM} team projects" \
    "${GITLAB_URL}/api/v4/groups"
done

# Get the group ID for Infrastructure
INFRA_GROUP_ID=$(curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
  "${GITLAB_URL}/api/v4/groups?search=infrastructure" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

# Create sub-groups under Infrastructure
for TEAM in cloud dr olam satellite access-hub; do
  curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
    --data "name=${TEAM}&path=${TEAM}&visibility=private&parent_id=${INFRA_GROUP_ID}&description=${TEAM} team projects" \
    "${GITLAB_URL}/api/v4/groups"
done
```

**Step 3 — Create projects under sub-groups:**

```bash
# Get sub-group IDs and create projects
# Example: Create 'bms' project under the 'bms' sub-group
BMS_SUBGROUP_ID=$(curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
  "${GITLAB_URL}/api/v4/groups?search=bms" | \
  python3 -c "import sys,json; groups=[g for g in json.load(sys.stdin) if g['full_path']=='business-technology/bms']; print(groups[0]['id'])")

curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
  --data "name=bms&namespace_id=${BMS_SUBGROUP_ID}&visibility=private&initialize_with_readme=true" \
  "${GITLAB_URL}/api/v4/projects"

# Repeat pattern for each team — or use a loop:
for TEAM in itsm erp; do
  SUBGROUP_ID=$(curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
    "${GITLAB_URL}/api/v4/groups?search=${TEAM}" | \
    python3 -c "import sys,json; groups=[g for g in json.load(sys.stdin) if 'business-technology/${TEAM}'==g.get('full_path','')]; print(groups[0]['id'])")
  curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
    --data "name=${TEAM}&namespace_id=${SUBGROUP_ID}&visibility=private&initialize_with_readme=true" \
    "${GITLAB_URL}/api/v4/projects"
done

for TEAM in cloud dr olam satellite access-hub; do
  SUBGROUP_ID=$(curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
    "${GITLAB_URL}/api/v4/groups?search=${TEAM}" | \
    python3 -c "import sys,json; groups=[g for g in json.load(sys.stdin) if 'infrastructure/${TEAM}'==g.get('full_path','')]; print(groups[0]['id'])")
  curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
    --data "name=${TEAM}&namespace_id=${SUBGROUP_ID}&visibility=private&initialize_with_readme=true" \
    "${GITLAB_URL}/api/v4/projects"
done
```

**Step 4 — Add Department Head to top-level group (sees all teams):**

```bash
# Add Department Head as Owner to Business Technology group
USER_ID=3  # Get user ID from Admin Area -> Users, or API
curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
  --data "user_id=${USER_ID}&access_level=50" \
  "${GITLAB_URL}/api/v4/groups/${BT_GROUP_ID}/members"
```

**Step 5 — Add team members to sub-groups (team isolation):**

```bash
# Add a developer to the BMS sub-group only
DEV_USER_ID=5
curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
  --data "user_id=${DEV_USER_ID}&access_level=30" \
  "${GITLAB_URL}/api/v4/groups/${BMS_SUBGROUP_ID}/members"

# Add a team lead as Maintainer to the BMS sub-group
LEAD_USER_ID=4
curl -sk --header "PRIVATE-TOKEN: $TOKEN" \
  --data "user_id=${LEAD_USER_ID}&access_level=40" \
  "${GITLAB_URL}/api/v4/groups/${BMS_SUBGROUP_ID}/members"
```

**Access level numbers:**

| Access Level | Number | Typical Use |
|---|---|---|
| Guest | 10 | External auditors / stakeholders |
| Reporter | 20 | Project managers / QA |
| Developer | 30 | Engineers (push to non-protected branches) |
| Maintainer | 40 | Team leads (merge to protected branches) |
| Owner | 50 | Department heads (full group control) |

### 21.7 Transferring Existing Projects

If projects were created at the instance root level or under the wrong group and need to be moved into a sub-group:

1. Navigate to the project -> **Settings** -> **General** -> **Advanced**
2. Scroll to **Transfer project**
3. Select the target sub-group (e.g., `business-technology / bms`)
4. Type the project name to confirm
5. Click **Transfer project**

> **WARNING:** Transferring a project **changes its URL permanently**. All existing Git remotes, bookmarks, CI/CD configurations, and links referencing the old URL will break. Update remotes on every developer machine:
> ```bash
> git remote set-url origin ssh://git@gitlab.yourdomain.com:2222/business-technology/bms/bms.git
> ```

### 21.8 Best Practices Summary

- **One top-level group per department, one sub-group per team** — provides clean hierarchy with team isolation
- **Sub-group-level members for isolation** — add team members at the sub-group level so they only see their team's projects; add Department Heads at the top-level group for department-wide visibility
- **Never add regular users to the top-level group** — this gives them access to every team's projects, breaking isolation
- **Private by default** — keep all groups, sub-groups, and projects Private; use Internal only if cross-department collaboration is needed
- **Maintainer, not Owner** — give team leads Maintainer at the sub-group level; reserve Owner for Department Heads at the top-level group
- **1 Project = 1 Repo** — remember each project holds a single Git repository; use sub-groups to organize multiple repos for the same team
- **Review membership quarterly** — remove departed employees and audit role assignments
- **Descriptive names** — use project names that match the real application/system name, lowercase-hyphenated
- **Document the structure** — add a description to each group and sub-group explaining its purpose and ownership
- **Protect the main branch** — in each project, go to **Settings** -> **Repository** -> **Protected branches** and ensure `main` requires merge request approval
- **Require merge request approvals** — set minimum approvals in **Settings** -> **Merge requests** to enforce code review

---

*End of SOP*
