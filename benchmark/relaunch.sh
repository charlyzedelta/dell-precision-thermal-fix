#!/bin/bash
# Clean-slate relaunch. Run as root:  sudo bash relaunch.sh
#
# Ordering is the whole point. Previous attempts launched the new experiment
# while the old ones were still dying, and their cleanup traps -- which restart
# cpu-powercap-watchdog.timer and reset both RAPL domains to 50W -- fired
# AFTER the new run had already configured itself. Nothing may be started
# until everything else is confirmed dead.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

# Count real experiment processes: argv[0]=bash, argv[1] contains the script.
# Matching on the whole command line would match this script and any shell
# that merely mentions it, which is how "remaining: 1" appeared last time.
count()   { ps -eo pid,args --no-headers | awk '$2=="bash" && $3 ~ /experiment-dynamic/ {n++} END{print n+0}'; }
nstress() { pgrep -x stress-ng 2>/dev/null | wc -l; }

echo "before: $(count) experiment proc(s), $(nstress) stress-ng"
pkill -f 'experiment-dynamic.*--authorized-by' 2>/dev/null
pkill -x stress-ng 2>/dev/null
sleep 5
# Anything still alive has the old broken trap: it caught TERM, ran cleanup,
# and resumed. SIGKILL cannot be trapped, so it cannot resume. Its cleanup
# will not run -- which is fine, because this script restores the cap itself,
# below, once everything is confirmed dead.
if [ "$(count)" != 0 ] || [ "$(nstress)" != 0 ]; then
  echo "survivors after TERM -- escalating to KILL"
  pkill -9 -f 'experiment-dynamic.*--authorized-by' 2>/dev/null
  pkill -9 -x stress-ng 2>/dev/null
fi

for i in $(seq 1 30); do
  c=$(count); s=$(nstress)
  [ "$c" = 0 ] && [ "$s" = 0 ] && break
  sleep 1
done
c=$(count); s=$(nstress)
echo "after kill: $c experiment proc(s), $s stress-ng"
if [ "$c" != 0 ] || [ "$s" != 0 ]; then
  echo "ABORT: something survived; not launching into a dirty machine" >&2
  ps -eo pid,ppid,etime,args --no-headers | grep -E 'experiment-dynamic|stress-ng' | grep -v grep >&2
  exit 1
fi

# Only now is it safe to configure state: nothing is left to restore it behind us.
systemctl stop rapl-sample.service 2>/dev/null
systemctl restart cpu-powercap.service
systemctl stop cpu-powercap-watchdog.timer bot-net-node-health.timer
echo "watchdog now: $(systemctl is-active cpu-powercap-watchdog.timer)"
echo "MSR=$(( $(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw)/1000000 ))W MMIO=$(( $(cat /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw)/1000000 ))W"

tmux kill-session -t bench 2>/dev/null
tmux new-session -d -s bench "COOLER_RPM=${COOLER_RPM:-1400} bash $HERE/experiment-dynamic-v4.sh --authorized-by ${WHO:-Charles}"
sleep 6
echo "--- progress ---"
tail -6 "$HERE/results/progress.log"
echo "--- verify ---"
echo "watchdog: $(systemctl is-active cpu-powercap-watchdog.timer) (want inactive)"
echo "MSR=$(( $(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw)/1000000 ))W MMIO=$(( $(cat /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw)/1000000 ))W (want 45/45)"
echo "experiment procs: $(count)  stress-ng: $(nstress)"
