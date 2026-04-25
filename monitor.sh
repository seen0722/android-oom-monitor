#!/system/bin/sh
# ============================================================================
# THRPI-354 Device-side Monitor — runs on T70, no adb needed
# ============================================================================
#
# Push to device and run with nohup:
#   adb push thrpi354-device-monitor.sh /data/local/tmp/
#   adb shell "nohup sh /data/local/tmp/thrpi354-device-monitor.sh &"
#
# Stop:
#   adb shell "kill \$(cat /sdcard/thrpi354_monitor/pid.txt)"
#
# Collect results:
#   adb pull /sdcard/thrpi354_monitor/ /tmp/
# ============================================================================

LOG_DIR="/sdcard/thrpi354_monitor"
mkdir -p "$LOG_DIR"

echo $$ > "$LOG_DIR/pid.txt"

TS() { date '+%m-%d %H:%M:%S'; }

echo "$(TS) Monitor started (pid=$$)" > "$LOG_DIR/test.log"

# Initial snapshots
cat /proc/meminfo > "$LOG_DIR/meminfo_before.txt"
cat /proc/vmstat > "$LOG_DIR/vmstat_before.txt"

# VM settings
echo "dirty_ratio: $(cat /proc/sys/vm/dirty_ratio)" > "$LOG_DIR/vm_settings.txt"
echo "dirty_background_ratio: $(cat /proc/sys/vm/dirty_background_ratio)" >> "$LOG_DIR/vm_settings.txt"
echo "dirty_expire_centisecs: $(cat /proc/sys/vm/dirty_expire_centisecs)" >> "$LOG_DIR/vm_settings.txt"
echo "vfs_cache_pressure: $(cat /proc/sys/vm/vfs_cache_pressure)" >> "$LOG_DIR/vm_settings.txt"
echo "swappiness: $(cat /proc/sys/vm/swappiness)" >> "$LOG_DIR/vm_settings.txt"
echo "minfree_levels: $(getprop sys.lmk.minfree_levels)" >> "$LOG_DIR/vm_settings.txt"

# Monitor 1: logcat killinfo + oom_reaper (background)
logcat -c
logcat -v threadtime -s "lmkd:*" "ActivityManager:*" "oom_reaper:*" > "$LOG_DIR/logcat_lmk.txt" 2>/dev/null &
LOGCAT_PID=$!

# Monitor 2: memory + PSI + FBG process (every 5s)
(
  while true; do
    T=$(TS)
    MEM=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    DIRTY=$(grep "^nr_dirty " /proc/vmstat | awk '{print $2}')
    DIRTY_MB=$((DIRTY * 4 / 1024))
    SWAP=$(grep SwapFree /proc/meminfo | awk '{print $2}')
    ANON=$(grep AnonPages /proc/meminfo | awk '{print $2}')
    PSI_SOME=$(head -1 /proc/pressure/memory | awk '{print $2}')
    PSI_FULL=$(sed -n '2p' /proc/pressure/memory | awk '{print $2}')
    FBG=$(pidof com.google.android.apps.nbu.files 2>/dev/null || echo "DEAD")
    USED=$(df /data | tail -1 | awk '{print $5}')
    echo "$T Mem=${MEM}kB Dirty=${DIRTY_MB}MB Swap=${SWAP}kB Anon=${ANON}kB FBG=$FBG Disk=$USED $PSI_SOME $PSI_FULL"
    sleep 5
  done
) > "$LOG_DIR/monitor.txt" 2>/dev/null &
MON_PID=$!

# Monitor 3: vmstat deltas (every 10s)
(
  PREV_STEAL=0
  PREV_REFAULT=0
  PREV_PSWPOUT=0
  while true; do
    T=$(TS)
    VMSTAT=$(cat /proc/vmstat)
    STEAL=$(echo "$VMSTAT" | grep "^pgsteal_kswapd " | awk '{print $2}')
    REFAULT=$(echo "$VMSTAT" | grep "^workingset_refault " | awk '{print $2}')
    PSWPOUT=$(echo "$VMSTAT" | grep "^pswpout " | awk '{print $2}')
    DIRTY=$(echo "$VMSTAT" | grep "^nr_dirty " | awk '{print $2}')
    WB=$(echo "$VMSTAT" | grep "^nr_writeback " | awk '{print $2}')
    ALLOCSTALL=$(echo "$VMSTAT" | grep "^allocstall_normal " | awk '{print $2}')

    DS=$((STEAL - PREV_STEAL))
    DR=$((REFAULT - PREV_REFAULT))
    DP=$((PSWPOUT - PREV_PSWPOUT))

    echo "$T steal_d=$DS refault_d=$DR swapout_d=$DP dirty=$DIRTY wb=$WB allocstall=$ALLOCSTALL"

    PREV_STEAL=$STEAL
    PREV_REFAULT=$REFAULT
    PREV_PSWPOUT=$PSWPOUT
    sleep 10
  done
) > "$LOG_DIR/vmstat_monitor.txt" 2>/dev/null &
VMSTAT_PID=$!

# Monitor 4: FBG crash detector
(
  PREV_PID=""
  while true; do
    T=$(TS)
    CUR_PID=$(pidof com.google.android.apps.nbu.files 2>/dev/null || echo "")
    if [ -n "$PREV_PID" ] && [ -z "$CUR_PID" ]; then
      echo "$T !!! FILES BY GOOGLE CRASHED !!! (was pid=$PREV_PID)"
      cat /proc/meminfo > "$LOG_DIR/meminfo_crash.txt" 2>/dev/null
      cat /proc/vmstat > "$LOG_DIR/vmstat_crash.txt" 2>/dev/null
    elif [ -n "$CUR_PID" ] && [ "$CUR_PID" != "$PREV_PID" ] && [ -n "$PREV_PID" ]; then
      echo "$T FBG restarted: $PREV_PID -> $CUR_PID"
    fi
    PREV_PID=$CUR_PID
    sleep 3
  done
) > "$LOG_DIR/fbg_crash.txt" 2>/dev/null &
CRASH_PID=$!

echo "$(TS) Monitors started: logcat=$LOGCAT_PID mem=$MON_PID vmstat=$VMSTAT_PID crash=$CRASH_PID" >> "$LOG_DIR/test.log"
echo "$LOGCAT_PID $MON_PID $VMSTAT_PID $CRASH_PID" > "$LOG_DIR/child_pids.txt"

# Keep parent alive — write heartbeat every 60s
while true; do
  KILLS=$(grep -c "killinfo" "$LOG_DIR/logcat_lmk.txt" 2>/dev/null || echo 0)
  REAPS=$(grep -c "oom_reaper" "$LOG_DIR/logcat_lmk.txt" 2>/dev/null || echo 0)
  CRASHES=$(grep -c "CRASHED" "$LOG_DIR/fbg_crash.txt" 2>/dev/null || echo 0)
  MEM=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  echo "$(TS) heartbeat: kills=$KILLS reaps=$REAPS crashes=$CRASHES mem=${MEM}kB" >> "$LOG_DIR/test.log"
  sleep 60
done
