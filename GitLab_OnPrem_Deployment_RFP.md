---
title: "GitLab Premium On-Premises Deployment"
subtitle: "Request for Proposal (RFP)"
date: "March 2026"
---

\newpage

+---------------------------+----------------------------------------------+
| **Document Title**        | GitLab Premium On-Premises Deployment — RFP  |
+---------------------------+----------------------------------------------+
| **RFP Reference**         | RFP-GITLAB-2026-001                          |
+---------------------------+----------------------------------------------+
| **Version**               | 1.0                                          |
+---------------------------+----------------------------------------------+
| **Classification**        | Confidential                                 |
+---------------------------+----------------------------------------------+
| **Date**                  | March 2, 2026                                |
+---------------------------+----------------------------------------------+
| **Issuing Organization**  | [Organization Name]                          |
+---------------------------+----------------------------------------------+
| **Department**            | Information Technology                       |
+---------------------------+----------------------------------------------+
| **Contact Person**        | [Contact Name / Title]                       |
+---------------------------+----------------------------------------------+
| **Email**                 | [contact@organization.gov.sa]                |
+---------------------------+----------------------------------------------+
| **Submission Deadline**   | [Deadline Date]                              |
+---------------------------+----------------------------------------------+

\newpage

# Table of Contents

1. Executive Summary
2. Organization Overview
3. Scope of Work
4. Technical Requirements
5. Security Requirements
6. Acceptance Criteria
7. Timeline & Milestones
8. Vendor Requirements
9. Proposal Submission Requirements
10. Evaluation Criteria
11. Terms & Conditions
12. Sign-Off

\newpage

# 1. Executive Summary

## 1.1 Purpose

This Request for Proposal (RFP) invites qualified vendors to submit proposals for the deployment of a self-hosted **GitLab Premium** instance on the organization's on-premises infrastructure. The selected vendor will be responsible for full installation, configuration, integration, and knowledge transfer.

## 1.2 Project Overview

The organization currently uses GitHub (SaaS) for source code management and version control. Due to data sovereignty requirements and the need for greater control over development infrastructure, the organization has decided to migrate to a **self-hosted GitLab Premium** deployment within its private network.

The deployment must include enterprise authentication via Microsoft Entra ID, HTTPS with a public CA certificate, automated backups, monitoring integration, and a complete migration of existing repositories from GitHub.

## 1.3 Expected Outcomes

- A fully operational GitLab Premium instance accessible within the internal network via HTTPS
- Single Sign-On (SSO) authentication through Microsoft Entra ID
- All existing repositories migrated from GitHub with full commit history
- Automated backup and monitoring systems in place
- Comprehensive documentation (SOP) and knowledge transfer to the IT team

\newpage

# 2. Organization Overview

## 2.1 Current State

The organization currently relies on **GitHub SaaS** (github.com) for source code management. Development teams across multiple departments use GitHub for version control, code review, and collaboration.

## 2.2 Target State

Migrate to a **self-hosted GitLab Premium** instance deployed on-premises. GitLab will become the **primary source of truth** for all source code. GitHub will be retained as a secondary backup with manual synchronization.

## 2.3 User Base

| Category | Count |
|:---------|------:|
| Admin Users (Instance Administrators) | 10 |
| Developer / Maintainer Users | 25 |
| **Total Licensed Seats** | **35** |

\newpage

# 3. Scope of Work

The vendor shall deliver all items listed below. Each deliverable includes a priority level indicating its criticality to the project.

## 3.1 Deliverables Summary

| # | Deliverable | Priority |
|:--|:------------|:---------|
| 3.2 | Server Provisioning & Docker Setup | Critical |
| 3.3 | GitLab Premium Deployment | Critical |
| 3.4 | SSL/TLS Certificate Setup | Critical |
| 3.5 | HTTPS & SSH Configuration | Critical |
| 3.6 | Microsoft Entra ID SSO (OIDC) | Critical |
| 3.7 | SMTP Email Configuration | High |
| 3.8 | Firewall Configuration | Critical |
| 3.9 | Backup Strategy & Automation | Critical |
| 3.10 | Monitoring Integration | High |
| 3.11 | User & Group Management | High |
| 3.12 | GitHub Repository Migration | High |
| 3.13 | Source of Truth & Sync Strategy | Medium |
| 3.14 | GitLab Premium License Activation | Critical |
| 3.15 | Documentation & SOP | High |
| 3.16 | Knowledge Transfer & Training | High |

