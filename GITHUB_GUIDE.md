# GitHub Setup & Usage Guide (Noob-Friendly)

Ei project ke GitHub-এ rakhte hobe **version control** + **CI/CD** er jonno. Ei guide ti noob-er jonno — step by step, browser + terminal dui theke'i.

---

## কয়েকটা কথাই আগে (আমি কে, কেন GitHub)

| শব্দ | মানে |
|------|------|
| **Git** | আপনার কম্পিউটারে version tracking — project file-change গুলোর history রাখে |
| **GitHub** | Internet-এ Git repo hosting (backup + sharing) |
| **Repository (repo)** | আপনার project er folder, যেটা GitHub-এ online |
| **Commit** | "পরিবর্তন সেভ" — একটা snapshot |
| **Push** | আপনার local commit গুলো GitHub-এ পাঠানো |
| **Pull** | GitHub-হতে changes নেওয়া (আপনার machine-এ) |
| **Clone** | GitHub-হতে নতুন copy দূরে name setup |

**কেন করবো?** file backup, যেকোনো জায়গা থেকে code দেখা, change history, কেউ error করলে undo, এবং CI (auto-check)।

---

## ⚠️ প্রথমেই security নিয়ম (সবচেয়ে গুরুত্বপূর্ণ)

এই project-এ Secret file গুলো (`terraform.tfstate`, `secure/**/*.tfvars`) GitHub-এ **NEVER push করা হয়**।

`.gitignore` file already ঠিক করা আছে — এটাই auto-রূপে নিষেধ করে।

| ফাইল | GitHub-এ যাবে? | কারণ |
|------|:---:|------|
| `deploy/*/vm-*.tfvars` | ✅ হ্যাঁ | ssh public key only, safe |
| `terraform/` (.tf code) | ✅ হ্যাঁ | code, secret নয় |
| `docs/`, `scripts/` | ✅ হ্যাঁ | docs + script |
| `terraform.tfstate*` | ❌ না | vCenter password তথ্য |
| `secure/` | ❌ না | vcenter password (encrypted) |
| `.terraform/` | ❌ না | local cache |
| `*.tfplan` | ❌ না | state backup |

> **গোল্ডেন রুল:** Push ধরার আগে `git status` run করে দেখো — যেন `secure/` বা `*.tfstate` না দেখাও। নিচে Checklist section-এ ধাপ দেয়া আছে.

---

## Setup (একবার) — প্রথমবার GitHub-এ connection

