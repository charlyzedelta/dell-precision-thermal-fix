R=/sys/class/powercap/intel-rapl:0
OUT=/tmp/results.tsv
LOGD=/tmp/runlogs; mkdir -p $LOGD
pkg() { awk '{print int($1/1000)}' /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input 2>/dev/null | head -1; }
thr() { cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms; }
fan() { sensors 2>/dev/null | awk '/^fan1:/{print $2}' | head -1; }

set_cfg() {
  case $1 in
    A) p1=200000000; t1=55967744; p2=109000000 ;;   # STOCK
    B) p1=50000000;  t1=8000000;  p2=65000000  ;;   # tuned
    C) p1=55000000;  t1=8000000;  p2=80000000  ;;   # aggressive
  esac
  echo $p1 | sudo tee $R/constraint_0_power_limit_uw >/dev/null
  echo $t1 | sudo tee $R/constraint_0_time_window_us >/dev/null
  echo $p2 | sudo tee $R/constraint_1_power_limit_uw >/dev/null
}

cooldown() {
  local target=64 waited=0
  while [ $waited -lt 300 ]; do
    T=$(pkg); [ "$T" -le $target ] && break
    sleep 10; waited=$((waited+10))
  done
  sleep 20
  echo "$(pkg)"
}

printf "run\tcfg\trep\tambientC\tbogo_ops\tbogo_per_s\tsteadyC\tmaxC\tmeanW\tsteadyW\tthrottle_ms\tfanRPM\taborted\n" > $OUT

RUN=0
for spec in A:1 B:1 C:1 C:2 B:2 A:2; do
  CFG=${spec%%:*}; REP=${spec##*:}
  RUN=$((RUN+1))
  set_cfg $CFG
  AMB=$(cooldown)
  T0=$(thr)
  sudo systemctl start rapl-sample.service
  sleep 1
  stress-ng --cpu 16 --cpu-method matrixprod --timeout 180s --metrics-brief > $LOGD/run${RUN}_${CFG}${REP}.txt 2>&1 &
  SPID=$!
  MAXT=0; HOT=0; ABORT=0
  for i in $(seq 1 37); do
    sleep 5
    T=$(pkg); [ "$T" -gt "$MAXT" ] && MAXT=$T
    if [ "$T" -ge 104 ]; then HOT=$((HOT+1)); else HOT=0; fi
    if [ "$HOT" -ge 2 ]; then ABORT=1; kill $SPID 2>/dev/null; pkill -f stress-ng; break; fi
    kill -0 $SPID 2>/dev/null || break
  done
  wait $SPID 2>/dev/null
  FAN=$(fan)
  sudo systemctl stop rapl-sample.service
  T1=$(thr)
  cp /tmp/rapl.log $LOGD/rapl_run${RUN}_${CFG}${REP}.log
  # parse bogo ops
  BOGO=$(awk '/ cpu /{print $5}' $LOGD/run${RUN}_${CFG}${REP}.txt | head -1)
  BPS=$(awk '/ cpu /{print $9}' $LOGD/run${RUN}_${CFG}${REP}.txt | head -1)
  # steady state = last 30 samples (60s); mean over whole run too
  STEADYC=$(tail -30 $LOGD/rapl_run${RUN}_${CFG}${REP}.log | awk '{s+=$3;n++} END{if(n)printf "%.1f",s/n}')
  STEADYW=$(tail -30 $LOGD/rapl_run${RUN}_${CFG}${REP}.log | awk '{s+=$2;n++} END{if(n)printf "%.1f",s/n}')
  MEANW=$(awk '{s+=$2;n++} END{if(n)printf "%.1f",s/n}' $LOGD/rapl_run${RUN}_${CFG}${REP}.log)
  printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    $RUN $CFG $REP "$AMB" "${BOGO:-NA}" "${BPS:-NA}" "${STEADYC:-NA}" "$MAXT" "${MEANW:-NA}" "${STEADYW:-NA}" "$((T1-T0))" "${FAN:-NA}" "$ABORT" >> $OUT
  echo "done run $RUN cfg=$CFG rep=$REP" >> /tmp/progress.log
done

# always restore tuned config
sudo systemctl restart cpu-powercap.service
echo "EXPERIMENT COMPLETE" >> /tmp/progress.log