## 3.2 Server Provisioning & Docker Setup

The vendor shall provision and prepare the server environment:

- Install and configure **Oracle Enterprise Linux 9 (OEL 9)** as the host operating system
- Install **Docker Engine** and **Docker Compose**
- Prepare host-mounted volumes for GitLab data persistence:
  - `/var/gitlab/config` — Configuration files
  - `/var/gitlab/logs` — Log files
  - `/var/gitlab/data` — Application data (repositories, uploads, etc.)
  - `/var/gitlab/backups` — Backup storage
- Verify Docker service is running and enabled on boot
- Configure Docker log rotation to prevent disk exhaustion

## 3.3 GitLab Premium Deployment

Deploy GitLab Premium (Self-Managed) using Docker Compose:

- Create a `docker-compose.yml` with the official GitLab Docker image
- Configure port mappings:
  - `443:443` — HTTPS
  - `80:80` — HTTP (redirect to HTTPS)
  - `2222:22` — SSH for Git operations
- Configure `gitlab.rb` with all required settings (external URL, volumes, etc.)
- Verify all GitLab services start successfully (target: 15+ internal services)
- Verify GitLab web interface is accessible

## 3.4 SSL/TLS Certificate Setup

Configure HTTPS using a public Certificate Authority (CA) certificate:

- Install a **wildcard SSL certificate** from a public CA (e.g., DigiCert)
- Certificate format: `*.infra.domain` covering the GitLab hostname
- Build the correct certificate chain: Server Certificate → Intermediate CA → Root CA
- Place certificate files in the GitLab SSL directory
- Verify the full chain using `openssl verify` and `openssl s_client`
- Ensure no browser warnings when accessing the GitLab URL

## 3.5 HTTPS & SSH Configuration

Configure secure access to the GitLab instance:

- Enable **HTTPS** as the primary access method via NGINX (built-in)
- Redirect all HTTP traffic to HTTPS
- Configure **SSH** access on port **2222** for Git clone/push operations
- Enforce TLS 1.2 and TLS 1.3 only (disable older protocols)
- Verify both HTTPS and SSH access work correctly

## 3.6 Microsoft Entra ID SSO (OIDC)

Integrate GitLab with Microsoft Entra ID for Single Sign-On:

- Register a new application in **Microsoft Entra ID** (Azure AD)
- Configure **OpenID Connect (OIDC)** as the authentication provider
- Configure the following `gitlab.rb` settings:
  - `omniauth_allow_single_sign_on` — Enable SSO
  - `omniauth_auto_link_user` — Auto-link users by email
  - `omniauth_block_auto_created_users` — Set to `false` for auto-provisioning
- Set the correct redirect URI: `https://<gitlab-hostname>/users/auth/openid_connect/callback`
- Test end-to-end SSO login flow
- Document the SSO user flow (first-time login vs returning user)

**Premium Feature — SCIM Provisioning:**

- Configure **SCIM** (System for Cross-domain Identity Management) for automatic user provisioning and de-provisioning from Entra ID
- Configure group-level SAML SSO (Premium feature)

## 3.7 SMTP Email Configuration

Configure email notifications via SMTP:

- Configure GitLab to send emails through **Office 365 / Exchange Online**
- SMTP settings: `smtp.office365.com`, port 587, STARTTLS
- Configure sender address and display name
- Test email delivery using GitLab's built-in test email function
- Verify notification emails for merge requests, issues, and pipeline events

## 3.8 Firewall Configuration

Configure firewall rules on the host server:

- Open the following ports via `firewalld`:
  - **443/tcp** — HTTPS access
  - **80/tcp** — HTTP (redirect to HTTPS)
  - **2222/tcp** — SSH for Git operations
- Block all other inbound traffic by default
- Verify connectivity from client machines to all three ports

## 3.9 Backup Strategy & Automation

Implement a comprehensive backup solution:

- Configure **automated daily backups** using `gitlab-backup create`
- Set backup retention policy (minimum 7 days)
- Back up the following:
  - Repositories (all Git data)
  - Database (PostgreSQL)
  - Uploads and attachments
  - CI/CD artifacts (if applicable)
  - Configuration files (`gitlab.rb`, `gitlab-secrets.json`)
