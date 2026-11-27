#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# hardening.sh — DATACENTER baseline = enterprise doc, direct translation:
# docs/terraform-backend/04-security-and-hardening/02-os-hardening-pipeline.md
# Copy-paste style: plain commands in doc order, top to bottom.
# # at line start = SKIPPED. Runs VERBATIM after OS provisioning + LAN up.
# Output → /var/log/vmpilot-hardening.log · result → manifest.
# NOTE: root password (Phase 1) + hostname (Phase 2) stay manual/console
# steps (interactive) — everything below runs unattended. Passwords are
# NEVER stored here (SSH keys come from $VMPILOT_SSH_KEY).
# ══════════════════════════════════════════════════════════════════════
# ─── ON/OFF SWITCH (WebUI SecureFile edits this one line) ───
ENABLED="true"              # "true" = this file runs · anything else = skipped
if [ "$ENABLED" != "true" ]; then
  echo "hardening: DISABLED by policy switch (ENABLED=$ENABLED) — skipping"
  exit 0
fi
export DEBIAN_FRONTEND=noninteractive
#
# ═══ SECTION 0 — DECISIONS (edit values only; commands below use them) ═══
FIREWALL="ufw"              # "ufw" or "firewalld"
PORTS="80 443 8080 8443 6379 6160 6162 6163 10808 15672 9100"  # ssh/22 always kept
NTP1="pool.ntp.org"
NTP2=""
TIMEZONE="Asia/Dhaka"
SUDO_ADMIN_USERS=""         # Sudo-privileged Server Team Administrators (space-separated)
COMMON_USERS=""             # Legacy fallback alias for SUDO_ADMIN_USERS
ROOT_PASSWORD=""            # Root account password; empty = untouched
SUDO_ADMIN_PASSWORD=""      # Initial password for SUDO_ADMIN_USERS; forces password change on 1st login (empty = SSH-key only)
ADMIN_PASSWORD=""           # Legacy fallback alias for SUDO_ADMIN_PASSWORD
SSH_PORT="22"               # custom port auto-opens in firewall (22 stays as fallback)
ROOT_LOGIN="yes"            # PermitRootLogin yes/no (doc Phase 7)
SSH_PASSWORD_AUTH="yes"     # SSH password auth: "yes" or "no" (strict key-only)
SSH_MAX_AUTH_TRIES="4"      # CIS 5.2.7: MaxAuthTries
SSH_IDLE_TIMEOUT="900"      # ClientAliveInterval in seconds (0 = disabled); ClientAliveCountMax 2
SSH_BANNER="true"           # CIS 5.2.14: Legal access notice banner
SYSCTL_HARDENING="true"     # CIS 3.x: Kernel & Network sysctl parameter baseline
FAIL2BAN_ENABLED="true"     # Fail2Ban intrusion prevention
FAIL2BAN_MAXRETRY="5"       # Max retries before ban
FAIL2BAN_BANTIME="3600"     # Ban duration in seconds
AUDITD_ENABLED="true"       # CIS 4.1: Host system audit daemon
PASS_MAX_DAYS="90"          # CIS 5.4.1.1: Password expiration days (0 = no expiry)
PASS_MIN_LEN="12"           # CIS 5.4.1: Password minimum length
UNATTENDED_SECURITY_UPDATES="false" # Automatic security patch baseline
NE_REPO="https://repo.internal:8443/repository/node_exp"   # internal repo base (set yours)
NE_VERSION="1.12.1"         # must match the tarball in the repo above
CLAMAV="false"              # "true" = file/mail servers only
SELINUX_TOOLS="no"          # "yes" = opt-in SELinux userspace tools (Ubuntu default is AppArmor)
# Network Isolation & Block-Wise Accessibility
SSH_ALLOW_CIDRS=""          # Space-separated CIDR blocks allowed to reach SSH (empty = any source)
ALLOW_CIDR_RULES=""         # Space-separated PORT@CIDR rules (e.g. 9100@192.168.100.110/32 5432@10.20.0.0/24)
BLOCK_CIDRS=""              # Space-separated CIDR/IPs explicitly denied
ICMP_PING_ALLOW="true"      # "true" = allow ping; "false" = drop inbound ICMP echo-request
OUTBOUND_ISOLATION="false"  # "true" = strict egress deny-by-default (DNS 53, NTP 123 + OUTBOUND_ALLOW_CIDRS only)
OUTBOUND_ALLOW_CIDRS=""     # Space-separated destination CIDRs allowed when OUTBOUND_ISOLATION="true"
# Granular User Controlling & Sudo Governance
SUDO_MODE="nopasswd"        # "nopasswd" (NOPASSWD:ALL) or "passwd" (password required for sudo)
SUDO_COMMAND_LOG="true"     # "true" = audit sudo commands to /var/log/sudo.log
LOCKED_USERS=""             # Space-separated usernames to lock and revoke sudo privileges

