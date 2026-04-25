# THRPI-354 OOM 技術深度分析

**Ticket**: THRPI-354  
**日期**: 2026-04-25  
**作者**: Billy Chen EXT  
**裝置**: Thorpe DVT3 / Qualcomm SM7325 (lahaina) / Android 15  

本文件為 THRPI-354 OOM 問題的技術深度分析，涵蓋 Linux kernel 記憶體管理機制、PSI/LMK 觸發邏輯、bugreport 數據驗證、以及修正後的 mitigation plan。

---

## 1. Dirty Page 與 Thrashing 機制

### 1.1 什麼是 Dirty Page

當 Files by Google 呼叫 `write()` 複製檔案時：

```
write() → 資料寫入 Page Cache（RAM）
       → Page 被標記為 "dirty"（已修改但未寫入磁碟）
       → 稍後由 writeback thread 非同步寫入 UFS 儲存
```

`dirty_ratio` 控制 dirty pages 佔 RAM 的最大百分比：

```
T70 RAM: ~6000 MB

dirty_ratio = 20（原始）: dirty pages 上限 = 6000 × 20% = 1200 MB
dirty_ratio = 5（修改後）: dirty pages 上限 = 6000 × 5% = 300 MB

超過上限時，write() 被同步阻塞，等 writeback 完成才能繼續。
```

`dirty_background_ratio` 控制背景 writeback 啟動門檻：

```
dirty_background_ratio = 10（原始）: dirty pages 到 600 MB 時開始背景寫回
dirty_background_ratio = 3（修改後）: dirty pages 到 180 MB 時就開始
```

### 1.2 什麼是 Thrashing

**Page 被 kswapd 回收後立刻又被讀回來** — kernel 做了白工。

```
正常情況：
  App A 用完某 page → 很久沒用 → kswapd 回收
  → 很久之後才再次需要 → 從磁碟讀回（偶爾，可接受）

Thrashing：
  Files by Google read() page → kswapd 回收（因為 RAM 壓力）
  → Files by Google write() 需要這個 page → 從 USB 重新讀取（refault）
  → kswapd 又回收 → 又讀回 → 反覆循環
```

Kernel 用 `/proc/vmstat` 中的 `workingset_refault` 追蹤 refault 次數：

```
workingset_refault = 2,980,928  （bugreport 數據）

每次 refault 代表：
  - kswapd 回收的 CPU 時間白費
  - 額外的磁碟 I/O（重複讀取）
  - Process 等待 I/O 完成的時間（stall）
```

### 1.3 File Pages 的組成

```
RAM 中的 pages 分兩大類：

1. Anonymous pages — App 的 Java heap、stack、malloc
   - 沒有對應的磁碟檔案
   - 只能 swap 到 zRAM，不能直接丟棄

2. File pages — 從磁碟讀入的檔案內容（page cache）
   - 有對應的磁碟檔案
   - Clean file pages → 可以直接丟棄（磁碟上有副本）
   - Dirty file pages → 必須先寫回磁碟才能丟棄

File pages 再分兩個 LRU list：
   Active(file)   = 最近被存取的 file pages（kswapd 不優先回收）
   Inactive(file) = 一段時間沒存取的（kswapd 優先回收）

file_pages = Active(file) + Inactive(file)
```

---

## 2. PSI 與 LMK 觸發邏輯

### 2.1 PSI (Pressure Stall Information)

Kernel PSI 子系統追蹤 task 因記憶體不足被阻塞（stall）的時間：

```
/proc/pressure/memory:
  some avg10=4.52 avg60=4.58 avg300=2.51 total=11575612
  full avg10=1.32 avg60=1.58 avg300=0.87 total=4859266

some = 至少 1 個 task 在 stall 的時間比例
full = 所有 non-idle task 都在 stall 的時間比例
```

什麼操作會產生 memory stall：

| 操作 | 說明 |
|------|------|
| Direct reclaim | process 分配記憶體但 free < watermark，必須自己同步回收 |
| Writeback wait | process 需要的 page 正在被 writeback，必須等完成 |
| Refault I/O | process 需要的 page 已被 kswapd 回收，必須從磁碟重讀 |
| Swap in | process 需要的 page 被 swap out 到 zRAM，必須解壓讀回 |

### 2.2 lmkd 的 PSI Trigger 註冊

```
T70 的 lmkd 向 kernel 註冊三個 PSI trigger：

LOW level:     "some 70000 1000000"   → 1 秒內 some stall > 70ms
MEDIUM level:  "some 100000 1000000"  → 1 秒內 some stall > 100ms
CRITICAL level:"full 700000 1000000"  → 1 秒內 full stall > 700ms

stall 超過門檻 → kernel 透過 epoll 通知 lmkd
```

