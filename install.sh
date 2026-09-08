#!/usr/bin/env bash
# Diagnose and fix RAPL thermal runaway on Intel laptops that ship with an
# effectively-unlimited PL1 (seen across the Dell Precision 7xxx line).
#
#   sudo ./install.sh                 diagnose, then install with a safe default
#   sudo ./install.sh --autotune      measure YOUR machine, pick its own optimum
#   sudo ./install.sh --pl1 50 --pl2 65 --tau 8    apply specific values
#   sudo ./install.sh --diagnose      report only, change nothing
set -euo pipefail

R=/sys/class/powercap/intel-rapl:0
MODE=install; PL1=""; PL2=""; TAU=""
TAU_DEFAULT=8
TARGET_STEADY=85   # degC ceiling for autotune steady state
TARGET_PEAK=96     # degC ceiling for autotune peak

while [ $# -gt 0 ]; do
  case "$1" in
    --autotune) MODE=autotune ;;
    --diagnose) MODE=diagnose ;;
    --pl1) PL1="$2"; shift ;;
    --pl2) PL2="$2"; shift ;;
    --tau) TAU="$2"; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

[ "$MODE" = diagnose ] || [ "$EUID" -eq 0 ] || { echo "run with sudo (or --diagnose, which needs no root)" >&2; exit 1; }
[ -d "$R" ] || { echo "No intel-rapl powercap zone. Intel CPU with RAPL required." >&2; exit 1; }
[ "$(cat $R/constraint_0_name)" = "long_term" ] || {
  echo "constraint_0 is not long_term on this system; refusing to write blindly." >&2; exit 1; }

w()   { echo $(( $(cat "$R/constraint_${1}_power_limit_uw") / 1000000 )); }
tau() { echo $(( $(cat "$R/constraint_${1}_time_window_us") / 1000000 )); }
pkg() { awk '{print int($1/1000)}' /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input 2>/dev/null | head -1; }

CPU=$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')
STOCK_PL1=$(w 0); STOCK_PL2=$(w 1); STOCK_TAU=$(tau 0)

# If we already installed, the live values are ours, not the firmware's.
INSTALLED=0
PRIOR=""; PRIOR_STOCK=""; PRIOR_PL1=""; PRIOR_PL2=""; PRIOR_TAU=""
if [ -f /etc/default/cpu-powercap ]; then
  INSTALLED=1
  PRIOR=$(sed -n "s/^# Tuned //p" /etc/default/cpu-powercap | head -1)
  # Keep the ORIGINAL firmware-stock description. STOCK_PL1/PL2/TAU above are
  # read from live sysfs, which after an install are OUR values -- regenerating
  # the header from them overwrites the only record of what the machine
  # shipped with (here: PL1=200W tau=56s) with the capped values.
  PRIOR_STOCK=$(sed -n 's/^# Tuned .*Firmware stock was \(.*\)\.$/\1/p' \
                /etc/default/cpu-powercap | head -1)
  # Keep the tuned values too, so a bare re-run re-applies what is configured
  # instead of falling through to the conservative first-install default.
  PRIOR_PL1=$(sed -n 's/^PL1_W=//p'     /etc/default/cpu-powercap | head -1)
  PRIOR_PL2=$(sed -n 's/^PL2_W=//p'     /etc/default/cpu-powercap | head -1)
  PRIOR_TAU=$(sed -n 's/^PL1_TAU_S=//p' /etc/default/cpu-powercap | head -1)
fi
# Explicit --tau wins, then whatever is already configured, then the default.
TAU=${TAU:-${PRIOR_TAU:-$TAU_DEFAULT}}

