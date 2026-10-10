#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# hardening.sh — DATACENTER baseline = enterprise doc, direct translation:
# docs/headrning_doc/hardening-pipeline.md
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
FIREWALL="firewalld"        # "firewalld" or "ufw"
PORTS="80 443 8080 8443 6379 6160 6162 6163 10808 15672 9100"  # ssh/22 always kept
NTP1="pool.ntp.org"
NTP2=""
TIMEZONE=""
COMMON_USERS=""
ROOT_PASSWORD=""            # empty = untouched (plaintext risk if set!)
ADMIN_PASSWORD=""           # empty = SSH-key only; set = all common users + force-change
SSH_PORT="22"               # custom port auto-opens in firewall (22 stays as fallback)
ROOT_LOGIN="yes"            # PermitRootLogin yes/no (doc Phase 7)
NE_REPO="https://repo.internal:8443/repository/node_exp"   # internal repo base (set yours)
NE_VERSION="1.12.1"         # must match the tarball in the repo above
CLAMAV="false"              # "true" = file/mail servers only
#
# ─── Phase 3: User Provisioning ───
PASS="$ADMIN_PASSWORD"
for u in $COMMON_USERS; do
  if ! id "$u" &>/dev/null; then
    useradd -m -s /bin/bash "$u"
    mkdir -p /home/$_u/.ssh && chmod 700 /home/$_u/.ssh
    grep -qF "$VMPILOT_SSH_KEY" \
    /home/$_u/.ssh/authorized_keys 2>/dev/null || \
    echo "$VMPILOT_SSH_KEY" >> /home/$_u/.ssh/authorized_keys || true
    chmod 600 /home/$_u/.ssh/authorized_keys || true
    chown -R $_u:$_u /home/$_u/.ssh || true
    if [ -n "$PASS" ]; then
      echo "$u:$PASS" | chpasswd
      chage -d 0 "$u"
    fi
    usermod -aG sudo "$u"
    echo "$_u ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-vmpilot-$_u || true
    chmod 440 /etc/sudoers.d/90-vmpilot-$_u 2>/dev/null || true
  visudo -c -q -f /etc/sudoers.d/90-vmpilot-$_u 2>/dev/null || rm -f /etc/sudoers.d/90-vmpilot-$_u
    echo "Created: $u"
  else
    echo "User already exists: $u"
  fi
done
# Verify users:
for u in $COMMON_USERS; do
  echo "----- $u -----"
  id "$u"
  groups "$u"
done
# Verify home directories:
ls -ld /home/*
#
# ─── Phase 5: Essential Administration Tools ───
apt update
apt install -y network-manager plocate sysstat traceroute net-tools htop curl wget vim
apt install -y \
network-manager \
chrony \
plocate \
sysstat \
traceroute \
net-tools \
htop \
curl \
wget \
vim \
bash-completion \
rsync \
auditd \
zip \
unzip \
lsof \
tcpdump \
ncdu \
firewalld \
fail2ban
#
# --- Root password (doc Phase 1; empty = untouched) ---
if [ -n "$ROOT_PASSWORD" ]; then
  echo "root:$ROOT_PASSWORD" | chpasswd 2>/dev/null || true
fi
#
# ─── Phase 4: Time Synchronization (Chrony) ───
systemctl enable --now chrony
if [ -n "$NTP1" ]; then
  echo "server $NTP1 iburst" > /etc/chrony/conf.d/vmpilot.conf
  if [ -n "$NTP2" ]; then
    echo "server $NTP2 iburst" >> /etc/chrony/conf.d/vmpilot.conf
  fi
fi
if [ -n "$TIMEZONE" ]; then
  timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true
fi
systemctl restart chrony
chronyc reload sources
# Verify:
timedatectl
chronyc tracking
chronyc sources -v
#
# ─── Phase 6: Firewall Hardening ───
systemctl enable --now firewalld
# Allow essential services:
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --remove-service=dhcpv6-client
# Custom application ports (from $PORTS above):
for _p in $PORTS; do
  firewall-cmd --permanent --add-port=$_p/tcp 2>/dev/null || true
done
if [ "$SSH_PORT" != "22" ]; then
  firewall-cmd --permanent --add-port=$SSH_PORT/tcp 2>/dev/null || true
fi
firewall-cmd --reload
# Verify:
firewall-cmd --list-all
#
# ─── node_exporter (system user + service file) ───
# Source = $NE_REPO + $NE_VERSION from SECTION 0 (internal server).
cd /tmp &&
curl -k -fL -o node_exporter.tar.gz "$NE_REPO/node_exporter-$NE_VERSION.linux-amd64.tar.gz" &&
useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter 2>/dev/null || true
tar -xzf node_exporter.tar.gz -C /tmp/
install -o node_exporter -g node_exporter -m 0755 \
  "/tmp/node_exporter-$NE_VERSION.linux-amd64/node_exporter" \
  /usr/local/bin/node_exporter
rm -rf "/tmp/node_exporter-$NE_VERSION.linux-amd64" /tmp/node_exporter.tar.gz
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
systemctl daemon-reload &&
systemctl enable --now node_exporter
systemctl is-active --quiet node_exporter && echo "Node Exporter installed successfully."
#
# ─── Phase 7: SSH Hardening ───
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
{
  echo "Port $SSH_PORT"
  echo "PermitRootLogin $ROOT_LOGIN"
  echo 'PasswordAuthentication yes'
  echo 'X11Forwarding no'
} > /etc/ssh/sshd_config.d/99-vmpilot-doc.conf
# Validate:
sshd -t
# Restart:
systemctl restart ssh
# Verify:
systemctl status ssh --no-pager | head -3
#
# ─── Phase 8: Fail2Ban ───
systemctl enable --now fail2ban
# Verify:
fail2ban-client status
#
# ─── Phase 9: Antivirus (file/samba/mail/upload servers) ───
apt install -y clamav clamav-daemon
systemctl enable --now clamav-freshclam
freshclam
# Verify:
systemctl status clamav-freshclam --no-pager | head -3
clamscan --version
#
# ─── SELinux tools ───
apt install -y policycoreutils selinux-utils selinux-basics
#
# ═══ VERIFY (pipeline checks: CHECK lines → deploy log) ═══
echo "--- VERIFY ---"
for _u in $COMMON_USERS; do
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
if [ -f /usr/local/bin/node_exporter ]; then
  if systemctl is-active --quiet node_exporter 2>/dev/null; then echo "CHECK node_exporter: PASS"; else echo "CHECK node_exporter: FAIL"; fi
else
  echo "CHECK node_exporter: SKIP (no binary)"
fi
if sshd -t 2>/dev/null; then echo "CHECK sshd: PASS"; else echo "CHECK sshd: FAIL"; fi
if systemctl is-active --quiet fail2ban 2>/dev/null; then echo "CHECK fail2ban: PASS"; else echo "CHECK fail2ban: FAIL"; fi