### Step 1: GitHub Account বানাও
- 💻 [github.com](https://github.com) → **Sign up** → username + email + password
- (আমার username: `engr-rakib`, repo: `terraform-lab`)

### Step 2: Git install
```bash
# Debian/Ubuntu
sudo apt update && sudo apt install git -y

# verify
git --version
```

### Step 3: Git-এ আপনার identity set করা (একবার)
```
git config --global user.name "engr-rakib"
git config --global user.email "youremail@example.com"
```

### Step 4: GitHub-এ repo create (browser)
1. যাও `github.com/new`
2. Repository name: `terraform-lab` → **Public** select
3. **Create repository** (kono checkbox নয় — empty repo)
4. এখন একটি URL পাবে: `https://github.com/engr-rakib/terraform-lab.git`

### Step 5: Token তৈরি (browser) — push করতে লাগবে
1. [github.com/settings/tokens/new](https://github.com/settings/tokens/new)
2. Note: `project01-push`
3. **Expiration:** `90 days` (best practice — finite)
4. **Scopes:** 🎯 এই দুটা checkbox চেক করো:
   - ☑ `repo` (push হবে)
   - ☑ `workflow` (CI workflow file push-এ লাগবে — `.github/workflows/`)
5. **Generate token** → `ghp_...` copy। 
   > **জরুরী:** এইটাকে কেও দেখবে না। কোথাও ভাগে না। কাজ শেষে revoke করো!

### Step 6: Local repo → GitHub (One time)
```
# project directory-তে enter
cd /opt/terraform-lab/projects/project01

# remote যোগ করো (token example — আপনি নিজের token ব্যবহার)
git remote add origin https://<YOUR_TOKEN>@github.com/engr-rakib/terraform-lab.git

# first push
git push -u origin main
```

> `-u origin main` মানে — এখন থেকে just `git push` লিখলেই যথেষ্ট।

---

## Daily Workflow (প্রতিবার)

নিয়মিত কাজ করি — change, add VM, edit script — তাহলে:

```bash
cd /opt/terraform-lab/projects/project01

# ১) কোন file change হয়েছে দেখো
git status

# ২) specific file add (বা সব: git add .)
git add filename.tf
git add scripts/deploy-vm.sh

# ৩) commit (message বুঝানো — কী করলি)
git commit -m "Add VM web-04 config"

# ৪) github-এ পাঠাও
git push
```

তাড়াতাড়ি shortcut:
```
git add -A                    # সব change stage
git commit -m "message"       # commit
git push                      # GitHub-এ পাঠানো
```

---

## বেস্ট commit rules (Noob hack)

1. **Commit message ছোট কিন্তু মানে বুঝা যায়:**
   - ❌ `update` 
   - ✅ `Add deploy config for web-04`
2. **একটা logical change –এ একটা commit**
3. **সব না, নথি না যোগ করি** — আগে `git status` দেখো
4. **Secret কভার করো না** — (মনে রাখো `.gitignore` already আছে)

---

## CI/CD What-Why (GitHub Actions)

repo-এ `workflow` scope token থাকলে এই auto-এর বৈচিত্র্য (validate + security) GitHub-এ হবে।
তবে **deploy নয়**, কারণ vCenter private network-এ আছে।

- **GitHub-hosted runner** = private vCenter (`192.0.2.10`) reach করবে না।
- তাই GitHub Actions দিয়ে শুধু **CI (check)** করা যায়, deploy নয়।
- 🎯 এর সুবিধা: code-check (`terraform fmt`, `validate`) + security scan (tflint/tfsec/checkov) — প্রতিবার push-এ auto।

যদি deploy চাও GitHub-দিয়ে, তাহলে দরকার: **self-hosted runner** (এই Terraform server-এ)।
এটা extra setup — এই guide-এর বাইরে।

### CI workflow file আবার যোগ করা (ঐচ্ছিক)

এই project-এ `.github/workflows/terraform-ci.yml` আছে। এই file push করার সময় token-এ `workflow` scope লাগে।

```bash
git checkout origin/main -- .github/workflows/terraform-ci.yml   # local-এ ফিরিয়ে আনা
# অথবা পুরনো commit থেকে
git show <commit>:.github/workflows/terraform-ci.yml > .github/workflows/terraform-ci.yml

git add .github/workflows/terraform-ci.yml
git commit -m "Re-enable GitHub Actions CI"
git push
```

`workflow` scope-যুক্ত token না থাকলে push reject হবে — তখন টোকেনে scope যোগ করে নতুন token বানাও।

---

## সমস্যা হলে (Troubleshooting)

| **Error** | **কখন হয়** | **সমাধান** |
|---|---|---|
| `Authentication failed` | token ভুল/মেয়াদ শেষ | নতুন token → `git remote set-url` |
| `Missing required scope 'read:org'` | gh দিয়ে login | gh-এ push না করে; git token-এ push |
| `refusing to allow ... workflow` | token-এ `workflow` scope নাই | token-এ `workflow` scope যোগ করো |
| পুশ হচ্ছে না secret file | .gitignore কাজ করছে না | `git rm --cached <file>` → আবার push |
| `push rejected` | কেউ আগে push করেছে | `git pull` → merge → `git push` |

---

## Frequently Asked

- **টোকেন হারিয়ে ফেললাম** — revoke → নতুন token বানাও
- **public repo-তে নিরাপত্তা?** — `secure/` + `tfstate` push হয় না; শুধু VM config (public key) যায়
- **আর কী কী শিখতে হবে** — commit/push workflow-ই যথেষ্ট
- **অন্য জায়গায় copy** — `git clone https://github.com/engr-rakib/terraform-lab.git`

---

## Checklist — প্রতিটি push-এর আগে

1. `git status` → kono secret file নেই
2. Token নিজের কাছে (git remote-এ আছে, আর কোথাও না)
3. Commit message স্পষ্ট (meaning)
4. `git push`

সব ঠিক থাকলে — 👍

---

> **Note:** এটা shortcut guide। আরো বিস্তারিত দেখো [docs/](docs/README.md) এবং [operator-guide](docs/operator-guide/operator-guide.md)।