#!/bin/bash
# airflow-point.sh -- two PL1 points at one cooler setting. ~14 min.
#   sudo COOLER_RPM=2000 bash airflow-point.sh
# Adds rows to results/airflow-ladder.tsv so settings can be compared directly.
set -u
R=/sys/class/powercap/intel-rapl:0
RM=/sys/class/powercap/intel-rapl-mmio:0
HERE=$(cd "$(dirname "$0")" && pwd)
OUTD=$HERE/results; LOGD=$OUTD/raw-airflow; OUT=$OUTD/airflow-ladder.tsv
PROG=$OUTD/progress.log
RPM=${COOLER_RPM:?set COOLER_RPM to the cooler setting you dialled in}
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
mkdir -p "$LOGD"

LOCK=/run/experiment-sweep.lock
exec 9>"$LOCK" || exit 1
flock -n 9 || { echo "REFUSING: another experiment holds the lock" >&2; exit 3; }
pgrep -x stress-ng >/dev/null && { echo "REFUSING: stress-ng already running" >&2; exit 3; }

say() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$PROG"; }
pkg() { awk '{print int($1/1000)}' /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input 2>/dev/null | head -1; }
thr() { cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms; }

cleanup() {
  say "RESTORING"
  systemctl start cpu-powercap-watchdog.timer 2>/dev/null
  systemctl restart cpu-powercap.service 2>/dev/null
  systemctl start ${PAUSE_TIMER:-} 2>/dev/null
  pkill -x stress-ng 2>/dev/null; systemctl stop rapl-sample.service 2>/dev/null
  say "restored: MSR=$(( $(cat $R/constraint_0_power_limit_uw)/1000000 ))W MMIO=$(( $(cat $RM/constraint_0_power_limit_uw)/1000000 ))W"
}
on_signal() { say "signal, aborting"; cleanup; trap - EXIT; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM HUP QUIT

systemctl stop ${PAUSE_TIMER:-} cpu-powercap-watchdog.timer 2>/dev/null
say "AIRFLOW POINT: cooler ${RPM} RPM"

set_pl() {
  local p1=$1 d got
  systemctl stop cpu-powercap-watchdog.timer 2>/dev/null
  for d in "$R" "$RM"; do
    [ "$(cat "$d/enabled" 2>/dev/null)" = "1" ] || continue
    echo $(( p1 * 1000000 ))       > "$d/constraint_0_power_limit_uw"
    echo 8000000                   > "$d/constraint_0_time_window_us" 2>/dev/null || true
    echo $(( (p1+15) * 1000000 ))  > "$d/constraint_1_power_limit_uw" 2>/dev/null || true
    got=$(( $(cat "$d/constraint_0_power_limit_uw")/1000000 ))
    [ "$got" = "$p1" ] || { say "FATAL: $d asked ${p1}W reads ${got}W"; exit 1; }
  done
}
cooldown() { local w=0; while [ $w -lt 300 ]; do [ "$(pkg)" -le 64 ] && break; sleep 10; w=$((w+10)); done; sleep 20; pkg; }

[ -f "$OUT" ] || printf 'cooler_rpm\tpl1_w\trep\tambientC\tbogo_per_s\tsteadyC\tmaxC\tsteadyW\tthrottle_ms\n' > "$OUT"
RUN=0
for spec in 50:1 65:1 65:2 50:2; do
  PL=${spec%%:*}; REP=${spec##*:}; RUN=$((RUN+1))
  set_pl "$PL"; say "rpm=$RPM PL1=${PL}W rep=$REP -- cooling"
  AMB=$(cooldown); T0=$(thr)
  systemctl start rapl-sample.service; sleep 1
  stress-ng --cpu "$(nproc)" --cpu-method matrixprod --timeout 180s --metrics-brief \
      > "$LOGD/r${RPM}_pl${PL}_${REP}.txt" 2>&1 &
  SP=$!; MAXT=0; HOT=0
  for i in $(seq 1 37); do
    sleep 5; T=$(pkg); [ "${T:-0}" -gt "$MAXT" ] && MAXT=$T
    [ "${T:-0}" -ge 104 ] && { HOT=$((HOT+1)); [ $HOT -ge 2 ] && { kill $SP 2>/dev/null; pkill -x stress-ng; break; }; } || HOT=0
    kill -0 $SP 2>/dev/null || break
  done
  wait $SP 2>/dev/null; systemctl stop rapl-sample.service; T1=$(thr)
  cp /tmp/rapl.log "$LOGD/rapl_r${RPM}_pl${PL}_${REP}.log" 2>/dev/null
  BPS=$(awk '/ cpu /{print $9}' "$LOGD/r${RPM}_pl${PL}_${REP}.txt" | head -1)
  L="$LOGD/rapl_r${RPM}_pl${PL}_${REP}.log"
  SC=$(tail -30 "$L" 2>/dev/null | awk '{s+=$3;n++} END{if(n)printf "%.1f",s/n}')
  SW=$(tail -30 "$L" 2>/dev/null | awk '{s+=$2;n++} END{if(n)printf "%.1f",s/n}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$RPM" "$PL" "$REP" "$AMB" "${BPS:-NA}" "${SC:-NA}" "$MAXT" "${SW:-NA}" "$((T1-T0))" >> "$OUT"
  say "  -> steady=${SC:-NA}C max=${MAXT}C work=${BPS:-NA}/s throttle=$((T1-T0))ms"
done
say "AIRFLOW POINT COMPLETE (${RPM} RPM)"