# ─── 3-Tier Fallback Resolution (vm-defaults.conf -> hardening.sh) ───
FIREWALL="${FIREWALL:-${DEFAULT_FIREWALL:-ufw}}"
PORTS="${PORTS:-${DEFAULT_PORTS:-80 443 8080 8443 6379 6160 6162 6163 10808 15672 9100}}"
NTP1="${NTP1:-${DEFAULT_NTP1:-pool.ntp.org}}"
NTP2="${NTP2:-${DEFAULT_NTP2:-}}"
TIMEZONE="${TIMEZONE:-${DEFAULT_TIMEZONE:-Asia/Dhaka}}"
_SUDO_ADMINS="${SUDO_ADMIN_USERS:-${COMMON_USERS:-${DEFAULT_SUDO_ADMIN_USERS:-}}}"
_SUDO_ADMIN_PASS="${SUDO_ADMIN_PASSWORD:-${ADMIN_PASSWORD:-${DEFAULT_SUDO_ADMIN_PASSWORD:-}}}"
ROOT_PASSWORD="${ROOT_PASSWORD:-${DEFAULT_ROOT_PASSWORD:-}}"
SSH_PORT="${SSH_PORT:-${DEFAULT_SSH_PORT:-22}}"
SSH_ROOT_LOGIN="${SSH_ROOT_LOGIN:-${ROOT_LOGIN:-${DEFAULT_ROOT_LOGIN:-yes}}}"
ROOT_LOGIN="$SSH_ROOT_LOGIN"
SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-${DEFAULT_SSH_PASSWORD_AUTH:-yes}}"
SSH_MAX_AUTH_TRIES="${SSH_MAX_AUTH_TRIES:-${DEFAULT_SSH_MAX_AUTH_TRIES:-4}}"
SSH_IDLE_TIMEOUT="${SSH_IDLE_TIMEOUT:-${DEFAULT_SSH_IDLE_TIMEOUT:-900}}"
SSH_BANNER="${SSH_BANNER:-${DEFAULT_SSH_BANNER:-true}}"
SYSCTL_HARDENING="${SYSCTL_HARDENING:-${DEFAULT_SYSCTL_HARDENING:-true}}"
FAIL2BAN_ENABLED="${FAIL2BAN_ENABLED:-${DEFAULT_FAIL2BAN_ENABLED:-true}}"
FAIL2BAN_MAXRETRY="${FAIL2BAN_MAXRETRY:-${DEFAULT_FAIL2BAN_MAXRETRY:-5}}"
FAIL2BAN_BANTIME="${FAIL2BAN_BANTIME:-${DEFAULT_FAIL2BAN_BANTIME:-3600}}"
AUDITD_ENABLED="${AUDITD_ENABLED:-${DEFAULT_AUDITD_ENABLED:-true}}"
PASS_MAX_DAYS="${PASS_MAX_DAYS:-${DEFAULT_PASS_MAX_DAYS:-90}}"
PASS_MIN_LEN="${PASS_MIN_LEN:-${DEFAULT_PASS_MIN_LEN:-12}}"
UNATTENDED_SECURITY_UPDATES="${UNATTENDED_SECURITY_UPDATES:-${DEFAULT_UNATTENDED_SECURITY_UPDATES:-false}}"
NE_REPO="${NE_REPO:-${DEFAULT_NE_REPO:-https://repo.internal:8443/repository/node_exp}}"
NE_VERSION="${NE_VERSION:-${DEFAULT_NE_VERSION:-1.12.1}}"
CLAMAV="${CLAMAV:-${DEFAULT_CLAMAV:-false}}"
SELINUX_TOOLS="${SELINUX_TOOLS:-${DEFAULT_SELINUX_TOOLS:-no}}"
SSH_ALLOW_CIDRS="${SSH_ALLOW_CIDRS:-${DEFAULT_SSH_ALLOW_CIDRS:-}}"
ALLOW_CIDR_RULES="${ALLOW_CIDR_RULES:-${DEFAULT_ALLOW_CIDR_RULES:-}}"
BLOCK_CIDRS="${BLOCK_CIDRS:-${DEFAULT_BLOCK_CIDRS:-}}"
ICMP_PING_ALLOW="${ICMP_PING_ALLOW:-${DEFAULT_ICMP_PING_ALLOW:-true}}"
OUTBOUND_ISOLATION="${OUTBOUND_ISOLATION:-${DEFAULT_OUTBOUND_ISOLATION:-false}}"
OUTBOUND_ALLOW_CIDRS="${OUTBOUND_ALLOW_CIDRS:-${DEFAULT_OUTBOUND_ALLOW_CIDRS:-}}"
SUDO_MODE="${SUDO_MODE:-${DEFAULT_SUDO_MODE:-nopasswd}}"
SUDO_COMMAND_LOG="${SUDO_COMMAND_LOG:-${DEFAULT_SUDO_COMMAND_LOG:-true}}"
LOCKED_USERS="${LOCKED_USERS:-${DEFAULT_LOCKED_USERS:-}}"