T70 上沒有設定 `ro.lmk.*` properties，全部使用 AOSP 預設值。可透過 `persist.device_config.lmkd_native.*` 在 runtime 覆蓋。

### 2.3 lmkd 收到 PSI event 後的決策邏輯

```python
def mp_event_psi(level):
    # Step 1: 讀取記憶體狀態
    free_pages = read("/proc/meminfo", "MemFree")
    file_pages = read("Active(file)") + read("Inactive(file)")
    
    # Step 2: 計算 thrashing 程度
    refault = read("/proc/vmstat", "workingset_refault")
    thrashing_pct = (refault - prev_refault) * 100 / file_pages
    
    # Step 3: 根據 level + thrashing 決定 min_score_adj
    if level == CRITICAL:
        if thrashing_pct > thrashing_limit_critical:  # 300%
            min_score_adj = 0      # 可 kill 前台 app
        else:
            min_score_adj = 100
    elif level == MEDIUM:
        min_score_adj = 200~700  # 根據 free pages 查 minfree_levels
    else:  # LOW
        min_score_adj = 900
    
    # Step 4: 在 adj >= min_score_adj 的 process 中 kill tasksize 最大的
    find_and_kill_process(min_score_adj)
```

### 2.4 killinfo 欄位格式

lmkd 每次 kill 一個 process 寫一筆 `killinfo` 到 logcat（37 個欄位）：

| Index | 欄位 | 說明 |
|-------|------|------|
| 0 | pid | 被 kill 的 PID |
| 1 | uid | UID |
| 2 | oom_score_adj | 被 kill process 的 oom_adj |
| 3 | min_oom_score | PSI 觸發層級（最低可 kill 的 adj） |
| 4 | tasksize | RSS (pages) |
| 7 | swap_free | Swap 可用 (KB) |
| 13 | free_mem | 系統可用記憶體 (pages) |
| 14 | file_pages | File-backed pages = Active(file) + Inactive(file) |
| 15 | slab_reclaimable | 可回收 slab (pages) |
| 16 | workingset_refault | Thrashing 指標 |
| 18 | active_file | Active file pages |
| 19 | inactive_file | Inactive file pages |
| 20 | active_anon | Active anonymous pages |
| 32-36 | PSI avg | PSI some/full avg10/60/300 |

### 2.5 PSI CRITICAL 觸發的關鍵公式

```
thrashing% = workingset_refault / file_pages × 100

bugreport 數據：
  refault = 2,980,928
  file_pages = 99,388 pages (388 MB)
  thrashing% = 2,980,928 / 99,388 × 100 = 2998%

2998% > thrashing_limit_critical (300%)
→ min_score_adj = 0
→ 連前台 app 都可以 kill
→ Files by Google 被 kill
```

**file_pages 越低，thrashing% 越高**。同樣的 refault 次數，file_pages 從 3991 MB 降到 388 MB 時，thrashing% 從 ~75% 飆升到 2998%。

---

## 3. Bugreport 數據驗證

### 3.1 File Pages 被擠壓的完整證據

| 時間點 | File Pages | Active Anon | FreeMem | 說明 |
|--------|-----------|-------------|---------|------|
| **正常快照** | **3991 MB** | 781 MB | 1168 MB | bugreport /proc/meminfo |
| **Kill #1** | **388 MB** | 502 MB | 6997 MB | lmkd 第一次 kill |
| 差異 | **-3603 MB** | -279 MB | +5829 MB | file cache 幾乎全被回收 |

關鍵觀察：

- **File pages 從 3991 MB 降到 388 MB**（消失了 3603 MB）
- **Anonymous 沒有膨脹**（反而從 781 MB 降到 502 MB）
- **FreeMem 從 1168 MB 升到 6997 MB**（被回收的 file cache 變成 free）

### 3.2 FreeMem 高但 File Pages 低 — 原因

FreeMem 高不代表系統沒有壓力。Free RAM 不會自動變成 file cache — 只有 app 呼叫 `read()` 時才會產生 file pages。

```
File pages 被回收 → 變成 FreeMem
→ 大檔案 I/O 立刻消耗 FreeMem（產生新 dirty pages）
→ dirty pages writeback 後變成 clean → 又被 kswapd 回收
→ 循環！FreeMem 在快速波動。
```

### 3.3 Kill #99 — Files by Google 被 Kill 時的完整快照

