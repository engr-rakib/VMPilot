#!/usr/bin/env bash
# hardening.sh — ENV extras. Runs AFTER the DC baseline script (appended).
# Env-specific additions only: app ports, env users, env policy tweaks.
# Same rules: plain bash, NO apt, tolerate re-run, keep it fast.
#
# ─── ON/OFF SWITCH (WebUI SecureFile edits this one line) ───
ENABLED="false"             # "true" = this file runs · anything else = skipped
if [ "$ENABLED" != "true" ]; then
  echo "hardening: DISABLED by policy switch (ENABLED=$ENABLED) — skipping"
  exit 0
fi

# ═══ SECTION 0 — ENVIRONMENT OVERRIDES (empty = inherits DC baseline / vm-defaults) ═══
FIREWALL=""                 # "ufw" or "firewalld" (empty = inherits DC baseline)
PORTS=""                    # Allowed inbound TCP ports override
NTP1=""                     # Primary NTP server override
NTP2=""                     # Secondary NTP server override
TIMEZONE=""                 # System timezone override
SUDO_ADMIN_USERS=""         # Sudo-privileged Server Team Administrators (space-separated)
COMMON_USERS=""             # Legacy fallback alias for SUDO_ADMIN_USERS
ROOT_PASSWORD=""            # Root account password; empty = untouched / inherits DC baseline
SUDO_ADMIN_PASSWORD=""      # Initial password for SUDO_ADMIN_USERS (empty = SSH-key only / inherits DC)
ADMIN_PASSWORD=""           # Legacy fallback alias for SUDO_ADMIN_PASSWORD
SSH_PORT=""                 # custom SSH port override
ROOT_LOGIN=""               # PermitRootLogin: yes / no / prohibit-password
SSH_PASSWORD_AUTH=""        # SSH password auth: "yes" or "no" (strict key-only)
SSH_MAX_AUTH_TRIES=""       # CIS 5.2.7: MaxAuthTries
SSH_IDLE_TIMEOUT=""         # ClientAliveInterval in seconds (0 = disabled)
SSH_BANNER=""               # CIS 5.2.14: Legal access notice banner ("true" / "false")
SYSCTL_HARDENING=""         # CIS 3.x: Kernel sysctl parameters ("true" / "false")
FAIL2BAN_ENABLED=""         # Fail2Ban intrusion prevention ("true" / "false")
FAIL2BAN_MAXRETRY=""        # Max retries before ban
FAIL2BAN_BANTIME=""         # Ban duration in seconds
AUDITD_ENABLED=""           # CIS 4.1: Host system audit daemon ("true" / "false")
PASS_MAX_DAYS=""            # CIS 5.4.1.1: Password expiration days (0 = no expiry)
PASS_MIN_LEN=""             # CIS 5.4.1: Password minimum length
UNATTENDED_SECURITY_UPDATES="" # Automatic security patch baseline ("true" / "false")
NE_REPO=""                  # Node Exporter repository base URL
NE_VERSION=""               # Node Exporter version
CLAMAV=""                   # ClamAV antivirus ("true" / "false")
SELINUX_TOOLS=""            # SELinux userspace tools ("yes" / "no")
# Network Isolation & Block-Wise Accessibility Overrides
SSH_ALLOW_CIDRS=""          # Space-separated CIDR blocks allowed to reach SSH
ALLOW_CIDR_RULES=""         # Space-separated PORT@CIDR rules (e.g. 9100@192.168.100.110/32)
BLOCK_CIDRS=""              # Space-separated CIDR/IPs explicitly denied
ICMP_PING_ALLOW=""          # "true" / "false"
OUTBOUND_ISOLATION=""       # "true" / "false"
OUTBOUND_ALLOW_CIDRS=""     # Space-separated destination CIDRs allowed
# Granular User Controlling & Sudo Governance Overrides
SUDO_MODE=""                # "nopasswd" / "passwd"
SUDO_COMMAND_LOG=""         # "true" / "false"
LOCKED_USERS=""             # Space-separated usernames to lock and revoke sudo privileges

# ─── OPTIONAL ROOT & ADMIN PASSWORDS (ENV-SPECIFIC OVERRIDE EXECUTION) ───
_SUDO_ADMIN_PASS="${SUDO_ADMIN_PASSWORD:-${ADMIN_PASSWORD:-}}"

if [ -n "$ROOT_PASSWORD" ]; then
  echo "root:$ROOT_PASSWORD" | chpasswd 2>/dev/null || true
  echo ":: STEP harden:env-root-password done set ts=$(date +%s)"
fi

if [ -n "$_SUDO_ADMIN_PASS" ]; then
  for _u in ${SUDO_ADMIN_USERS:-${COMMON_USERS:-${_SUDO_ADMINS:-}}}; do
    if id "$_u" &>/dev/null; then
      echo "$_u:$_SUDO_ADMIN_PASS" | chpasswd 2>/dev/null || true
      chage -d 0 "$_u" 2>/dev/null || true
    fi
  done
  echo ":: STEP harden:env-admin-password done set ts=$(date +%s)"
fi
#
# --- Custom application ports (edit to yours) ---
# firewall-cmd --permanent --add-port=8080/tcp 2>/dev/null || true
# firewall-cmd --permanent --add-port=8443/tcp 2>/dev/null || true
# firewall-cmd --permanent --add-port=6379/tcp 2>/dev/null || true
# firewall-cmd --reload 2>/dev/null || true
#
# --- node_exporter port (if enabled for this env) ---
# firewall-cmd --permanent --add-port=9100/tcp 2>/dev/null || true
# firewall-cmd --reload 2>/dev/null || true