#
# ─── Phase 3: User Provisioning & Password Aging (CIS 5.4) ───
PASS="$_SUDO_ADMIN_PASS"
for u in $_SUDO_ADMINS; do
  if ! id "$u" &>/dev/null; then
    useradd -m -s /bin/bash "$u"
    mkdir -p "/home/$u/.ssh" && chmod 700 "/home/$u/.ssh"
    if [ -n "${VMPILOT_SSH_KEY:-}" ]; then
      grep -qF "$VMPILOT_SSH_KEY" \
      "/home/$u/.ssh/authorized_keys" 2>/dev/null || \
      echo "$VMPILOT_SSH_KEY" >> "/home/$u/.ssh/authorized_keys" || true
    fi
    chmod 600 "/home/$u/.ssh/authorized_keys" 2>/dev/null || true
    chown -R "$u:$u" "/home/$u/.ssh" 2>/dev/null || true
    if [ -n "$PASS" ]; then
      echo "$u:$PASS" | chpasswd
      chage -d 0 "$u"
    fi
    [ -n "$PASS_MAX_DAYS" ] && [ "$PASS_MAX_DAYS" -gt 0 ] 2>/dev/null && chage -M "$PASS_MAX_DAYS" "$u" 2>/dev/null || true
    usermod -aG sudo "$u" 2>/dev/null || true
    if [ "$SUDO_MODE" = "passwd" ]; then
      echo "$u ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/90-vmpilot-$u" || true
    else
      echo "$u ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-vmpilot-$u" || true
    fi
    chmod 440 "/etc/sudoers.d/90-vmpilot-$u" 2>/dev/null || true
    visudo -c -q -f "/etc/sudoers.d/90-vmpilot-$u" 2>/dev/null || rm -f "/etc/sudoers.d/90-vmpilot-$u"
    echo "Created: $u"
  else
    echo "User already exists: $u"
    if [ -n "$PASS" ]; then
      echo "$u:$PASS" | chpasswd
      chage -d 0 "$u"
    fi
    [ -n "$PASS_MAX_DAYS" ] && [ "$PASS_MAX_DAYS" -gt 0 ] 2>/dev/null && chage -M "$PASS_MAX_DAYS" "$u" 2>/dev/null || true
    usermod -aG sudo "$u" 2>/dev/null || true
    if [ "$SUDO_MODE" = "passwd" ]; then
      echo "$u ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/90-vmpilot-$u" || true
    else
      echo "$u ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-vmpilot-$u" || true
    fi
    chmod 440 "/etc/sudoers.d/90-vmpilot-$u" 2>/dev/null || true
    visudo -c -q -f "/etc/sudoers.d/90-vmpilot-$u" 2>/dev/null || rm -f "/etc/sudoers.d/90-vmpilot-$u"
  fi
done

# Sudo command audit logging
if [ "$SUDO_COMMAND_LOG" = "true" ]; then
  echo 'Defaults logfile="/var/log/sudo.log"' > /etc/sudoers.d/90-vmpilot-audit || true
  chmod 440 /etc/sudoers.d/90-vmpilot-audit 2>/dev/null || true
  visudo -c -q -f /etc/sudoers.d/90-vmpilot-audit 2>/dev/null || rm -f /etc/sudoers.d/90-vmpilot-audit
else
  rm -f /etc/sudoers.d/90-vmpilot-audit 2>/dev/null || true
fi

# Locked & Revoked accounts enforcement
for lu in $LOCKED_USERS; do
  if id "$lu" &>/dev/null; then
    usermod -L "$lu" 2>/dev/null || true
    chage -E 0 "$lu" 2>/dev/null || true
    rm -f "/etc/sudoers.d/90-vmpilot-$lu" 2>/dev/null || true
    echo "Account locked & sudo revoked: $lu"
  fi
done

