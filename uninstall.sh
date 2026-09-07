#!/usr/bin/env bash
# Removes the power cap and restores firmware defaults (takes effect after reboot).
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "run with sudo"; exit 1; }
systemctl disable --now cpu-powercap.service 2>/dev/null || true
systemctl disable --now cpu-powercap-watchdog.timer 2>/dev/null || true
rm -f /etc/systemd/system/cpu-powercap.service \
      /etc/systemd/system/cpu-powercap-watchdog.service \
      /etc/systemd/system/cpu-powercap-watchdog.timer \
      /usr/local/bin/cpu-powercap-apply \
      /etc/default/cpu-powercap
systemctl daemon-reload
echo "Removed. Firmware defaults return after a reboot."