- Configure backup storage location (`/var/gitlab/backups`)
- Test **full restore** from backup to verify data integrity
- Document the backup and restore procedures

## 3.10 Monitoring Integration

Integrate GitLab with the organization's existing monitoring platform:

- Configure GitLab **health check endpoints**:
  - `/-/health` — Basic health
  - `/-/readiness` — Readiness probe
  - `/-/liveness` — Liveness probe
- Configure `monitoring_whitelist` to allow access from monitoring servers
- Set up **Site24x7** monitors:
  - URL monitor (HTTPS access)
  - Port monitors (443, 80, 2222)
  - SSL certificate expiry monitor
  - Health endpoint monitor
- Verify alert notifications are delivered correctly

## 3.11 User & Group Management

Create the organizational structure in GitLab:

- Create **top-level groups** for each department
- Create **sub-groups** under each department for individual teams
- Apply visibility settings:
  - Sub-groups set to **Private** by default
  - Each team can only see their own sub-group and projects
- Create projects (repositories) under the appropriate sub-groups
- Assign users to groups/sub-groups with appropriate roles:
  - **Owner** — Group administrators
  - **Maintainer** — Team leads
  - **Developer** — Team members
- Configure **protected branches** on all repositories (protect `main`)

**Premium Features:**

- Configure **push rules** (e.g., reject unsigned commits, enforce commit message format)
- Configure **merge request approval rules** (require multiple approvers)
- Set up **Code Owners** for critical repositories

## 3.12 GitHub Repository Migration

Migrate all existing repositories from GitHub to GitLab:

- Import all repositories with full **commit history**, branches, and tags
- Verify migration by comparing commit SHAs between GitHub and GitLab
- Ensure no data loss during migration
- Methods available:
  - GitLab built-in GitHub import (recommended)
  - Git bare clone + push (alternative)
- Document the migration process and results

## 3.13 Source of Truth & Sync Strategy

Establish GitLab as the primary source of truth:

- **GitLab** is the primary repository for all active development
- **GitHub** is retained as a backup/mirror
- Configure **dual-push** Git remotes so developers push to both GitLab and GitHub simultaneously
- Document the dual-push workflow for developers
- Provide instructions for transitioning from GitHub-primary to GitLab-primary

**Premium Feature — Pull Mirroring:**

- Configure built-in **pull mirroring** (Premium feature) as an alternative to manual sync scripts

## 3.14 GitLab Premium License Activation

Procure and activate the GitLab Premium license:

### License Details

| Item | Specification |
|:-----|:--------------|
| License Tier | GitLab Premium (Self-Managed) |
| Admin Users | 10 (Instance-level administrators) |
| Developer / Maintainer Users | 25 (Regular users with push/merge access) |
| **Total Licensed Seats** | **35** |

### Premium Features to Configure

The following Premium features shall be enabled and configured after license activation:

| # | Feature | Description |
|:--|:--------|:------------|
| 1 | SCIM Provisioning | Automatic user provisioning/de-provisioning from Entra ID |
| 2 | Pull Mirroring | Built-in repository mirroring from GitHub to GitLab |
| 3 | Group-Level SAML SSO | Centralized SSO at the group level |
| 4 | Push Rules | Enforce commit message format, reject unsigned commits |
| 5 | Merge Request Approvals | Require multiple approvers before merge |
| 6 | Code Owners | Assign code ownership for review requirements |
| 7 | Approval Rules | Fine-grained approval workflows per project |

### License Installation

1. Obtain the `.gitlab-license` file from GitLab sales
2. Navigate to **Admin Area → License**
3. Upload the `.gitlab-license` file
4. Verify the license is active and shows the correct seat count (35)
5. Verify Premium features are unlocked in the admin panel

## 3.15 Documentation & SOP

Deliver comprehensive documentation:

- **Standard Operating Procedure (SOP)** covering:
  - Full deployment steps (reproducible)
  - Configuration reference for all settings
  - Backup and restore procedures
  - SSO configuration and troubleshooting
  - User and group management guide
  - Monitoring setup and alert configuration
  - GitHub migration procedures
  - Common troubleshooting scenarios
- SOP must be detailed enough for the IT team to reproduce the deployment independently

## 3.16 Knowledge Transfer & Training

Conduct knowledge transfer sessions:

