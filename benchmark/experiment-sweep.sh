#!/bin/bash
# experiment-sweep.sh -- data for a DYNAMIC power controller, cooler attached.
#
# Differs from experiment.sh in three ways, all deliberate:
#   1. PL1 is swept as a single variable. experiment.sh moved PL2 with it
#      (B=PL1+15, C=PL1+25), so PL1 and PL2 were confounded; here PL2 is
#      always PL1+15 and tau is always 8s. 50/65 reproduces experiment.sh's
#      config B exactly, giving one anchor comparable to the pre-cooler table.
#   2. Phase 3 measures BURST behaviour. Agent workloads are bursty, and a
#      180s all-core run cannot tell us whether real work ever leaves the PL2
#      boost window -- if it does not, PL1 is the wrong lever and tau is the
#      right one.
#   3. It restores the tuned cap from a trap, on ANY exit. experiment.sh
#      restores only on normal completion, so an interrupt could leave the
#      machine parked at stock 200W indefinitely.
#
# Run as root:  sudo bash experiment-sweep.sh
set -u

R=/sys/class/powercap/intel-rapl:0
RM=/sys/class/powercap/intel-rapl-mmio:0
OUTD=$(cd "$(dirname "$0")" && pwd)/results
LOGD=$OUTD/raw-cooler
OUT=$OUTD/cooler-sweep.tsv
BURST=$OUTD/cooler-burst.tsv
PROG=$OUTD/progress.log
NPROC=$(nproc)

[ "$(id -u)" = 0 ] || { echo "run me as root: sudo bash $0" >&2; exit 1; }
mkdir -p "$LOGD"

# ---- mutual exclusion ------------------------------------------------------
# v1 survived `tmux kill-session` (its signal handling had been corrupted by an
# edit to the file while it was executing) and ran CONCURRENTLY with v2 for 18
# minutes. Both wrote the same TSV, the same progress log, and the same
# /tmp/rapl.log, and both drove the RAPL registers -- producing duplicated rows
# and halved bogo_ops as two stress-ng sets split the machine. Nothing in the
# harness prevented it. An experiment that can silently run twice is an
# experiment whose numbers mean nothing.
LOCK=/run/experiment-sweep.lock
exec 9>"$LOCK" || { echo "cannot open $LOCK" >&2; exit 1; }
if ! flock -n 9; then
  echo "REFUSING: another experiment already holds $LOCK" >&2
  ps -eo pid,etime,cmd | grep '[e]xperiment-dynamic' >&2
  exit 3
fi
# Inherited strays would corrupt the first run the same way.
if pgrep -x stress-ng >/dev/null; then
  echo "REFUSING: stress-ng already running before we started" >&2
  exit 3
fi

# ---- site-policy gate ----------------------------------------------------
# This host carries a machine-wide policy for automated agents which reads:
#   "Never modify, stop, disable or mask cpu-powercap.service ... If
#    /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw does not
#    read 50000000, stop and tell a human."
# This script sweeps exactly that file and restarts that service. That is the
# forbidden action, by name. It is a legitimate experiment, but it needs a
# human to own the deviation -- so it will not run by accident, and the name
# of whoever authorised it lands in the results.
AUTH=""
[ "${1:-}" = "--authorized-by" ] && AUTH="${2:-}"
if [ -z "$AUTH" ]; then
  cat >&2 <<'GATE'
REFUSING TO RUN.

This sweeps intel-rapl:0/constraint_0_power_limit_uw across 45-65W, which
this host's agent policy forbids by name. The cap is what
stops the chassis thermally shutting down.

If a human has signed off on a time-boxed exception, re-run as:

  sudo bash experiment-sweep.sh --authorized-by "<name>"

The cap is restored from a trap on any exit, including Ctrl-C and abort.
GATE
  exit 2
fi
echo "AUTHORISED BY: $AUTH  ($(date -u +%FT%TZ))" | tee -a "$(cd "$(dirname "$0")" && pwd)/results/progress.log"

pkg()  { awk '{print int($1/1000)}' /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input 2>/dev/null | head -1; }
thr()  { cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms; }
fan()  { sensors 2>/dev/null | awk '/^fan1:/{print $2}' | head -1; }
say()  { echo "$(date -u +%H:%M:%S) $*" | tee -a "$PROG"; }

