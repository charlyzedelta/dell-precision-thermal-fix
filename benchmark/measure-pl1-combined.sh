#!/bin/bash
# measure-pl1-combined.sh <watts> [seconds]
#
# Measure one PL1 value under COMBINED CPU+GPU load, then put the machine back.
#
#   sudo bash measure-pl1-combined.sh 55 420
#
# Why a wrapper rather than install.sh + gpu-thermal.sh:
#   * cpu-powercap-watchdog.timer re-asserts the CONFIGURED PL1 every 60s. It
#     silently invalidated three benchmark attempts on 2026-09-08. It is paused
#     here and restarted from the trap.
#   * /etc/default/cpu-powercap is never modified. The registers are set
#     directly, so restoring is just `systemctl restart cpu-powercap.service`,
#     which re-reads the unchanged config. No second sudo, nothing to forget.
#   * the restore runs from a trap on ANY exit, including the 95C abort and
#     Ctrl-C. A run that stops because it got too hot must not leave the cap
#     raised.
set -u
W=${1:?usage: measure-pl1-combined.sh <watts> [seconds]}
SECS=${2:-420}
ABORT_C=95
R=/sys/class/powercap/intel-rapl:0
RM=/sys/class/powercap/intel-rapl-mmio:0
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/results/combined-pl${W}.tsv
OLLAMA=${OLLAMA_HOST:-100.115.113.12:11434}
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
case "$W" in ''|*[!0-9]*) echo "watts must be an integer" >&2; exit 1 ;; esac
[ "$W" -ge 45 ] && [ "$W" -le 65 ] || { echo "refusing $W W: outside the measured 45-65W envelope" >&2; exit 1; }

LOCK=/run/experiment-dynamic.lock
exec 9>"$LOCK" || exit 1
flock -n 9 || { echo "REFUSING: another experiment holds the lock" >&2; exit 3; }
pgrep -x stress-ng >/dev/null && { echo "REFUSING: stress-ng already running" >&2; exit 3; }

pkg() { awk '{print int($1/1000)}' /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input 2>/dev/null | head -1; }
thr() { cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms; }

restore() {
  echo "restoring configured cap"
  pkill -x stress-ng 2>/dev/null
  kill %1 2>/dev/null
  systemctl restart cpu-powercap.service 2>/dev/null
  systemctl start cpu-powercap-watchdog.timer 2>/dev/null
  sleep 1
  echo "  now: MSR=$(( $(cat $R/constraint_0_power_limit_uw)/1000000 ))W MMIO=$(( $(cat $RM/constraint_0_power_limit_uw)/1000000 ))W  (config: PL1_W=$(sed -n 's/^PL1_W=//p' /etc/default/cpu-powercap))"
}
on_sig() { echo; echo "signal received"; restore; trap - EXIT; exit 130; }
trap restore EXIT
trap on_sig INT TERM HUP QUIT

systemctl stop cpu-powercap-watchdog.timer 2>/dev/null
for d in "$R" "$RM"; do
  [ "$(cat "$d/enabled" 2>/dev/null)" = 1 ] || continue
  echo $(( W * 1000000 ))          > "$d/constraint_0_power_limit_uw"
  echo 8000000                     > "$d/constraint_0_time_window_us" 2>/dev/null || true
  echo $(( (W + 15) * 1000000 ))   > "$d/constraint_1_power_limit_uw" 2>/dev/null || true
  got=$(( $(cat "$d/constraint_0_power_limit_uw")/1000000 ))
  [ "$got" = "$W" ] || { echo "FATAL: $d asked ${W}W reads ${got}W" >&2; exit 1; }
done
echo "PL1=${W}W PL2=$((W+15))W on both domains, watchdog paused, ${SECS}s, abort at ${ABORT_C}C"

# cool to a common baseline so this is comparable to the other runs
w=0; while [ $w -lt 240 ]; do [ "$(pkg)" -le 60 ] && break; sleep 5; w=$((w+5)); done; sleep 10
echo "baseline $(pkg)C"

( while :; do
    curl -s "http://$OLLAMA/api/generate" -d '{"model":"extract","prompt":"Write a detailed technical explanation of RAPL power limiting on Intel processors: PL1, PL2, the time window, and the MSR versus MMIO interfaces.","stream":false,"options":{"num_predict":400}}' >/dev/null 2>&1 || sleep 1
  done ) &
stress-ng --cpu "$(nproc)" --cpu-method matrixprod --timeout "${SECS}s" --quiet >/dev/null 2>&1 &

printf 't_s\tgpu_w\tgpu_c\tgpu_util\tcpu_c\tthrottle_delta_ms\n' > "$OUT"
T0=$(thr); start=$(date +%s); aborted=0
while :; do
  el=$(( $(date +%s) - start ))
  [ "$el" -ge "$SECS" ] && break
  IFS=', ' read -r gw gc gu <<< "$(nvidia-smi --query-gpu=power.draw,temperature.gpu,utilization.gpu --format=csv,noheader,nounits 2>/dev/null)"
  c=$(pkg)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$el" "${gw:-NA}" "${gc:-NA}" "${gu:-NA}" "${c:-NA}" "$(( $(thr) - T0 ))" >> "$OUT"
  if [ "${c:-0}" -ge "$ABORT_C" ]; then echo "ABORT at t=${el}s: package ${c}C >= ${ABORT_C}C"; aborted=1; break; fi
  sleep 10   # not 5s: tight nvidia-smi polling put this GPU into reset-required
done
T1=$(thr)
echo
echo "=== PL1=${W}W combined ==="
[ "$aborted" = 1 ] && echo "  ABORTED — did not hold" || echo "  completed ${SECS}s"
awk -F'\t' -v s="$SECS" 'NR>1 && $1>=120 {n++; g+=$2; c+=$5; if($5>mx)mx=$5}
END{if(n)printf "  late window (t>=120s, n=%d): gpu %.0fW  cpu mean %.1fC peak %dC\n",n,g/n,c/n,mx}' "$OUT"
awk -F'\t' 'NR>1{a[NR]=$5} END{printf "  first/last cpu sample: %sC -> %sC  (rising means no steady state)\n",a[2],a[NR]}' "$OUT"
echo "  throttle delta: $(( T1 - T0 ))ms"