- **Session 1:** GitLab administration (user management, settings, backups)
- **Session 2:** GitLab operations (monitoring, troubleshooting, upgrades)
- **Session 3:** Developer workflow (Git operations, merge requests, CI/CD basics)
- Provide hands-on training with the deployed instance
- All sessions to be recorded for future reference

\newpage

# 4. Technical Requirements

The following technical specifications must be met:

| # | Requirement | Specification |
|:--|:------------|:--------------|
| 4.1 | Operating System | Oracle Enterprise Linux 9 (OEL 9) |
| 4.2 | Deployment Method | Docker Compose |
| 4.3 | GitLab Edition | GitLab Premium (Self-Managed) — 35 seats |
| 4.4 | SSL Certificate | Public CA wildcard certificate (e.g., DigiCert) |
| 4.5 | Authentication | Microsoft Entra ID via OpenID Connect (OIDC) + SCIM |
| 4.6 | Email Service | SMTP via Office 365 / Exchange Online |
| 4.7 | Monitoring Platform | Site24x7 (existing) |
| 4.8 | Current Source Control | GitHub SaaS (to be migrated) |
| 4.9 | Minimum Server Specs | 4 vCPU, 8 GB RAM, 100 GB storage |
| 4.10 | Network Exposure | Internal network only (not publicly accessible) |
| 4.11 | Outbound Internet | Required (for Docker images, package updates, SMTP) |
| 4.12 | Git SSH Port | 2222 (non-standard to avoid conflict with host SSH) |

\newpage

# 5. Security Requirements

The deployment must comply with the following security requirements:

| # | Requirement | Details |
|:--|:------------|:--------|
| 5.1 | HTTPS Enforcement | All traffic over HTTPS; HTTP redirected to HTTPS |
| 5.2 | TLS Version | TLS 1.2 and TLS 1.3 only; older versions disabled |
| 5.3 | Authentication | SSO-only via Entra ID; password login disabled (except root admin) |
| 5.4 | SELinux | Enabled and enforcing on the host OS |
| 5.5 | Branch Protection | Protected branches enabled on all repositories (`main` branch) |
| 5.6 | Default Visibility | All new projects and groups set to **Private** by default |
| 5.7 | Access Control | Role-based access via group/sub-group hierarchy |
| 5.8 | Backup Security | Backup files stored with restricted permissions (600) |
| 5.9 | Token Management | GitLab tokens stored with restricted file permissions |
| 5.10 | Network Isolation | GitLab instance not exposed to public internet |

\newpage

# 6. Acceptance Criteria

The following criteria must be met for project acceptance. Each criterion will be verified using the specified method:

| # | Acceptance Criterion | Verification Method | Status |
|:--|:---------------------|:---------------------|:-------|
| 6.1 | GitLab accessible via HTTPS with no certificate warnings | Browser access + `curl` test | |
| 6.2 | SSL certificate chain is valid and complete | `openssl verify` + `openssl s_client` | |
| 6.3 | SSO login via Microsoft Entra ID works end-to-end | Login test with Entra ID user | |
| 6.4 | SCIM user provisioning creates users automatically | Assign user in Entra ID, verify in GitLab | |
| 6.5 | Email notifications are delivered | GitLab test email function | |
| 6.6 | Health endpoints return HTTP 200 | `curl /-/health`, `/-/readiness`, `/-/liveness` | |
| 6.7 | Automated backup completes successfully | Run `gitlab-backup create` | |
| 6.8 | Backup restore produces a working instance | Full restore test | |
| 6.9 | All repositories migrated from GitHub | Commit SHA comparison | |
| 6.10 | Monitoring alerts configured and functional | Site24x7 test alert | |
| 6.11 | User/group/sub-group structure matches requirements | Web UI verification | |
| 6.12 | Protected branches configured on all repos | Settings verification | |
| 6.13 | Premium license active with correct seat count | Admin Area → License | |
| 6.14 | SOP document delivered and reviewed | Review and sign-off | |
| 6.15 | Knowledge transfer sessions completed | Attendance and recording | |

\newpage

# 7. Timeline & Milestones

The project is expected to be completed within **4 weeks** from the start date:

| Phase | Milestone | Deliverables | Duration |
|:------|:----------|:-------------|:---------|
| 1 | Infrastructure Setup | Server provisioning, Docker, volume setup | Week 1 |
| 2 | GitLab Deployment | GitLab install, SSL, HTTPS, SSH | Week 1 |
| 3 | Integrations | SSO (Entra ID), SMTP, Firewall | Week 2 |
| 4 | Data & Users | User/group setup, GitHub migration | Week 2 |
| 5 | Operations | Monitoring, backup, Premium license, testing | Week 3 |
| 6 | Handover | Documentation (SOP), knowledge transfer | Week 3–4 |