```
Kill #99 — pid=4796 (.apps.nbu.files)
Time: 02-09 15:44:47.847

  oom_score_adj   = 0         ← Foreground app（正在使用中）
  min_oom_score   = 0         ← CRITICAL 層級（連前台都可 kill）
  tasksize (RSS)  = 681 MB    ← FBG 實際佔用（不是之前推測的 2.5GB）
  total_vm        = 1668 MB
  free_mem        = 1037 MB
  file_pages      = 618 MB
  inactive_file   = 128 MB    ← 可回收的 file cache 幾乎沒了
  active_anon     = 201 MB
  swap_free       = 4185 MB   ← Swap 幾乎沒用
  PSI full_avg10  = 16.49     ← 嚴重 full stall
  thrashing%      = 1463%     ← 遠超 300% 門檻
```

### 3.4 假設修正：Dirty Pages 堆積 vs 實際數據

**重要發現**：killinfo 中所有 121 筆的 dirty pages 估算值都接近 0。

```
之前的假設：
  dirty pages 堆積到 1.2GB（dirty_ratio=20 的上限）→ 擠掉 file cache

killinfo 實際數據：
  Kill #1:  file_pages=388MB, active_file=1241MB, inactive_file=256MB
  → dirty ≈ file_pages - active - inactive ≈ 0

  Kill #99: file_pages=618MB, active_file=1009MB, inactive_file=128MB
  → dirty ≈ 0
```

這有兩種解釋：

```
解釋 A：killinfo 記錄的是 kill 瞬間的快照
  複製過程中 dirty pages 可能確實很高
  → 但 writeback 在 kill 前已完成
  → killinfo 拍到的是 dirty=0 的瞬間
  → dirty_ratio mitigation 仍然有效

解釋 B：USB 讀取速度太慢，dirty pages 從未堆積
  USB → read() 速度有限
  → writeback 總是跟得上
  → dirty pages 從未堆積到 1.2GB
  → dirty_ratio mitigation 效果有限
```

**需要用 monitor.sh 在複製過程中持續監控 dirty pages 峰值來驗證。**

### 3.5 修正後的因果鏈

```
確認的事實（從 killinfo 證實）：
  - File pages 從 3991 MB 降到 388 MB（消失 3603 MB）
  - Anonymous 沒有膨脹（反而減少 279 MB）
  - FBG RSS = 681 MB（不是 2.5GB）
  - thrashing% 從頭到尾 > 1200%
  - SwapFree 始終 > 3.3 GB

因果鏈：
  大量 I/O（USB → Internal Storage）
  → kswapd 大量回收 file cache（原因待驗證：dirty pages 或其他壓力源）
  → file cache 從 3991 MB 被回收到 388 MB
  → 剩餘的 388 MB 是 FBG 的 working set
  → kswapd 回收它們 → 立刻 refault → thrashing
  → thrashing% > 300% → PSI CRITICAL → min_oom_score=0
  → lmkd kill Files by Google（tasksize 681 MB，前台最大的 process）
```

### 3.4 kswapd 回收活動證據

| 計數器 | 值 | 說明 |
|--------|-----|------|
| pgsteal_kswapd | 25,858,443 | kswapd 回收了 ~99 GB 的 page cache |
| pgscan_kswapd | 26,211,271 | kswapd 掃描了 ~100 GB |
| pgsteal_direct | 3,002 | Direct reclaim 只 ~12 MB（極少） |
| kswapd_low_wmark_hit_quickly | 13,853 | kswapd 被喚醒 13,853 次 |
| workingset_refault | 2,980,928 | refault 298 萬次 |

kswapd CPU：kswapd-1:0 = 13% + kswapd0:1 = 14%，合計 24%。

### 3.5 Kill 過程中的記憶體追蹤

```
Kill#  FreeMem   FilePages  ActiveAnon  SwapFree
─────  ───────   ─────────  ──────────  ────────
  #1   6997 MB    388 MB     502 MB     3346 MB
 #10   5958 MB    413 MB     458 MB     3567 MB
 #20   5721 MB    509 MB     424 MB     3740 MB
 #40   5120 MB    624 MB     347 MB     3858 MB
 #60   3634 MB    594 MB     255 MB     4063 MB
 #80   1797 MB    655 MB     270 MB     4070 MB
 #99   1037 MB    500 MB     210 MB     4185 MB  ← FBG 被 kill
#121   1684 MB    539 MB     218 MB     4190 MB

- File pages 始終在 388~655 MB 低位（FBG working set）
- Anonymous 持續下降（cached apps 被 kill）
- SwapFree 始終 > 3.3 GB（swap 不是瓶頸）
```

---

## 4. 修正後的 Mitigation Plan

### 4.1 核心策略

