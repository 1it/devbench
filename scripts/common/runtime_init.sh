#!/usr/bin/env bash
# Emit the initial `runtime` object (before a run starts): power_source, ambient CPU%,
# timestamp, devbench + config identity. Cross-platform (macos/linux/wsl).
#
# Usage:
#   runtime_init.sh [--ambient-seconds N] [--config path/to/default.yaml]
#
# Output: JSON object matching the `runtime` portion of docs/schema.json, minus `ended`
# (which the orchestrator fills in at the end of the run).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd jq

ambient_seconds=10
config_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ambient-seconds) ambient_seconds="$2"; shift 2 ;;
    --config)          config_path="$2";     shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

os="$(detect_os)"

# Power source.
power_source="unknown"
case "$os" in
  macos)
    if pmset -g ps 2>/dev/null | grep -qi "AC Power";      then power_source="ac"
    elif pmset -g ps 2>/dev/null | grep -qi "Battery Power"; then power_source="battery"
    fi
    ;;
  linux|wsl)
    # /sys/class/power_supply/AC*/online == 1 -> ac. If no AC supply exists, assume desktop on AC.
    online=""
    for ac in /sys/class/power_supply/AC*/online /sys/class/power_supply/ADP*/online; do
      [[ -r "$ac" ]] && online="$(cat "$ac" 2>/dev/null)" && break
    done
    if [[ -z "$online" ]] && ! ls /sys/class/power_supply/BAT* >/dev/null 2>&1; then
      power_source="ac"   # no batteries present -> desktop
    elif [[ "$online" == "1" ]]; then power_source="ac"
    elif [[ "$online" == "0" ]]; then power_source="battery"
    fi
    ;;
esac

# Ambient CPU% over N seconds. One sample per second, average at the end.
# Keep it light and portable. On macOS we use `iostat -c`; on linux `mpstat` if present,
# else fall back to /proc/stat diffs.
log_info "sampling ambient CPU for ${ambient_seconds}s ..."
ambient_cpu_pct=""
case "$os" in
  macos)
    # macOS iostat -c row format ends with: us sy id 1m 5m 15m
    # so idle is $(NF-3). Skip rows where that field isn't numeric (headers).
    # iostat's first data row is since-boot cumulative; skip it (NR==1 data).
    ambient_cpu_pct="$(iostat -c "$((ambient_seconds + 1))" -w 1 2>/dev/null | awk '
      NF>=6 && $(NF-3) ~ /^[0-9]+(\.[0-9]+)?$/ {
        seen++
        if (seen == 1) next   # skip boot-cumulative line
        sum += (100 - $(NF-3))
        n++
      }
      END { if (n>0) printf "%.2f", sum/n }
    ')"
    ;;
  linux|wsl)
    if command -v mpstat >/dev/null 2>&1; then
      ambient_cpu_pct="$(mpstat 1 "$ambient_seconds" 2>/dev/null | awk '/Average/ && $2 == "all" { printf "%.2f", 100 - $(NF) }')"
    else
      # Fallback: delta /proc/stat
      read_stat() { awk '/^cpu / { for(i=2;i<=NF;i++) s+=$i; print s, $5; exit }' /proc/stat; }
      read a_total a_idle < <(read_stat)
      sleep "$ambient_seconds"
      read b_total b_idle < <(read_stat)
      dtot=$((b_total - a_total))
      didle=$((b_idle - a_idle))
      if [[ $dtot -gt 0 ]]; then
        ambient_cpu_pct="$(awk -v t="$dtot" -v i="$didle" 'BEGIN{printf "%.2f", (1 - i/t) * 100}')"
      fi
    fi
    ;;
esac

ram_used_gb=""
case "$os" in
  macos)
    pages_free="$(vm_stat | awk '/Pages free/ {gsub("\\.",""); print $3}')"
    pages_spec="$(vm_stat | awk '/Pages speculative/ {gsub("\\.",""); print $3}')"
    total_bytes="$(sysctl -n hw.memsize)"
    free_bytes=$(( (pages_free + pages_spec) * 4096 ))
    ram_used_gb="$(awk -v t="$total_bytes" -v f="$free_bytes" 'BEGIN{printf "%.2f", (t-f)/1073741824}')"
    ;;
  linux|wsl)
    ram_used_gb="$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%.2f", (t-a)/1048576}' /proc/meminfo)"
    ;;
esac

config_sha=""
if [[ -n "$config_path" && -r "$config_path" ]]; then
  if command -v shasum >/dev/null 2>&1; then
    config_sha="$(shasum -a 256 "$config_path" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    config_sha="$(sha256sum "$config_path" | awk '{print $1}')"
  fi
fi

jq -n \
  --arg started "$(_ts)" \
  --arg power_source "$power_source" \
  --arg ambient_cpu_pct "$ambient_cpu_pct" \
  --arg ram_used_gb "$ram_used_gb" \
  --arg devbench_version "$DEVBENCH_VERSION" \
  --arg config_sha "$config_sha" \
  '{
    started: $started,
    power_source: $power_source,
    ambient_cpu_pct: (if $ambient_cpu_pct == "" then null else ($ambient_cpu_pct|tonumber) end),
    ambient_ram_used_gb: (if $ram_used_gb == "" then null else ($ram_used_gb|tonumber) end),
    devbench_version: $devbench_version,
    config_sha: (if $config_sha == "" then null else $config_sha end)
  }'
