#!/bin/bash
# burst-crossover.sh -- at what burst length does PL1 start to matter?
#
#   sudo COOLER_RPM=1400 bash burst-crossover.sh
#
# The 10s burst test showed +13.5% work at 65W over 50W, falsifying the idea
# that bursts stay inside the PL2 window. But PL1's window (tau) is 8s, so a
# 10s burst runs its tail under PL1 by construction. Real agent tasks -- a
# grep, a file read, a short test -- are 1-3s and SHOULD sit entirely inside
# the boost window, where PL1 cannot apply. This finds the crossover.
#
# Fixed WORK, measured TIME. The previous test used fixed time, which at 1s
# would be dominated by stress-ng's own startup: spawning 16 workers is a
# meaningful fraction of a one-second burst. Holding ops constant and timing
# the run keeps that overhead identical across conditions instead of letting
# it scale with the thing being measured.
set -u
R=/sys/class/powercap/intel-rapl:0
RM=/sys/class/powercap/intel-rapl-mmio:0
HERE=$(cd "$(dirname "$0")" && pwd)
OUTD=$HERE/results; OUT=$OUTD/burst-crossover.tsv; PROG=$OUTD/progress.log
RPM=${COOLER_RPM:?set COOLER_RPM to the cooler setting you dialled in}
NPROC=$(nproc)
REPS=${REPS:-8}
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
mkdir -p "$OUTD"

LOCK=/run/experiment-dynamic.lock
exec 9>"$LOCK" || exit 1
flock -n 9 || { echo "REFUSING: another experiment holds the lock" >&2; exit 3; }
pgrep -x stress-ng >/dev/null && { echo "REFUSING: stress-ng already running" >&2; exit 3; }

say() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$PROG"; }
pkg() { awk '{print int($1/1000)}' /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input 2>/dev/null | head -1; }

cleanup() {
  say "RESTORING"
  systemctl start cpu-powercap-watchdog.timer 2>/dev/null
  systemctl restart cpu-powercap.service 2>/dev/null
  systemctl start ${PAUSE_TIMER:-} 2>/dev/null
  pkill -x stress-ng 2>/dev/null
  say "restored: MSR=$(( $(cat $R/constraint_0_power_limit_uw)/1000000 ))W MMIO=$(( $(cat $RM/constraint_0_power_limit_uw)/1000000 ))W"
}
on_signal() { say "signal, aborting"; cleanup; trap - EXIT; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM HUP QUIT

systemctl stop ${PAUSE_TIMER:-} cpu-powercap-watchdog.timer 2>/dev/null
say "BURST CROSSOVER: cooler ${RPM} RPM, ${REPS} reps per cell"

set_pl() {
  local p1=$1 d got
  systemctl stop cpu-powercap-watchdog.timer 2>/dev/null
  for d in "$R" "$RM"; do
    [ "$(cat "$d/enabled" 2>/dev/null)" = "1" ] || continue
    echo $(( p1 * 1000000 ))      > "$d/constraint_0_power_limit_uw"
    echo 8000000                  > "$d/constraint_0_time_window_us" 2>/dev/null || true
    echo $(( (p1+15) * 1000000 )) > "$d/constraint_1_power_limit_uw" 2>/dev/null || true
    got=$(( $(cat "$d/constraint_0_power_limit_uw")/1000000 ))
    [ "$got" = "$p1" ] || { say "FATAL: $d asked ${p1}W reads ${got}W"; exit 1; }
  done
}
cooldown() { local w=0; while [ $w -lt 240 ]; do [ "$(pkg)" -le 60 ] && break; sleep 5; w=$((w+5)); done; sleep 10; }

printf 'cooler_rpm\tpl1_w\tops_per_worker\trep\telapsed_ms\tpeakC\n' > "$OUT"

# Calibrated on this machine at 50W: ~65ms per 1000 ops/worker (5000->325ms,
# 20000->1301ms, 80000->5189ms, linear). These target 1,2,3,5,10 seconds.
# The first version guessed ~940 ops/worker/s from the 180s runs' reported
# bogo-ops rate -- a different unit -- and was wrong by 15x, so every 'burst'
# ran 0.25-0.8s instead of 1-9s.
for PL in 50 65; do
  for OPS in 15000 31000 46000 77000 154000; do
    set_pl "$PL"
    say "PL1=${PL}W ops=${OPS}/worker -- cooling"
    cooldown
    for rep in $(seq 1 "$REPS"); do
      # Sample temperature in a SEPARATE process. v1 polled inside the timing
      # loop with sleep 0.25, which quantized every measurement to 250ms --
      # 48 of 80 samples came back as exactly 256ms. Never put the instrument
      # in the path of the thing it measures.
      TF=$(mktemp)
      ( while :; do pkg >> "$TF"; sleep 0.2; done ) & SAMP=$!
      T0=$(date +%s%N)
      stress-ng --cpu "$NPROC" --cpu-method matrixprod --cpu-ops "$OPS" --quiet >/dev/null 2>&1
      T1=$(date +%s%N)
      kill $SAMP 2>/dev/null; wait $SAMP 2>/dev/null
      MAXT=$(sort -n "$TF" 2>/dev/null | tail -1); MAXT=${MAXT:-0}
      rm -f "$TF"
      MS=$(( (T1 - T0) / 1000000 ))
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$RPM" "$PL" "$OPS" "$rep" "$MS" "$MAXT" >> "$OUT"
      sleep 12
    done
    say "  PL1=${PL}W ops=${OPS}: median $(awk -F'\t' -v p="$PL" -v o="$OPS" '$2==p && $3==o {print $5}' "$OUT" | sort -n | awk '{a[NR]=$1} END{print a[int(NR/2)+1]}')ms"
  done
done
say "BURST CROSSOVER COMPLETE"
