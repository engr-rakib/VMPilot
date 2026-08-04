# GitHub Setup & Usage Guide

This repository is managed on GitHub for **version control** and **CI (automated checks)**. This guide explains how to connect the repository, commit and push changes, and use the available CI facilities. It is written for both new and existing contributors.

---

## Table of Contents

- [Terminology](#terminology)
- [Security Rules (Read First)](#security-rules-read-first)
- [One-Time Setup](#one-time-setup)
- [Daily Workflow](#daily-workflow)
- [Commit Guidelines](#commit-guidelines)
- [CI / CD (GitHub Actions)](#ci--cd-github-actions)
- [Re-Enabling the CI Workflow](#re-enabling-the-ci-workflow)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Pre-Push Checklist](#pre-push-checklist)

---

## Terminology

| Term | Meaning |
|------|---------|
| **Git** | Local version control — records history of file changes |
| **GitHub** | Online hosting for Git repositories (backup + collaboration) |
| **Repository (repo)** | The project folder, hosted online |
| **Commit** | A saved snapshot of changes |
| **Push** | Send local commits to GitHub |
| **Pull** | Fetch the latest changes from GitHub |
| **Clone** | Create a local copy of a GitHub repository |

---

## Security Rules (Read First)

This project contains **sensitive files that must never be pushed** to GitHub. The `.gitignore` has been configured to block them automatically.

| File / Path | Pushed? | Reason |
|------|:---:|------|
| `deploy/*/vm-*.tfvars` | ✅ Yes | Contains SSH public key + VM metadata only (safe) |
| `terraform/` (`.tf` source) | ✅ Yes | Infrastructure code, no secrets |
| `docs/`, `scripts/` | ✅ Yes | Documentation and tooling |
| `terraform.tfstate*` | ❌ No | Contains vCenter credentials/IPAM state |
| `secure/` | ❌ No | Encrypted vCenter credentials |
| `.terraform/` | ❌ No | Local provider cache |
| `*.tfplan` | ❌ No | Pre-generated plans / state backups |

> **Golden rule:** Before every push, run `git status` and confirm that no `secure/` or `*.tfstate` file appears in the staged list.

---

## One-Time Setup

### Step 1: Create a GitHub Account
- Go to [github.com](https://github.com) → **Sign up** → username, email, password.
- Note the repository details used in this project:
  - Owner: `engr-rakib`
  - Repository: `terraform-lab`

### Step 2: Install Git
```bash
# Debian / Ubuntu
sudo apt update && sudo apt install git -y

# Verify
git --version
```

### Step 3: Configure Git Identity (once)
```bash
git config --global user.name "engr-rakib"
git config --global user.email "youremail@example.com"
```

### Step 4: Create the Repository (browser)
1. Go to `github.com/new`.
2. Repository name: `terraform-lab` → visibility: **Public**.
3. Click **Create repository** (leave all "initialize" checkboxes unticked — the repo must be empty).
4. Note the URL: `https://github.com/engr-rakib/terraform-lab.git`.

### Step 5: Create an Access Token (browser)
Tokens are required to authenticate `git push` over HTTPS.

1. Open [github.com/settings/tokens/new](https://github.com/settings/tokens/new).
2. **Note:** `project01-push`.
3. **Expiration:** `90 days` (recommended — finite lifetime is more secure).
4. **Scopes** — select **both** checkboxes:
   - ☑ `repo` (required for pushing code)
   - ☑ `workflow` (required to push `.github/workflows/` CI files)
5. Click **Generate token**, then copy the `ghp_...` value.
   > ⚠️ Treat this like a password. Never share it, do not commit it, and revoke it once it is no longer needed.

### Step 6: Connect the Local Repository (once)
```bash
cd /opt/terraform-lab/projects/project01

# Add the remote (replace <YOUR_TOKEN> with your token)
git remote add origin https://<YOUR_TOKEN>@github.com/engr-rakib/terraform-lab.git

# First push
git push -u origin main
```

The `-u origin main` flags set upstream tracking, so subsequent pushes are just `git push`.

---

## Daily Workflow

After any change — adding a VM, editing a script, updating docs:

```bash
cd /opt/terraform-lab/projects/project01

# 1) Review what changed
git status

# 2) Stage specific files (or use: git add . for everything)
git add filename.tf
git add scripts/deploy-vm.sh

# 3) Commit with a meaningful message
git commit -m "Add deploy config for web-04"

# 4) Push to GitHub
git push
```

Quick shortcut for all changes:
```
git add -A
git commit -m "message"
git push
```

---

## Commit Guidelines

1. **Write meaningful, concise commit messages:**
   - ❌ `update`
   - ✅ `Add deploy config for web-04`
2. **One logical change per commit.**
3. **Stage selectively** — review `git status` before adding, rather than blindly adding everything.
4. **Never stage secrets** — the `.gitignore` already covers most, but always verify with `git status`.

---

## CI / CD (GitHub Actions)

The repository includes a CI workflow (`.github/workflows/terraform-ci.yml`) that runs on every push and PR against `main`:

- **`validate` job** — `terraform fmt -check`, `terraform init -backend=false`, `terraform validate`.
- **`security` job** — `tflint`, `tfsec`, and `checkov` static scans.

> **Deployment limitation:** GitHub-hosted runners cannot reach the private vCenter (`192.0.2.10`). Therefore **CI (code quality + security checks) runs automatically, but deployment does not**. To deploy from GitHub, a **self-hosted runner** on the Terraform server would be required — that is an additional setup outside the scope of this guide.

---

## Re-Enabling the CI Workflow

The workflow file requires a token with the `workflow` scope. If it is not currently in the repository, restore and push it as follows:

```bash
git checkout origin/main -- .github/workflows/terraform-ci.yml   # restore locally
# or from an older commit:
git show <commit>:.github/workflows/terraform-ci.yml > .github/workflows/terraform-ci.yml

git add .github/workflows/terraform-ci.yml
git commit -m "Re-enable GitHub Actions CI"
git push
```

If the push is rejected with a `workflow` scope error, generate a new token that includes the `workflow` scope and update the remote URL.

---

## Troubleshooting

| Error | Likely Cause | Solution |
|---|---|---|
| `Authentication failed` | Token expired or incorrect | Generate a new token, then `git remote set-url origin https://<TOKEN>@github.com/...` |
| `Missing required scope 'read:org'` | Attempted `gh` login flow | Push with a `git`-level token instead of `gh` |
| `Refusing to allow ... workflow` | Token lacks `workflow` scope | Create a token that includes `workflow` scope |
| Secret file still staged | `.gitignore` not catching it | `git rm --cached <file>` then push again |
| `push rejected` | Remote has commits you don't have | `git pull` → resolve conflicts → `git push` |

---

## FAQ

- **I lost my token.** — Revoke it on GitHub and generate a new one.
- **Is it safe that the repo is public?** — Yes: `secure/` and `terraform.tfstate*` are never pushed; only VM configs (containing SSH public keys) are exposed.
- **What else do I need to learn?** — This commit → push workflow covers day-to-day contribution. See `docs/` for project-specific operations.
- **How do I get a copy elsewhere?** — `git clone https://github.com/engr-rakib/terraform-lab.git`

---

## Pre-Push Checklist

1. `git status` — no secret file is staged.
2. Token is kept private (present in the git remote only, committed nowhere).
3. Commit message is clear and meaningful.
4. `git push` succeeds without error.

---

> **Note:** This is a quick-start guide. For detailed operations, see [docs/](docs/README.md) and the [operator guide](docs/operator-guide/operator-guide.md).