echo "=============================================================="
echo " CPU            : $CPU"
echo " Current PL1    : ${STOCK_PL1} W   (window ${STOCK_TAU}s)"
echo " Current PL2    : ${STOCK_PL2} W"
echo " Idle pkg temp  : $(pkg) C"
echo "=============================================================="
if [ "$INSTALLED" = 1 ]; then
  echo "NOTE: this fix is already installed (${PRIOR:-date unknown})."
  echo "      The values above are ITS values, not your firmware defaults."
  echo "      Firmware stock is recorded in /etc/default/cpu-powercap."
  grep "^# Tuned" /etc/default/cpu-powercap 2>/dev/null | sed "s/^/      /"
  echo
fi

# --- defect heuristic -------------------------------------------------------
# Mobile Intel parts are 15-65 W. A PL1 far above that is not a tuning choice,
# it is the absence of a sustained limit.
if [ "$STOCK_PL1" -ge 100 ]; then
  echo "!! PL1 of ${STOCK_PL1} W means there is effectively NO sustained power limit."
  echo "   Under load the CPU will run to TjMax and throttle. This is the defect."
  DEFECT=1
elif [ "$STOCK_TAU" -ge 30 ]; then
  echo "!! PL1 window of ${STOCK_TAU}s is very long: the CPU can sit near PL2 for"
  echo "   most of a minute before the rolling average reins it in."
  DEFECT=1
else
  if [ "$INSTALLED" = 1 ]; then
    echo "PL1 is sane because this fix is applied. Nothing to do."
  else
    echo "PL1 looks sane. You may not need this fix."
  fi
  DEFECT=0
fi
[ "$MODE" = diagnose ] && exit 0

# --- autotune ---------------------------------------------------------------
if [ "$MODE" = autotune ]; then
  command -v stress-ng >/dev/null || { echo "autotune needs stress-ng: apt install stress-ng" >&2; exit 1; }
  NPROC=$(nproc)
  echo
  echo "Autotune: testing candidate PL1 values against steady<=${TARGET_STEADY}C peak<=${TARGET_PEAK}C"
  echo "This takes ~5 minutes per candidate. Ctrl-C is safe."
  BEST=""
  for CAND in 35 40 45 50 55 60 65; do
    echo $((CAND*1000000))      > $R/constraint_0_power_limit_uw
    echo $((TAU*1000000))       > $R/constraint_0_time_window_us
    echo $(((CAND+15)*1000000)) > $R/constraint_1_power_limit_uw
    # cool to a common baseline so runs are comparable
    for _ in $(seq 30); do [ "$(pkg)" -le 64 ] && break; sleep 10; done
    sleep 15
    stress-ng --cpu "$NPROC" --cpu-method matrixprod --timeout 120s --quiet &
    SP=$!; MAX=0; SUM=0; N=0
    for i in $(seq 24); do
      sleep 5; T=$(pkg); [ "$T" -gt "$MAX" ] && MAX=$T
      [ "$i" -ge 14 ] && { SUM=$((SUM+T)); N=$((N+1)); }
      [ "$T" -ge 100 ] && { kill $SP 2>/dev/null; pkill -f stress-ng; break; }
    done
    wait $SP 2>/dev/null || true; pkill -f stress-ng 2>/dev/null || true
    STEADY=$(( N > 0 ? SUM/N : 999 ))
    printf "  PL1=%2dW -> steady %3dC  peak %3dC" "$CAND" "$STEADY" "$MAX"
    if [ "$STEADY" -le "$TARGET_STEADY" ] && [ "$MAX" -le "$TARGET_PEAK" ]; then
      echo "  PASS"; BEST=$CAND
    else
      echo "  FAIL - stopping here"; break
    fi
  done
  [ -n "$BEST" ] || { echo "No candidate passed. Your cooling may need service."; exit 1; }
  PL1=$BEST; PL2=$((BEST+15))
  echo
  echo "Autotune result: PL1=${PL1}W PL2=${PL2}W tau=${TAU}s"
fi

