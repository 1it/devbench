# Preflight checklist

Run through this **before every benchmark session**. Background noise is the #1 cause of
garbage numbers. If you skip this, don't post the results.

## All OSes

- [ ] Laptop is on the same power state you plan to record (AC or battery — not "mostly AC").
- [ ] Battery >= 80% if on battery.
- [ ] Ambient room temperature noted (°C).
- [ ] Lid open, machine on a hard surface (no blankets / couch thermal throttling).
- [ ] External monitor / dock disconnected unless explicitly part of the test.
- [ ] No VPN active.
- [ ] Browser closed. Slack / Teams / Zoom / Discord quit.
- [ ] No Time Machine / File History / rsync backup running.
- [ ] No OS updates downloading.
- [ ] Clock synced (ntpdate / w32tm).

## macOS

- [ ] `sudo mdutil -a -i off` to halt Spotlight indexing for the session (revert after!).
- [ ] Quit Dropbox, iCloud syncs paused (Finder → "Pause iCloud Sync").
- [ ] Disable "Low Power Mode" in Battery settings (or enable, but record either way).
- [ ] `pmset -g` checked — confirm `sleep 0`, `disksleep 0`, `displaysleep` long enough.
- [ ] Kill `photoanalysisd`, `mediaanalysisd`, `cloudphotod` via `launchctl`.
- [ ] Run `purge` between cold iterations.
- [ ] `powermetrics` accessible via sudo and writes to the results dir.

## Linux

- [ ] `systemctl stop packagekit apt-daily.timer apt-daily-upgrade.timer snapd`
- [ ] Disable `tracker-miner-fs-3` (GNOME) / baloo (KDE) for session.
- [ ] CPU governor recorded: `cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`.
  - For "raw throughput" runs: `performance`.
  - For "as shipped" runs: `powersave`/`schedutil` (whatever the distro defaults to).
  - Record which.
- [ ] `echo 3 > /proc/sys/vm/drop_caches` between cold iterations.
- [ ] `turbostat --version` works (needs msr module and root).
- [ ] Swap usage < 100 MB at start (`free -m`).
- [ ] No `make`/`cargo`/`docker` already running (`pgrep -l`).

## Windows

- [ ] Windows Update paused for 7 days.
- [ ] Defender real-time protection: **record setting, don't blindly disable**. Run twice
      (on/off) if you care about delta.
- [ ] OneDrive paused.
- [ ] Power plan: `powercfg /setactive SCHEME_MIN` (high performance) for "raw" runs,
      `SCHEME_BALANCED` for "as shipped". Record which.
- [ ] Focus assist: priority only.
- [ ] Close all Edge/Chrome windows (they keep background tabs running).
- [ ] `Get-Process | Where-Object { $_.CPU -gt 10 }` — nothing unexpected.
- [ ] RAMMap `-Ew` between cold iterations (download from Sysinternals).

## Verifying "clean"

Run this quick check; abort if ambient CPU > 3% sustained for 30s:

```bash
# macOS / Linux
top -l 30 -s 1 | awk '/CPU usage/ {print}' | tail -30
```

```powershell
# Windows
1..30 | ForEach-Object { (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue; Start-Sleep 1 }
```