```
方向 1: 減少 dirty pages 佔用 → 保護 file cache 不被擠壓（待驗證效果）
方向 2: 提早清除 cached apps → 減少 kswapd 對 file cache 的回收壓力
```

### 4.2 方向 1：限制 Dirty Page Cache

| 參數 | 原始值 | 修改值 | 效果 |
|------|--------|--------|------|
| **dirty_ratio** | 20 | **5** | dirty 上限 1.2GB → 300MB |
| **dirty_background_ratio** | 10 | **3** | writeback 在 180MB 啟動（原 600MB） |
| vfs_cache_pressure | 100 | **150** | 更積極回收 dentry/inode cache |

**效果待驗證**：killinfo 中 dirty pages 接近 0（kill 瞬間快照），無法確認複製過程中的 dirty pages 峰值。需要用 monitor.sh 在 USB → Internal 複製過程中持續監控 dirty pages 來判斷此措施是否有效。

```
如果複製中 dirty peaks > 300 MB → dirty_ratio=5 有效（限制堆積）
如果複製中 dirty peaks < 300 MB → dirty_ratio=5 效果有限（USB 太慢，dirty 來不及堆積）
```

驗證狀態：⚠ 參數已在 T70 上 runtime 測試可套用，但實際效果待 monitor.sh 數據驗證。

### 4.3 方向 2：提早清除 Cached Apps（輔助措施）

| adj | 原始門檻 | 修改門檻 | 效果 |
|-----|---------|---------|------|
| 950 | 315 MB | **625 MB** | 更早清除最不重要的背景 app |
| 900 | 216 MB | **430 MB** | 更早清除背景 app |
| 250~0 | 不變 | 不變 | 不影響前台 |

運作原理：

```
不提早清除：I/O 壓力 → kswapd 先回收 file cache → thrashing → 才 kill apps（太晚）
提早清除：  I/O 開始 → free 降到 625MB 就 kill cached apps → 保護 file cache
```

### 4.4 預期效果

```
修改前:
  Kernel 1300 + Dirty 1200 + CachedApps 800 + FileCache 388 + Other 1312 = 6000
                                                          ↑ thrashing!

修改後:
  Kernel 1300 + Dirty 300 + CachedApps 300 + FileCache 1788 + Other 1312 = 6000
                                                          ↑ 遠超 working set
```

### 4.5 實現方式

```bash
# init.thorpe.rc
on property:sys.boot_completed=1
    write /proc/sys/vm/dirty_ratio 5
    write /proc/sys/vm/dirty_background_ratio 3
    write /proc/sys/vm/vfs_cache_pressure 150
```

```properties
# system.prop 或 vendor.prop
sys.lmk.minfree_levels=18432:0,23040:100,27648:200,32256:250,110000:900,160000:950
sys.sysctl.extra_free_kbytes=54674
```

### 4.6 評估後排除的方案

| 方案 | 排除原因 |
|------|---------|
| PSI stall 門檻提高 | PSI 偵測真實 stall，降低敏感度讓系統更卡 |
| swappiness 提高 | 已是最大值 100，active anon pages 無法 swap |
| zRAM 增大 | SwapFree 始終 > 3.3GB，swap 不是瓶頸 |

### 4.7 風險評估

| 修改 | 風險 | 影響 |
|------|------|------|
| dirty_ratio 20→5 | 低 | 大量寫入 throughput 降低，一般使用無感 |
| dirty_background_ratio 10→3 | 低 | writeback 更頻繁，輕微增加 I/O |
| minfree adj=950 提高 | 低 | 背景 app cold start 機率增加 |
| vfs_cache_pressure 100→150 | 低 | 輕微 cache miss |

---

## 5. OOM Reaper 說明

`oom_reaper` 是 kernel thread，在 process 被 SIGKILL 後快速回收 anonymous memory，不等 process 自己 exit。

| | lmkd killinfo | oom_reaper |
|---|---|---|
| 來源 | lmkd (userspace) | kernel thread |
| 時機 | kill 前（決定殺誰） | kill 後（回收記憶體） |
| 觸發者 | PSI trigger | lmkd kill + AM kill + kernel OOM kill |

killinfo=0 但 oom_reaper > 0 代表 ActivityManager 的正常 cached app 清理。

---

## 6. 測試工具

裝置端監控腳本：https://github.com/seen0722/android-oom-monitor

監控項目：killinfo、oom_reaper、MemAvailable、Dirty、Swap、AnonPages、PSI、vmstat deltas、Files by Google crash 偵測。

---

## 附件

- `THRPI-354-OOM-analysis-and-mitigation-plan.docx` — 正式報告
- `THRPI-354-test-case.md` — 測試案例
- `monitor.sh` — 裝置端監控腳本