# Password aging policy in /etc/login.defs
if [ -f /etc/login.defs ]; then
  [ -n "$PASS_MAX_DAYS" ] && [ "$PASS_MAX_DAYS" -gt 0 ] 2>/dev/null && \
    sed -i "s/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   $PASS_MAX_DAYS/" /etc/login.defs || true
  [ -n "$PASS_MIN_LEN" ] && [ "$PASS_MIN_LEN" -gt 0 ] 2>/dev/null && \
    sed -i "s/^PASS_MIN_LEN.*/PASS_MIN_LEN    $PASS_MIN_LEN/" /etc/login.defs || true
fi

# Verify users:
for u in $_SUDO_ADMINS; do
  echo "----- $u -----"
  id "$u"
  groups "$u"
done
# Verify home directories:
ls -ld /home/* 2>/dev/null || true
_u_count=$(echo "$_SUDO_ADMINS" | wc -w)
echo ":: STEP harden:users done ${_u_count}-users ts=$(date +%s)"
#
# ─── Phase 5: Essential Administration Tools (Binary-Guarded) ───
_NEED=""
command -v nmcli >/dev/null 2>&1 || _NEED="$_NEED network-manager"
command -v plocate >/dev/null 2>&1 || _NEED="$_NEED plocate"
command -v sar >/dev/null 2>&1 || _NEED="$_NEED sysstat"
command -v traceroute >/dev/null 2>&1 || _NEED="$_NEED traceroute"
command -v netstat >/dev/null 2>&1 || _NEED="$_NEED net-tools"
command -v htop >/dev/null 2>&1 || _NEED="$_NEED htop"
command -v curl >/dev/null 2>&1 || _NEED="$_NEED curl"
command -v wget >/dev/null 2>&1 || _NEED="$_NEED wget"
command -v vim >/dev/null 2>&1 || _NEED="$_NEED vim"
command -v chronyc >/dev/null 2>&1 || _NEED="$_NEED chrony"
command -v rsync >/dev/null 2>&1 || _NEED="$_NEED rsync"
command -v auditctl >/dev/null 2>&1 || _NEED="$_NEED auditd"
command -v zip >/dev/null 2>&1 || _NEED="$_NEED zip"
command -v unzip >/dev/null 2>&1 || _NEED="$_NEED unzip"
command -v lsof >/dev/null 2>&1 || _NEED="$_NEED lsof"
command -v tcpdump >/dev/null 2>&1 || _NEED="$_NEED tcpdump"
command -v ncdu >/dev/null 2>&1 || _NEED="$_NEED ncdu"
command -v fail2ban-client >/dev/null 2>&1 || _NEED="$_NEED fail2ban"
[ -f /usr/share/bash-completion/bash_completion ] || _NEED="$_NEED bash-completion"
if [ "$FIREWALL" = "firewalld" ]; then
  command -v firewall-cmd >/dev/null 2>&1 || _NEED="$_NEED firewalld"
fi
if [ "$UNATTENDED_SECURITY_UPDATES" = "true" ]; then
  dpkg -s unattended-upgrades >/dev/null 2>&1 || _NEED="$_NEED unattended-upgrades"
fi
if [ -n "$_NEED" ]; then
  timeout 120 apt-get update -qq 2>/dev/null || true
  timeout 600 apt-get install -y --no-install-recommends $_NEED 2>/dev/null || apt-get install -y $_NEED 2>/dev/null || true
fi
echo ":: STEP harden:tools done $(echo "$_NEED" | wc -w)-installed ts=$(date +%s)"
#
# ─── Root password (doc Phase 1; empty = untouched) ───
if [ -n "$ROOT_PASSWORD" ]; then
  echo "root:$ROOT_PASSWORD" | chpasswd 2>/dev/null || true
  echo ":: STEP harden:root-password done set ts=$(date +%s)"
else
  echo ":: STEP harden:root-password done untouched ts=$(date +%s)"
fi
#
# ─── Phase 4: Time Synchronization (Chrony) ───
mkdir -p /etc/chrony/conf.d
if [ -n "$NTP1" ]; then
  echo "server $NTP1 iburst" > /etc/chrony/conf.d/vmpilot.conf
  if [ -n "$NTP2" ]; then
    echo "server $NTP2 iburst" >> /etc/chrony/conf.d/vmpilot.conf
  fi
fi
if [ -n "$TIMEZONE" ]; then
  timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true
fi
systemctl enable --now chrony 2>/dev/null || true
systemctl restart chrony 2>/dev/null || true
chronyc reload sources 2>/dev/null || true
# Verify:
timedatectl 2>/dev/null || true
chronyc tracking 2>/dev/null || true
chronyc sources -v 2>/dev/null || true
echo ":: STEP harden:chrony done ntp=${NTP1:-pool.ntp.org} ts=$(date +%s)"
#
# ─── Kernel & Network Sysctl Hardening (CIS 3.x) ───
if [ "$SYSCTL_HARDENING" = "true" ]; then
  mkdir -p /etc/sysctl.d
  cat <<'EOF_SYSCTL' > /etc/sysctl.d/99-vmpilot-hardening.conf
# VMPilot CIS Level-1 Network & Kernel Hardening Baseline
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF_SYSCTL
  sysctl --system >/dev/null 2>&1 || true
  echo ":: STEP harden:sysctl done active ts=$(date +%s)"
else
  echo ":: STEP harden:sysctl skip disabled ts=$(date +%s)"
fi
#
# ─── Phase 6: Firewall Hardening (Dual-Engine: ufw / firewalld) ───
if [ "$FIREWALL" = "firewalld" ]; then
  systemctl enable --now firewalld 2>/dev/null || true
  # Block explicitly denied CIDRs first
  for _bc in $BLOCK_CIDRS; do
    firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${_bc}' drop" 2>/dev/null || true
  done

  # ICMP Ping allow / stealth
  if [ "$ICMP_PING_ALLOW" = "false" ]; then
    firewall-cmd --permanent --add-icmp-block=echo-request 2>/dev/null || true
  fi

  # SSH Access: restrict to SSH_ALLOW_CIDRS or open globally
  if [ -n "$SSH_ALLOW_CIDRS" ]; then
    firewall-cmd --permanent --remove-service=ssh 2>/dev/null || true
    for _cidr in $SSH_ALLOW_CIDRS; do
      firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${_cidr}' port port='22' protocol='tcp' accept" 2>/dev/null || true
      [ "$SSH_PORT" != "22" ] && firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${_cidr}' port port='${SSH_PORT}' protocol='tcp' accept" 2>/dev/null || true
    done
  else
    firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
    [ "$SSH_PORT" != "22" ] && firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" 2>/dev/null || true
  fi

  # Standard inbound TCP ports
  for _p in $PORTS; do
    firewall-cmd --permanent --add-port="${_p}/tcp" 2>/dev/null || true
  done

  # Block-wise CIDR rules (PORT@CIDR)
  for _rule in $ALLOW_CIDR_RULES; do
    _rport="${_rule%%@*}"
    _rcidr="${_rule##*@}"
    if [ -n "$_rport" ] && [ -n "$_rcidr" ]; then
      firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${_rcidr}' port port='${_rport}' protocol='tcp' accept" 2>/dev/null || true
    fi
  done

  # Strict Outbound Isolation
  if [ "$OUTBOUND_ISOLATION" = "true" ]; then
    firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 0 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 1 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
    firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 1 -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
    firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 1 -p udp --dport 123 -j ACCEPT 2>/dev/null || true
    for _oc in $OUTBOUND_ALLOW_CIDRS; do
      firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 2 -d "$_oc" -j ACCEPT 2>/dev/null || true
    done
    firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 99 -j DROP 2>/dev/null || true
  fi

  firewall-cmd --reload 2>/dev/null || true
  echo ":: STEP harden:firewalld done $(echo "$PORTS" | wc -w)-ports ts=$(date +%s)"
else
  systemctl enable --now ufw 2>/dev/null || true
  ufw --force reset 2>/dev/null || true
  ufw default deny incoming 2>/dev/null || true

  # Strict Outbound Isolation
  if [ "$OUTBOUND_ISOLATION" = "true" ]; then
    ufw default deny outgoing 2>/dev/null || true
    ufw allow out 53 2>/dev/null || true
    ufw allow out 123/udp 2>/dev/null || true
    for _oc in $OUTBOUND_ALLOW_CIDRS; do
      ufw allow out to "$_oc" 2>/dev/null || true
    done
  else
    ufw default allow outgoing 2>/dev/null || true
  fi

  # Block explicitly denied CIDRs with top priority
  for _bc in $BLOCK_CIDRS; do
    ufw insert 1 deny from "$_bc" 2>/dev/null || true
  done

  # ICMP Ping allow / stealth
  if [ "$ICMP_PING_ALLOW" = "false" ] && [ -f /etc/ufw/before.rules ]; then
    sed -i '/-p icmp --icmp-type echo-request -j ACCEPT/s/ACCEPT/DROP/' /etc/ufw/before.rules 2>/dev/null || true
  elif [ -f /etc/ufw/before.rules ]; then
    sed -i '/-p icmp --icmp-type echo-request -j DROP/s/DROP/ACCEPT/' /etc/ufw/before.rules 2>/dev/null || true
  fi

  # SSH Access: restrict to SSH_ALLOW_CIDRS or open globally
  if [ -n "$SSH_ALLOW_CIDRS" ]; then
    for _cidr in $SSH_ALLOW_CIDRS; do
      ufw allow from "$_cidr" to any port 22 proto tcp 2>/dev/null || true
      [ "$SSH_PORT" != "22" ] && ufw allow from "$_cidr" to any port "$SSH_PORT" proto tcp 2>/dev/null || true
    done
  else
    ufw allow 22/tcp 2>/dev/null || true
    [ "$SSH_PORT" != "22" ] && ufw allow "${SSH_PORT}/tcp" 2>/dev/null || true
  fi

  # Standard inbound TCP ports
  for _p in $PORTS; do
    ufw allow "${_p}/tcp" 2>/dev/null || true
  done

  # Block-wise CIDR rules (PORT@CIDR)
  for _rule in $ALLOW_CIDR_RULES; do
    _rport="${_rule%%@*}"
    _rcidr="${_rule##*@}"
    if [ -n "$_rport" ] && [ -n "$_rcidr" ]; then
      ufw allow from "$_rcidr" to any port "$_rport" proto tcp 2>/dev/null || true
    fi
  done

  echo "y" | ufw enable 2>/dev/null || true
  echo ":: STEP harden:ufw done $(echo "$PORTS" | wc -w)-ports ts=$(date +%s)"
fi
#
# ─── Prometheus Node Exporter (Binary Install) ───
if [ -n "$NE_REPO" ] && [ "$NE_REPO" != "https://repo.internal:8443/repository/node_exp" ]; then
  id node_exporter &>/dev/null || useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true
  _TAR="node_exporter-${NE_VERSION}.linux-amd64.tar.gz"
  _URL="${NE_REPO%/}/${_TAR}"
  {
    curl -kfsSL "$_URL" -o "/tmp/${_TAR}" 2>/dev/null || wget --no-check-certificate -q "$_URL" -O "/tmp/${_TAR}" 2>/dev/null
    tar -xzf "/tmp/${_TAR}" -C /tmp/ 2>/dev/null
    cp "/tmp/node_exporter-${NE_VERSION}.linux-amd64/node_exporter" /usr/local/bin/ 2>/dev/null
    chown node_exporter:node_exporter /usr/local/bin/node_exporter 2>/dev/null
    chmod 755 /usr/local/bin/node_exporter 2>/dev/null
    rm -rf "/tmp/${_TAR}" "/tmp/node_exporter-${NE_VERSION}.linux-amd64" 2>/dev/null
    {
      echo '[Unit]'
      echo 'Description=Prometheus Node Exporter'
      echo 'After=network-online.target'
      echo 'Wants=network-online.target'
      echo '[Service]'
      echo 'User=node_exporter'
      echo 'Group=node_exporter'
      echo 'ExecStart=/usr/local/bin/node_exporter'
      echo 'Restart=always'
      echo 'RestartSec=10'
      echo '[Install]'
      echo 'WantedBy=multi-user.target'
    } > /etc/systemd/system/node_exporter.service
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now node_exporter 2>/dev/null || true
  } || true
  if systemctl is-active --quiet node_exporter 2>/dev/null; then
    echo ":: STEP harden:node-exporter done v=$NE_VERSION ts=$(date +%s)"
  else
    echo ":: STEP harden:node-exporter done inactive-or-repo-unreachable ts=$(date +%s)"
  fi
else
  echo ":: STEP harden:node-exporter skip no-repo-configured ts=$(date +%s)"
fi
#
# ─── Phase 7: SSH Hardening (CIS 5.2) ───
mkdir -p /etc/ssh/sshd_config.d
[ -f /etc/ssh/sshd_config ] && cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true

if [ "$SSH_BANNER" = "true" ]; then
  cat <<'EOF_BANNER' > /etc/issue.net
*******************************************************************************
*                               NOTICE TO USERS                               *
* This computer system is for authorized users only. Unauthorized or improper  *
* use of this system may result in administrative disciplinary action and/or  *
* civil and criminal penalties. By continuing to use this system you indicate *
* your awareness of and consent to these terms and conditions of use.         *
*******************************************************************************
EOF_BANNER
fi

{
  echo "Port $SSH_PORT"
  echo "PermitRootLogin $ROOT_LOGIN"
  echo "PasswordAuthentication $SSH_PASSWORD_AUTH"
  echo "MaxAuthTries ${SSH_MAX_AUTH_TRIES:-4}"
  echo 'X11Forwarding no'
  echo 'UseDNS no'
  echo 'GSSAPIAuthentication no'
  [ -n "$SSH_IDLE_TIMEOUT" ] && [ "$SSH_IDLE_TIMEOUT" != "0" ] && {
    echo "ClientAliveInterval $SSH_IDLE_TIMEOUT"
    echo "ClientAliveCountMax 2"
  }
  [ "$SSH_BANNER" = "true" ] && echo "Banner /etc/issue.net"
} > /etc/ssh/sshd_config.d/99-vmpilot-doc.conf

if [ "$ROOT_LOGIN" = "yes" ] || [ "$ROOT_LOGIN" = "prohibit-password" ]; then
  if [ -f /root/.ssh/authorized_keys ]; then
    sed -i -E 's/^.*(ssh-(rsa|ed25519|ecdsa)|ecdsa-sha2-)/\1/' /root/.ssh/authorized_keys 2>/dev/null || true
  fi
fi

if sshd -t 2>/dev/null; then
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  echo ":: STEP harden:sshd done port=$SSH_PORT root_login=$ROOT_LOGIN pass_auth=$SSH_PASSWORD_AUTH ts=$(date +%s)"
else
  rm -f /etc/ssh/sshd_config.d/99-vmpilot-doc.conf
  echo ":: STEP harden:sshd fail invalid-config-reverted ts=$(date +%s)"
fi
#
# ─── Phase 8: Fail2Ban Intrusion Defense ───
if [ "$FAIL2BAN_ENABLED" = "true" ]; then
  mkdir -p /etc/fail2ban/jail.d
  cat <<EOF_F2B > /etc/fail2ban/jail.d/99-vmpilot-sshd.conf
[sshd]
enabled = true
port = $SSH_PORT
maxretry = ${FAIL2BAN_MAXRETRY:-5}
bantime = ${FAIL2BAN_BANTIME:-3600}
EOF_F2B
  systemctl enable --now fail2ban 2>/dev/null || true
  systemctl restart fail2ban 2>/dev/null || true
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    echo ":: STEP harden:fail2ban done active ts=$(date +%s)"
  else
    echo ":: STEP harden:fail2ban done installed ts=$(date +%s)"
  fi
else
  systemctl stop fail2ban 2>/dev/null || true
  systemctl disable fail2ban 2>/dev/null || true
  echo ":: STEP harden:fail2ban skip disabled ts=$(date +%s)"
fi
#
# ─── Host Audit Logging (auditd — CIS 4.1) ───
if [ "$AUDITD_ENABLED" = "true" ]; then
  mkdir -p /etc/audit/rules.d
  cat <<'EOF_AUDIT' > /etc/audit/rules.d/99-vmpilot.rules
# VMPilot CIS Level-1 Audit Rules Baseline
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /etc/ssh/sshd_config -p wa -k config_ssh
-w /etc/ssh/sshd_config.d/ -p wa -k config_ssh
EOF_AUDIT
  command -v augenrules >/dev/null 2>&1 && augenrules --load >/dev/null 2>&1 || true
  systemctl enable --now auditd 2>/dev/null || true
  systemctl restart auditd 2>/dev/null || true
  echo ":: STEP harden:auditd done active ts=$(date +%s)"
else
  echo ":: STEP harden:auditd skip disabled ts=$(date +%s)"
fi
#
# ─── Automatic Security Patches Baseline ───
if [ "$UNATTENDED_SECURITY_UPDATES" = "true" ]; then
  cat <<'EOF_UNATTENDED' > /etc/apt/apt.conf.d/50unattended-upgrades-vmpilot
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF_UNATTENDED
  echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
  echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades
  echo ":: STEP harden:unattended-upgrades done active ts=$(date +%s)"
else
  echo ":: STEP harden:unattended-upgrades skip disabled ts=$(date +%s)"
fi
#
# ─── Phase 9: Antivirus (Strictly Gated Opt-In: CLAMAV=true) ───
if [ "${CLAMAV:-false}" = "true" ]; then
  apt-get install -y clamav clamav-daemon 2>/dev/null || true
  systemctl enable --now clamav-freshclam 2>/dev/null || true
  timeout 300 freshclam 2>/dev/null || true
  systemctl restart clamav-daemon 2>/dev/null || true
  echo ":: STEP harden:antivirus done active ts=$(date +%s)"
else
  echo ":: STEP harden:antivirus skip opt-in ts=$(date +%s)"
fi
#
# ─── SELinux tools (Strictly Gated Opt-In: SELINUX_TOOLS=yes) ───
if [ "${SELINUX_TOOLS:-no}" = "yes" ]; then
  apt-get install -y policycoreutils selinux-utils selinux-basics 2>/dev/null || true
  echo ":: STEP harden:selinux done installed ts=$(date +%s)"
else
  echo ":: STEP harden:selinux skip opt-in ts=$(date +%s)"
fi
#
# ═══ VERIFY (pipeline checks: CHECK lines → deploy log) ═══
echo "--- VERIFY ---"
for _u in $_SUDO_ADMINS; do
  if id "$_u" >/dev/null 2>&1; then echo "CHECK user $_u: PASS"; else echo "CHECK user $_u: FAIL"; fi
done
if [ -n "$NTP1" ]; then
  if chronyc tracking >/dev/null 2>&1; then echo "CHECK chrony: PASS"; else echo "CHECK chrony: FAIL"; fi
fi
if [ "$FIREWALL" = "ufw" ]; then
  if ufw status 2>/dev/null | grep -q "Status: active"; then echo "CHECK firewall: PASS"; else echo "CHECK firewall: FAIL"; fi
else
  if command -v firewall-cmd >/dev/null 2>&1; then echo "CHECK firewall ports: $(firewall-cmd --list-ports 2>/dev/null | tr ' ' ',')"; else echo "CHECK firewall: SKIP (no binary)"; fi
fi
echo "CHECK timezone: $(cat /etc/timezone 2>/dev/null || date +%Z)"
echo "CHECK ntp-sources: $(chronyc sources 2>/dev/null | grep -c '^\^\*' || echo 0)"
if [ -f /usr/local/bin/node_exporter ]; then
  if systemctl is-active --quiet node_exporter 2>/dev/null; then echo "CHECK node_exporter: PASS"; else echo "CHECK node_exporter: FAIL"; fi
else
  echo "CHECK node_exporter: SKIP (no binary)"
fi
if sshd -t 2>/dev/null; then echo "CHECK sshd: PASS"; else echo "CHECK sshd: FAIL"; fi
echo "CHECK ssh-port: $SSH_PORT"
echo "CHECK auth-mode: $(grep -Ei '^(PasswordAuthentication|PubkeyAuthentication)' /etc/ssh/sshd_config.d/* /etc/ssh/sshd_config 2>/dev/null | tail -2 | tr '\n' ' ')"
if [ -n "$ROOT_PASSWORD" ]; then
  echo "CHECK root-password: PASS (set)"
else
  echo "CHECK root-password: PASS (untouched)"
fi
if [ "$SYSCTL_HARDENING" = "true" ]; then
  if [ -f /etc/sysctl.d/99-vmpilot-hardening.conf ]; then echo "CHECK sysctl-hardening: PASS"; else echo "CHECK sysctl-hardening: FAIL"; fi
else
  echo "CHECK sysctl-hardening: SKIP (disabled)"
fi
if [ "$AUDITD_ENABLED" = "true" ]; then
  if systemctl is-active --quiet auditd 2>/dev/null; then echo "CHECK auditd: PASS"; else echo "CHECK auditd: FAIL"; fi
else
  echo "CHECK auditd: SKIP (disabled)"
fi
if [ "${CLAMAV:-false}" = "true" ]; then
  if command -v clamscan >/dev/null 2>&1; then echo "CHECK clamav: PASS"; else echo "CHECK clamav: FAIL"; fi
else
  echo "CHECK clamav: SKIP (opt-in)"
fi
if [ "${SELINUX_TOOLS:-no}" = "yes" ]; then
  if command -v sestatus >/dev/null 2>&1 || command -v selinuxenabled >/dev/null 2>&1; then echo "CHECK selinux-tools: PASS"; else echo "CHECK selinux-tools: FAIL"; fi
else
  echo "CHECK selinux-tools: SKIP (opt-in)"
fi
if [ "$FAIL2BAN_ENABLED" = "true" ]; then
  if systemctl is-active --quiet fail2ban 2>/dev/null; then echo "CHECK fail2ban: PASS"; else echo "CHECK fail2ban: FAIL"; fi
else
  echo "CHECK fail2ban: SKIP (disabled)"
fi
if [ "$SUDO_COMMAND_LOG" = "true" ]; then
  if [ -f /etc/sudoers.d/90-vmpilot-audit ]; then echo "CHECK sudo-audit: PASS"; else echo "CHECK sudo-audit: FAIL"; fi
else
  echo "CHECK sudo-audit: SKIP (disabled)"
fi
echo "CHECK network-isolation: egress=${OUTBOUND_ISOLATION} icmp=${ICMP_PING_ALLOW}"
_locked_checked=0
for _lku in $LOCKED_USERS; do
  if passwd -S "$_lku" 2>/dev/null | grep -qE " L "; then
    _locked_checked=$((_locked_checked+1))
  fi
done
echo "CHECK locked-users: ${_locked_checked} locked"
echo ":: STEP harden:verify done ts=$(date +%s)"