### Milestone Review

At the end of each phase, a milestone review meeting shall be conducted to verify deliverables and approve progression to the next phase.

\newpage

# 8. Vendor Requirements

The vendor must meet the following qualifications:

| # | Requirement |
|:--|:------------|
| 8.1 | Proven experience with **GitLab self-managed** deployments (Premium or Ultimate) |
| 8.2 | Experience with **Docker** and container orchestration |
| 8.3 | Experience with **Microsoft Entra ID / Azure AD** integration (OIDC/SAML) |
| 8.4 | Strong **Linux system administration** skills (RHEL/OEL family) |
| 8.5 | Experience with **SSL/TLS certificate** management and PKI |
| 8.6 | Experience with **Git** repository management and migration |
| 8.7 | Minimum **2 references** from similar projects within the last 3 years |

\newpage

# 9. Proposal Submission Requirements

Vendors must submit the following documents:

| # | Document | Description |
|:--|:---------|:------------|
| 9.1 | Technical Approach | Detailed description of the proposed implementation methodology |
| 9.2 | Cost Breakdown | Itemized cost for each deliverable, including licensing costs |
| 9.3 | Team Composition | Team members assigned to the project, with roles and CVs |
| 9.4 | Project Timeline | Detailed timeline with milestones and dependencies |
| 9.5 | References | Minimum 2 references from similar GitLab deployment projects |
| 9.6 | Risk Assessment | Identified risks and proposed mitigation strategies |

### Submission Format

- Proposals must be submitted in **PDF format**
- Maximum **30 pages** (excluding CVs and appendices)
- Submit to: **[contact@organization.gov.sa]** by **[Deadline Date]**

\newpage

# 10. Evaluation Criteria

Proposals will be evaluated based on the following criteria:

| # | Criteria | Weight | Description |
|:--|:---------|-------:|:------------|
| 10.1 | Technical Approach | 40% | Quality of proposed methodology, architecture, and tools |
| 10.2 | Experience & References | 25% | Relevant experience and quality of references |
| 10.3 | Cost | 20% | Total cost competitiveness and value for money |
| 10.4 | Timeline | 15% | Feasibility and efficiency of proposed schedule |
| | **Total** | **100%** | |

### Evaluation Process

1. **Initial Screening** — Proposals reviewed for completeness and compliance
2. **Technical Evaluation** — Scored by technical committee
3. **Cost Evaluation** — Scored by procurement committee
4. **Vendor Presentation** — Shortlisted vendors invited for presentation
5. **Final Selection** — Combined scoring and recommendation

\newpage

# 11. Terms & Conditions

## 11.1 Confidentiality

All information provided in this RFP and during the project is considered **confidential**. The vendor must not disclose any information to third parties without written consent from the organization.

## 11.2 Intellectual Property

- All documentation, scripts, and configurations produced during the project shall be the **property of the organization**
- The vendor retains no rights to the deliverables after project completion

## 11.3 Warranty Period

The vendor shall provide a **warranty period of 90 days** from the date of final acceptance. During this period, the vendor shall:

- Fix any defects or issues related to the deployment at no additional cost
- Provide remote support for troubleshooting

## 11.4 Post-Deployment Support

The vendor shall provide a **Service Level Agreement (SLA)** for post-deployment support:

| Priority | Response Time | Resolution Time |
|:---------|:-------------|:----------------|
| Critical (system down) | 2 hours | 8 hours |
| High (feature impacted) | 4 hours | 24 hours |
| Medium (non-critical) | 8 hours | 48 hours |
| Low (informational) | 24 hours | 5 business days |

## 11.5 Payment Terms

- Payment schedule tied to milestone completion and acceptance
- Final payment upon completion of all acceptance criteria and knowledge transfer

\newpage

# 12. Sign-Off

| Role | Name | Date | Signature |
|:-----|:-----|:-----|:----------|
| Project Sponsor | | | |
| IT Director | | | |
| Project Manager | | | |
| Procurement Officer | | | |

---

**End of Document**

*RFP Reference: RFP-GITLAB-2026-001 — Version 1.0*
