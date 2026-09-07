#!/bin/sh
# Root-only sampler: RAPL package power (W), package temp (C), cumulative
# throttle time (ms), every 2s to /tmp/rapl.log.
# energy_uj is root-readable only (a side-channel mitigation), hence the service.
R=/sys/class/powercap/intel-rapl:0
LOG=/tmp/rapl.log
: > $LOG; chmod 644 $LOG
prev=$(cat $R/energy_uj); pt=$(date +%s%N)
while true; do
  sleep 2
  e=$(cat $R/energy_uj); t=$(date +%s%N)
  if [ "$e" -ge "$prev" ]; then d=$((e-prev)); else d=$(( $(cat $R/max_energy_range_uj) - prev + e )); fi
  ms=$(( (t-pt)/1000000 ))
  w=$(awk -v d="$d" -v ms="$ms" 'BEGIN{printf "%.2f", (d/1000000)/(ms/1000)}')
  temp=$(awk '{print int($1/1000)}' /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input 2>/dev/null | head -1)
  thr=$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms)
  echo "$(date +%s) $w $temp $thr" >> $LOG
  prev=$e; pt=$t
done
