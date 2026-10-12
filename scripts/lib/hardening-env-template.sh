#!/usr/bin/env bash
# hardening.sh — ENV extras. Runs AFTER the DC baseline script (appended).
# Env-specific additions only: app ports, env users, env policy tweaks.
# Same rules: plain bash, NO apt, tolerate re-run, keep it fast.
#
# ─── ON/OFF SWITCH (WebUI SecureFile edits this one line) ───
ENABLED="true"              # "true" = this file runs · anything else = skipped
if [ "$ENABLED" != "true" ]; then
  echo "hardening: DISABLED by policy switch (ENABLED=$ENABLED) — skipping"
  exit 0
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
