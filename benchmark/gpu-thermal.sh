#!/bin/bash
# gpu-thermal.sh -- the combined CPU+GPU case, which every earlier measurement
# on this machine avoided.
#
# The 45-65W CPU envelope was measured GPU-idle. Two attempts to measure the
# GPU case caught the workload's cooldown instead of its load, because the
# sampler was started after the job had already finished. This runs the load
# itself, samples from OUTSIDE the load's timing path, and runs long enough to
# reach steady state rather than catching a transient.
#
# Needs NO root: inference, stress-ng and sysfs temp reads are all unprivileged,
# and PL1 is left exactly as configured.
set -u
OLLAMA=${OLLAMA_HOST:-100.115.113.12:11434}
MODE=${1:-both}          # gpu | both
SECS=${2:-300}
OUT=$(cd "$(dirname "$0")" && pwd)/results/gpu-thermal-$MODE.tsv
ABORT_C=95

pkg()  { awk '{print int($1/1000)}' /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input 2>/dev/null | head -1; }
thr()  { cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms; }
gpu()  { nvidia-smi --query-gpu=power.draw,temperature.gpu,utilization.gpu --format=csv,noheader,nounits; }

cleanup() { kill $(jobs -p) 2>/dev/null; pkill -x stress-ng 2>/dev/null; echo; echo "stopped"; }
trap cleanup EXIT INT TERM HUP

echo "mode=$MODE duration=${SECS}s PL1=$(( $(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw)/1000000 ))W"

# --- the GPU load: back-to-back generation, no network waits between calls ---
(
  while :; do
    curl -s "http://$OLLAMA/api/generate" -d '{"model":"extract","prompt":"Write a detailed technical explanation of how RAPL power limiting works on Intel processors, covering PL1, PL2, the time window, and the difference between the MSR and MMIO interfaces.","stream":false,"options":{"num_predict":400}}' >/dev/null 2>&1 || sleep 1
  done
) & GPULOAD=$!

# --- optional CPU load, so this is the real simultaneous worst case ---
if [ "$MODE" = both ]; then
  stress-ng --cpu "$(nproc)" --cpu-method matrixprod --timeout "${SECS}s" --quiet >/dev/null 2>&1 &
fi

printf 't_s\tgpu_w\tgpu_c\tgpu_util\tcpu_c\tthrottle_delta_ms\n' > "$OUT"
T0=$(thr); start=$(date +%s)
while :; do
  now=$(date +%s); el=$(( now - start ))
  [ "$el" -ge "$SECS" ] && break
  IFS=', ' read -r w gc gu <<< "$(gpu)"
  c=$(pkg)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$el" "$w" "$gc" "$gu" "$c" "$(( $(thr) - T0 ))" >> "$OUT"
  if [ "${c:-0}" -ge "$ABORT_C" ]; then
    echo "ABORT: package ${c}C >= ${ABORT_C}C"; break
  fi
  # 10s, not 5s. Polling nvidia-smi every 5s for minutes put this GPU into
  # NV_ERR_RESET_REQUIRED on 2026-09-08 (kernel: "Failed to get GCx
  # pre-requisite, status=0x62"). GCx is the laptop GPU's runtime power
  # management, and hammering telemetry while the driver manages low-power
  # states breaks it. 30 samples over 300s is ample for a steady-state mean.
  sleep 10
done
T1=$(thr)
echo
awk -F'\t' 'NR>1 && $1>=60 {n++; gw+=$2; gc+=$3; cc+=$5; if($5>mx)mx=$5}
END{printf "steady state (t>=60s, n=%d):\n  gpu %.0fW %.0fC   cpu mean %.0fC peak %dC\n", n, gw/n, gc/n, cc/n, mx}' "$OUT"
echo "  throttle delta over ${SECS}s: $(( T1 - T0 ))ms"