# ---- safety: always put the machine back, whatever happens -----------------
# A monitoring timer that alarms on high package temperature will fire
# repeatedly during a benchmark, for temperatures we are deliberately causing.
# Name it in PAUSE_TIMER and it is paused for the duration, and restored in the
# same trap that restores the cap -- so one cannot happen without the other.
cleanup() {
  say "RESTORING tuned cap and monitoring timer"
  systemctl start cpu-powercap-watchdog.timer 2>/dev/null
  systemctl restart cpu-powercap.service 2>/dev/null
  systemctl start ${PAUSE_TIMER:-} 2>/dev/null
  pkill -x stress-ng 2>/dev/null
  systemctl stop rapl-sample.service 2>/dev/null
  say "restored: MSR=$(( $(cat $R/constraint_0_power_limit_uw)/1000000 ))W MMIO=$(( $(cat $RM/constraint_0_power_limit_uw 2>/dev/null || echo 0)/1000000 ))W (both must read 50)"
}
# A bash signal trap runs the handler and then RESUMES the script. With a
# single `trap cleanup EXIT INT TERM HUP QUIT`, every kill ran cleanup --
# restoring the watchdog and resetting both RAPL domains -- and then carried on
# experimenting. That is why v1 and v2 survived repeated kills, why their
# "RESTORING" lines appeared AFTER a successor had already configured itself,
# and how two experiments ended up running at once. The handler must exit.
on_signal() { say "signal received, aborting run"; cleanup; trap - EXIT; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM HUP QUIT

systemctl stop ${PAUSE_TIMER:-} 2>/dev/null
say "cooler RPM (operator-reported): ${COOLER_RPM:-UNRECORDED}"
say "monitoring timer paused for the duration (${PAUSE_TIMER:-none})"
# cpu-powercap-watchdog.timer re-asserts PL1 from /etc/default/cpu-powercap
# every 60s. The first run of this experiment swept 45-65W and measured 50.0W
# in all ten runs, because the watchdog reset the cap ~3x per 180s run. Any
# experiment that VARIES PL1 must stop it; the trap restarts it.
systemctl stop cpu-powercap-watchdog.timer 2>/dev/null
say "powercap watchdog paused (it re-asserts 50W every 60s)"

set_pl() {  # set_pl <PL1_W> -- BOTH package domains; PL2=PL1+15; tau=8s
  local p1=$1 p2=$(( $1 + 15 )) d got
  # Re-assert the pause every run, not once at startup. v3 paused the watchdog
  # at 22:26:01; the cleanup traps of two dying predecessors re-STARTED it at
  # 22:26:04, three seconds later, and v3 spent the rest of its life being
  # silently reset to 50W. Pausing once is a promise about the past; this is
  # cheap, idempotent, and true for every run.
  systemctl stop cpu-powercap-watchdog.timer 2>/dev/null
  # v1 swept only intel-rapl:0 and measured a flat 50.0W at 55/60/65W. The
  # effective cap is min() across every ENABLED package domain, and
  # intel-rapl-mmio:0 was pinned at 50W, so it bound every run above 50W.
  # Sweeping one interface of a two-interface limit measures the other one.
  for d in "$R" "$RM"; do
    [ -d "$d" ] || continue
    [ "$(cat "$d/enabled" 2>/dev/null)" = "1" ] || continue
    echo $(( p1 * 1000000 )) > "$d/constraint_0_power_limit_uw"
    echo 8000000             > "$d/constraint_0_time_window_us" 2>/dev/null || true
    echo $(( p2 * 1000000 )) > "$d/constraint_1_power_limit_uw" 2>/dev/null || true
    got=$(( $(cat "$d/constraint_0_power_limit_uw") / 1000000 ))
    [ "$got" = "$p1" ] || { say "FATAL: $d asked ${p1}W, reads ${got}W"; exit 1; }
  done
}
# The EFFECTIVE cap is the minimum across enabled package domains, not the
# value of whichever one you happened to write. Report that.
pl_now() {
  local d v m=99999
  for d in "$R" "$RM"; do
    [ -d "$d" ] || continue
    [ "$(cat "$d/enabled" 2>/dev/null)" = "1" ] || continue
    v=$(( $(cat "$d/constraint_0_power_limit_uw") / 1000000 ))
    [ "$v" -lt "$m" ] && m=$v
  done
  echo "$m"
}

cooldown() {
  local waited=0
  while [ $waited -lt 300 ]; do
    [ "$(pkg)" -le 64 ] && break
    sleep 10; waited=$((waited+10))
  done
  sleep 20
  pkg
}

# ---- phase 1: PL1 sweep, mirrored order to cancel ambient drift ------------
printf 'run\tpl1_w\tpl1_end\trep\tambientC\tbogo_ops\tbogo_per_s\tsteadyC\tmaxC\tmeanW\tsteadyW\tthrottle_ms\tfanRPM\taborted\n' > "$OUT"
RUN=0
for spec in 45:1 55:1 65:1 50:1 60:1 60:2 50:2 65:2 55:2 45:2; do
  PL=${spec%%:*}; REP=${spec##*:}
  RUN=$((RUN+1))
  set_pl "$PL"
  say "run $RUN: PL1=${PL}W rep=$REP -- cooling to <=64C"
  AMB=$(cooldown)
  T0=$(thr)
  systemctl start rapl-sample.service; sleep 1
  stress-ng --cpu "$NPROC" --cpu-method matrixprod --timeout 180s --metrics-brief \
      > "$LOGD/run${RUN}_pl${PL}r${REP}.txt" 2>&1 &
  SPID=$!
  MAXT=0; HOT=0; ABORT=0
  for i in $(seq 1 37); do
    sleep 5
    T=$(pkg); [ "${T:-0}" -gt "$MAXT" ] && MAXT=$T
    if [ "${T:-0}" -ge 104 ]; then HOT=$((HOT+1)); else HOT=0; fi
    if [ "$HOT" -ge 2 ]; then ABORT=1; kill $SPID 2>/dev/null; pkill -x stress-ng; break; fi
    kill -0 $SPID 2>/dev/null || break
  done
  wait $SPID 2>/dev/null
  FAN=$(fan); systemctl stop rapl-sample.service; T1=$(thr)
  cp /tmp/rapl.log "$LOGD/rapl_run${RUN}_pl${PL}r${REP}.log" 2>/dev/null
  BOGO=$(awk '/ cpu /{print $5}' "$LOGD/run${RUN}_pl${PL}r${REP}.txt" | head -1)
  BPS=$(awk  '/ cpu /{print $9}' "$LOGD/run${RUN}_pl${PL}r${REP}.txt" | head -1)
  L="$LOGD/rapl_run${RUN}_pl${PL}r${REP}.log"
  STEADYC=$(tail -30 "$L" 2>/dev/null | awk '{s+=$3;n++} END{if(n)printf "%.1f",s/n}')
  STEADYW=$(tail -30 "$L" 2>/dev/null | awk '{s+=$2;n++} END{if(n)printf "%.1f",s/n}')
  MEANW=$(awk '{s+=$2;n++} END{if(n)printf "%.1f",s/n}' "$L" 2>/dev/null)
  PL_END=$(pl_now)
  systemctl is-active --quiet cpu-powercap-watchdog.timer \
    && say "WARNING run $RUN: powercap watchdog was RUNNING during this run"
  [ "$PL_END" = "$PL" ] || say "WARNING run $RUN: PL1 drifted ${PL}W -> ${PL_END}W during the run"
  printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$RUN" "$PL" "$PL_END" "$REP" "$AMB" "${BOGO:-NA}" "${BPS:-NA}" "${STEADYC:-NA}" "$MAXT" \
    "${MEANW:-NA}" "${STEADYW:-NA}" "$((T1-T0))" "${FAN:-NA}" "$ABORT" >> "$OUT"
  say "run $RUN done: steady=${STEADYC:-NA}C max=${MAXT}C work=${BPS:-NA}/s throttle=$((T1-T0))ms"
done
say "PHASE 1 COMPLETE"

# ---- phase 3: burst realism -----------------------------------------------
# 10s load / 20s idle x 12. If peak temp and throttling are indistinguishable
# across PL1 values here, then bursty agent work never leaves the PL2 window
# and PL1 is not the lever to tune for interactive responsiveness.
printf 'pl1_w\tcycle\tperiod\tpeakC\tbogo_per_s\tthrottle_ms\n' > "$BURST"
for PL in 50 65; do
  set_pl "$PL"
  say "burst: PL1=${PL}W -- cooling"
  cooldown >/dev/null
  for c in $(seq 1 12); do
    T0=$(thr); MAXT=0
    stress-ng --cpu "$NPROC" --cpu-method matrixprod --timeout 10s --metrics-brief \
        > "$LOGD/burst_pl${PL}_c${c}.txt" 2>&1 &
    SPID=$!
    for i in 1 2 3 4 5; do sleep 2; T=$(pkg); [ "${T:-0}" -gt "$MAXT" ] && MAXT=$T; done
    wait $SPID 2>/dev/null
    BPS=$(awk '/ cpu /{print $9}' "$LOGD/burst_pl${PL}_c${c}.txt" | head -1)
    printf '%s\t%s\tload\t%s\t%s\t%s\n' "$PL" "$c" "$MAXT" "${BPS:-NA}" "$(( $(thr) - T0 ))" >> "$BURST"
    sleep 20
  done
  say "burst PL1=${PL}W complete"
done
say "EXPERIMENT COMPLETE"