# --- defaults ---------------------------------------------------------------
if [ -z "$PL1" ]; then
  if [ -n "$PRIOR_PL1" ]; then
    # Already tuned and no values given: re-apply what is configured. The old
    # code fell straight through to the 45W first-install default, so a bare
    # `sudo ./install.sh` on a tuned machine silently retuned it DOWN from its
    # measured optimum and reported that as a fresh install.
    PL1=$PRIOR_PL1; PL2=${PRIOR_PL2:-$((PRIOR_PL1 + 15))}
    echo
    echo "Already tuned; re-applying the configured PL1=${PL1}W PL2=${PL2}W tau=${TAU}s."
    echo "Pass --pl1/--pl2/--tau or --autotune to change them."
  else
    # 45 W is at/below cTDP-up for essentially every Intel H-series mobile part,
    # so it is a safe floor when we have not measured this specific chassis.
    PL1=45; PL2=65
    echo
    echo "No --pl1 given; using conservative default PL1=${PL1}W PL2=${PL2}W."
    echo "Run with --autotune to find this machine's actual optimum."
  fi
fi

# --pl1 without --pl2 used to leave PL2 empty: the PL2 default lived inside the
# `if [ -z "$PL1" ]` branch, so supplying one flag skipped it. That wrote
# PL2_W= to the config and cpu-powercap-apply then evaluated $(( * 1000000)),
# a syntax error -- leaving the machine with NO cap at all.
[ -n "$PL2" ] || PL2=$(( PL1 + 15 ))

# --- thermald ---------------------------------------------------------------
# thermald reads the vendor DPTF tables and re-asserts PL1 from them a few
# seconds into boot. That can land AFTER our unit runs, silently reverting the
# cap - the fix then appears installed but does nothing after a reboot.
if systemctl is-enabled thermald >/dev/null 2>&1; then
  echo
  echo "thermald is enabled. It re-applies the firmware PL1 during boot and will"
  echo "silently undo this fix. Disabling it (hardware PROCHOT at TjMax and the"
  echo "kernel thermal governors still protect the CPU; this static cap is stricter"
  echo "than what thermald was enforcing)."
  systemctl disable --now thermald || true
  echo "  thermald: $(systemctl is-enabled thermald 2>&1)"
fi

# --- install ----------------------------------------------------------------
install -m 0755 "$(dirname "$0")/cpu-powercap-apply" /usr/local/bin/cpu-powercap-apply
# The tuning date is today's, but the stock description is written once, on
# a true first install, when the live values really are the firmware's.
STOCK_DESC=${PRIOR_STOCK:-PL1=${STOCK_PL1}W tau=${STOCK_TAU}s PL2=${STOCK_PL2}W}
cat > /etc/default/cpu-powercap <<EOF
# Tuned $(date -u +%Y-%m-%d). Firmware stock was ${STOCK_DESC}.
PL1_W=${PL1}
PL2_W=${PL2}
PL1_TAU_S=${TAU}
EOF
install -m 0644 "$(dirname "$0")/cpu-powercap.service" /etc/systemd/system/cpu-powercap.service

# Watchdog: some embedded controllers reset RAPL limits at runtime, which would
# silently undo the fix. Re-assert every 2 minutes.
cat > /etc/systemd/system/cpu-powercap-watchdog.service <<'EOF'
[Unit]
Description=Re-assert CPU RAPL power cap (guards against EC resets)
[Service]
Type=oneshot
EnvironmentFile=/etc/default/cpu-powercap
ExecStart=/usr/local/bin/cpu-powercap-apply
EOF
cat > /etc/systemd/system/cpu-powercap-watchdog.timer <<'EOF'
[Unit]
Description=Periodically re-assert CPU RAPL power cap
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=1s
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl reenable cpu-powercap.service >/dev/null 2>&1
systemctl restart cpu-powercap.service
systemctl enable --now cpu-powercap-watchdog.timer >/dev/null 2>&1

echo
echo "Installed. Now: PL1=$(w 0)W tau=$(tau 0)s PL2=$(w 1)W"
echo "Re-applies on boot, on resume from suspend, and every 2 min (EC-reset guard)."
echo "Undo with: sudo ./uninstall.sh"
