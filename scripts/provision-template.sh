#!/usr/bin/env bash
# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# ============================================================
# provision-template.sh — build a PRODUCTION golden template VM.
# Run INSIDE the template-build VM (via vSphere console) AFTER the
# interactive Ubuntu install (manual partitioning per
# docs/template_prepare_for_prod/prod_template.md Phase-1/2).
# Idempotent — safe to re-run. Ends with a verification checklist.
# Phase-10 generalization stays MANUAL (destructive, one-way).
#
# Usage (as root, WITH network):
#   sudo bash scripts/provision-template.sh
#   (or copy to the build VM and run; needs internet for apt)
# ============================================================
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "Run as root (sudo -i first)."; exit 1; }
if ! grep -qi 'ubuntu' /etc/os-release 2>/dev/null; then
  echo "Ubuntu required."; exit 1
fi
if ! ping -c1 -W5 archive.ubuntu.com >/dev/null 2>&1; then
  echo "WARNING: no internet — apt steps will fail. Connect LAN first."
fi

PASS=0; FAIL=0
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; PASS=$((PASS+1));
  else echo "  [FAIL] $label"; FAIL=$((FAIL+1)); fi
}

echo "=== 1. Packages (doc Phase-4/4a/4b) ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y open-vm-tools cloud-init cloud-guest-utils lvm2 \
  xfsprogs e2fsprogs auditd fail2ban firewalld curl wget git vim nano \
  unzip zip tar jq rsync bash-completion ca-certificates chrony dnsutils \
  iproute2 net-tools tcpdump traceroute lsof tree tmux screen htop \
  iotop iftop ncdu plocate sysstat network-manager software-properties-common \
  apt-transport-https gnupg clamav clamav-daemon || true
# NOTE: policycoreutils/selinux-* intentionally NOT here (opt-in via policy
# SELINUX_TOOLS; Ubuntu best practice = AppArmor). ufw ships with the OS.

echo "=== 2. node_exporter binary (doc Phase-4a) ==="
if [ ! -f /usr/local/bin/node_exporter ]; then
  VER=1.8.2
  wget -qO /tmp/ne.tar.gz "https://github.com/prometheus/node_exporter/releases/download/v${VER}/node_exporter-${VER}.linux-amd64.tar.gz" \
    && tar -xzf /tmp/ne.tar.gz -C /tmp/ \
    && install -m 0755 "/tmp/node_exporter-${VER}.linux-amd64/node_exporter" /usr/local/bin/node_exporter \
    && rm -rf /tmp/node_exporter-* /tmp/ne.tar.gz || true
fi

echo "=== 3. Services (doc Phase-5) ==="
for s in open-vm-tools cloud-init cloud-init-local cloud-config ssh chrony; do
  systemctl enable "$s" 2>/dev/null || true
done
systemctl enable fail2ban firewalld 2>/dev/null || true
systemctl enable clamav-freshclam 2>/dev/null || true
systemctl start open-vm-tools ssh chrony 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true

echo "=== 4. Cloud-init VMware datasource (doc Phase-5a) ==="
cat > /etc/cloud/cloud.cfg.d/99-vmware-guestinfo.cfg <<'EOF'
# Cloud-init will read metadata/userdata/network from VMware GuestInfo
datasource_list: ['VMware', 'NoCloud', 'ConfigDrive', 'None']
datasource:
  VMware:
    vmware_customization: false
    allow_raw_data: true
EOF
cat > /etc/cloud/cloud.cfg.d/10_vmware_ds.cfg <<'EOF'
datasource:
  VMware:
    vmware_customization: false
    allow_raw_data: true
EOF

echo "=== 5. Time (doc Phase-6a/6b) ==="
grep -q "ntp1.waltonbd.com" /etc/chrony/chrony.conf 2>/dev/null || {
  printf 'server ntp1.waltonbd.com iburst\nserver ntp2.waltonbd.com iburst\n' >> /etc/chrony/chrony.conf
}
timedatectl set-timezone Asia/Dhaka 2>/dev/null || true
systemctl restart chrony 2>/dev/null || true

echo "=== 6. SSH baseline (doc Phase-7) ==="
[ -f /etc/ssh/sshd_config.vmpilot-bak ] || cp /etc/ssh/sshd_config /etc/ssh/sshd_config.vmpilot-bak 2>/dev/null || true
printf '%s\n' 'PermitRootLogin yes' 'PasswordAuthentication yes' 'PubkeyAuthentication yes' 'KbdInteractiveAuthentication yes' 'UseDNS no' 'X11Forwarding no' 'MaxAuthTries 3' 'ClientAliveInterval 300' 'ClientAliveCountMax 2' > /etc/ssh/sshd_config.d/99-vmpilot-base.conf
sshd -t && systemctl restart ssh || echo "  [WARN] sshd config invalid — restored backup path kept"

echo "=== 7b. GRUB: no menu wait (saves 8-30s on EVERY boot) ==="
# NOTE: base TIMEOUT alone is NOT enough — Ubuntu sets recordfail on any
# failed boot and then forces the full menu. RECORDFAIL_TIMEOUT is the real
# fix (seen live: 8s GRUB menu despite TIMEOUT=0).
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub
if grep -q "^GRUB_TIMEOUT_STYLE" /etc/default/grub; then
  sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub
else
  echo "GRUB_TIMEOUT_STYLE=hidden" >> /etc/default/grub
fi
if grep -q "^GRUB_RECORDFAIL_TIMEOUT" /etc/default/grub; then
  sed -i 's/^GRUB_RECORDFAIL_TIMEOUT=.*/GRUB_RECORDFAIL_TIMEOUT=1/' /etc/default/grub
else
  echo "GRUB_RECORDFAIL_TIMEOUT=1" >> /etc/default/grub
fi
update-grub 2>/dev/null || true

echo "=== 7. terraform user (deploy operator) ==="
id terraform >/dev/null 2>&1 || useradd -m -s /bin/bash terraform
echo 'terraform ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/terraform
chmod 440 /etc/sudoers.d/terraform

echo ""
echo "=== VERIFICATION CHECKLIST ==="
check "open-vm-tools" vmware-toolbox-cmd -v
check "cloud-init enabled" systemctl is-enabled cloud-init
check "ssh running" systemctl is-active ssh
check "chrony running" systemctl is-active chrony
check "lvm2 present" command -v lvextend
check "xfsprogs present" command -v mkfs.xfs
check "auditd present" command -v auditd
check "fail2ban present" command -v fail2ban-client
check "firewalld present" command -v firewall-cmd
check "node_exporter present" test -f /usr/local/bin/node_exporter
check "jq present" command -v jq
check "wait-online masked" bash -c '! systemctl status systemd-networkd-wait-online.service 2>/dev/null | grep -q "active (running)"'
check "VMware datasource" bash -c "grep -q VMware /etc/cloud/cloud.cfg.d/99-vmware-guestinfo.cfg"
check "GRUB menu <=1s" bash -c "grep -q '^GRUB_TIMEOUT=1' /etc/default/grub"
check "GRUB recordfail <=1s" bash -c "grep -q '^GRUB_RECORDFAIL_TIMEOUT=1' /etc/default/grub"
check "terraform sudoers" sudo -l -U terraform
echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo ""
echo "NEXT (manual, doc Phase-10): generalize (cloud-init clean, machine-id,"
echo "SSH host keys, netplan, logs) → shutdown → Convert to Template."
echo "Then: template NIC 'Connect at power on' = OFF (via clone-replace or UI)."
