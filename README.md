# Android OOM Stress Test Monitor

Device-side monitoring script for tracking Android OOM events during large file copy operations via Files by Google.

Created for **THRPI-354**: DVT3 with OS 2.01.03 — Files By Google crashed during file transfer.

## Overview

This script runs directly on the Android device and continuously monitors:

- **LMK killinfo** — lmkd kill events with full memory state (37 fields per kill)
- **OOM reaper** — kernel oom_reaper process reclamation events
- **Memory** — MemAvailable, Dirty pages, Swap, AnonPages (every 5s)
- **PSI** — Pressure Stall Information some/full averages (every 5s)
- **vmstat deltas** — kswapd steal, workingset refault, allocstall (every 10s)
- **Files by Google crash detection** — monitors process existence (every 3s)
- **Storage usage** — disk usage percentage (every 5s)

The script runs independently on the device — **no continuous adb connection needed**.

## Prerequisites

- Android device with `adb root` access (userdebug or eng build)
- USB drive with large test files (10 x 2.47GB recommended)
- Files by Google installed

## Quick Start

### 1. Push script to device

```bash
adb push monitor.sh /data/local/tmp/
adb shell chmod 755 /data/local/tmp/monitor.sh
```

### 2. Start monitoring

```bash
adb shell "nohup sh /data/local/tmp/monitor.sh &"
```

### 3. Verify running

```bash
adb shell "cat /sdcard/thrpi354_monitor/test.log"
adb shell "tail -3 /sdcard/thrpi354_monitor/monitor.txt"
```

### 4. Disconnect adb, perform manual test

Disconnect adb cable, plug in USB drive, and manually operate Files by Google:

1. Open **Files by Google**
2. Navigate to **USB drive**
3. Select all test files (10 x 2.47GB)
4. **Copy to** Internal Storage / Documents
5. Wait for copy to complete
6. Repeat steps 2-5 until "Storage is full" appears
7. In Documents, **Select all** / **Delete permanently**
8. **Restart** the device
9. After reboot, reconnect adb and **restart the monitor** (see step 2)
10. Repeat steps 1-9 for **10-15 cycles**

### 5. Collect results

Reconnect adb and pull the monitoring data:

```bash
adb pull /sdcard/thrpi354_monitor/ ./results/
```

### 6. Stop monitoring

```bash
adb shell "kill $(cat /sdcard/thrpi354_monitor/pid.txt)"
```

## Output Files

All data is saved to `/sdcard/thrpi354_monitor/` on the device:

| File | Content | Interval |
|------|---------|----------|
| `test.log` | Heartbeat with kill/reap/crash counts | 60s |
| `monitor.txt` | Memory, Dirty, Swap, Anon, PSI, FBG pid, Disk usage | 5s |
| `vmstat_monitor.txt` | kswapd steal delta, refault delta, swapout delta, dirty, writeback | 10s |
| `logcat_lmk.txt` | Full lmkd killinfo entries + oom_reaper events | Real-time |
| `fbg_crash.txt` | Files by Google crash/restart events | 3s |
| `vm_settings.txt` | VM parameters at monitor start | Once |
| `meminfo_before.txt` | /proc/meminfo snapshot at start | Once |
| `vmstat_before.txt` | /proc/vmstat snapshot at start | Once |
| `meminfo_crash.txt` | /proc/meminfo at crash moment | On crash |
| `vmstat_crash.txt` | /proc/vmstat at crash moment | On crash |
| `pid.txt` | Monitor process PID | Once |

## Analyzing Results

### Check for crashes

```bash
cat results/fbg_crash.txt
```

### Check LMK kills

```bash
grep "killinfo" results/logcat_lmk.txt | wc -l
```

### Check OOM reaper activity

```bash
grep "oom_reaper" results/logcat_lmk.txt | wc -l
```

### Memory trend (minimum MemAvailable)

```bash
grep "Mem=" results/monitor.txt | awk -F'Mem=' '{print $2}' | awk -F'kB' '{print $1}' | sort -n | head -1
```

### Dirty page peaks

```bash
grep "Dirty=" results/monitor.txt | awk -F'Dirty=' '{print $2}' | awk -F'MB' '{print $1}' | sort -n | tail -5
```

### vmstat thrashing (workingset refault)

```bash
grep "refault_d=" results/vmstat_monitor.txt | awk -F'refault_d=' '{print $2}' | awk '{print $1}' | sort -n | tail -10
```

## killinfo Field Reference

Each `killinfo` entry in `logcat_lmk.txt` contains 37 fields:

| Index | Field | Description |
|-------|-------|-------------|
| 0 | pid | Killed process PID |
| 1 | uid | Killed process UID |
| 2 | oom_score_adj | Killed process oom_adj |
| 3 | min_oom_score | PSI trigger level |
| 4 | tasksize | RSS in pages |
| 7 | swap_free | Swap available (KB) |
| 13 | free_mem | System free memory (pages) |
| 14 | file_pages | File-backed pages |
| 15 | slab_reclaimable | Reclaimable slab (pages) |
| 16 | workingset_refault | Thrashing indicator |
| 18 | active_file | Active file pages |
| 20 | active_anon | Active anonymous pages |
| 32-36 | PSI avg | PSI some/full avg10/60/300 |

## Important Notes

- **Reboot resets the monitor** — restart it after each device reboot
- The script uses minimal memory (< 1MB) and will NOT be killed by LMK
- Monitor data persists across reboots (stored on `/sdcard/`)
- `logcat_lmk.txt` is cleared on each monitor start (`logcat -c`)

## Background

Root cause: Files by Google uses non-streaming file I/O when copying from USB, loading entire file contents into Java heap. During batch copy of large files, this exhausts available RAM and triggers Android's LMK/OOM killer.

This monitor captures the data needed to:
1. Confirm the OOM trigger mechanism (PSI stall / lmkd / killinfo)
2. Measure the effectiveness of VM parameter mitigations
3. Compare baseline vs. mitigated behavior

## License

MIT
