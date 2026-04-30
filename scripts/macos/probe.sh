#!/usr/bin/env bash
# devbench macOS host probe.
# Emits the `host` portion of a devbench run.json (per docs/schema.json) to stdout.
# stderr is used for logs only.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "$SCRIPT_DIR/../common/lib.sh"

require_cmd jq
require_cmd sysctl
require_cmd sw_vers

[[ "$(detect_os)" == "macos" ]] || die "macos probe invoked on $(detect_os)"

hostname_v="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
os_ver="$(sw_vers -productVersion)"
os_build="$(sw_vers -buildVersion)"
kernel="$(uname -r)"
arch="$(detect_arch)"

cpu_model="$(sysctl -n machdep.cpu.brand_string)"
cpu_vendor="$(sysctl -n machdep.cpu.vendor 2>/dev/null || echo "Apple")"
cores_total="$(sysctl -n hw.physicalcpu)"
threads_total="$(sysctl -n hw.logicalcpu)"
# Apple Silicon exposes perflevels; Intel Macs won't have them.
cores_p="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo "")"
cores_e="$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo "")"
# Frequencies: hw.cpufrequency(_max) exists on Intel, absent on Apple Silicon.
base_hz="$(sysctl -n hw.cpufrequency 2>/dev/null || echo "")"
boost_hz="$(sysctl -n hw.cpufrequency_max 2>/dev/null || echo "")"
base_ghz=""
boost_ghz=""
[[ -n "$base_hz" ]]  && base_ghz="$(awk -v v="$base_hz"  'BEGIN{printf "%.2f", v/1e9}')"
[[ -n "$boost_hz" ]] && boost_ghz="$(awk -v v="$boost_hz" 'BEGIN{printf "%.2f", v/1e9}')"

ram_bytes="$(sysctl -n hw.memsize)"
ram_gb="$(awk -v v="$ram_bytes" 'BEGIN{printf "%.2f", v/1073741824}')"
# Apple Silicon: unified LPDDR, no user-serviceable DIMMs. Speed/channels are
# effectively undocumented by Apple; leave null rather than lie.
ram_speed_mts=""
ram_channels=""
if [[ "$arch" == "x86_64" ]]; then
  # Best-effort on Intel Macs via system_profiler. Slow call (~2s), so only do it here.
  ram_speed_mts="$(system_profiler SPMemoryDataType 2>/dev/null | awk -F': ' '/Speed/{gsub(/[^0-9]/,"",$2); print $2; exit}')"
  ram_channels=""  # not reliably exposed
fi

# Root filesystem info.
root_dev="$(df / | awk 'NR==2{print $1}')"
root_fs="$(diskutil info "$root_dev" 2>/dev/null | awk -F': *' '/Type \(Bundle\)/{print $2; exit}')"
[[ -z "$root_fs" ]] && root_fs="$(mount | awk -v d="$root_dev" '$1==d{print $NF}' | tr -d '()' | awk '{print $1}')"
root_size_gb="$(df -g / | awk 'NR==2{print $2}')"

# Disk model: the physical disk backing /. diskutil parent chain.
phys_dev="$(diskutil info "$root_dev" 2>/dev/null | awk -F': *' '/Part of Whole/{print $2; exit}')"
disk_model=""
if [[ -n "$phys_dev" ]]; then
  disk_model="$(diskutil info "/dev/$phys_dev" 2>/dev/null | awk -F': *' '/Device \/ Media Name/{print $2; exit}')"
fi
[[ -z "$disk_model" ]] && disk_model="Apple Internal"

jq -n \
  --arg hostname "$hostname_v" \
  --arg os_name "macos" \
  --arg os_version "$os_ver" \
  --arg os_build "$os_build" \
  --arg os_kernel "$kernel" \
  --arg os_arch "$arch" \
  --arg cpu_model "$cpu_model" \
  --arg cpu_vendor "$cpu_vendor" \
  --argjson cores_total "$cores_total" \
  --argjson threads_total "$threads_total" \
  --arg cores_p "$cores_p" \
  --arg cores_e "$cores_e" \
  --arg base_ghz "$base_ghz" \
  --arg boost_ghz "$boost_ghz" \
  --arg ram_gb "$ram_gb" \
  --arg ram_speed_mts "$ram_speed_mts" \
  --arg ram_channels "$ram_channels" \
  --arg disk_model "$disk_model" \
  --arg root_fs "$root_fs" \
  --argjson root_size_gb "$root_size_gb" \
  '{
    hostname: $hostname,
    os: {
      name: $os_name,
      version: $os_version,
      build: $os_build,
      kernel: $os_kernel,
      arch: $os_arch
    },
    cpu: {
      model: $cpu_model,
      vendor: $cpu_vendor,
      cores_total: $cores_total,
      threads_total: $threads_total,
      cores_performance: (if $cores_p == "" then null else ($cores_p|tonumber) end),
      cores_efficiency:  (if $cores_e == "" then null else ($cores_e|tonumber) end),
      base_ghz:  (if $base_ghz  == "" then null else ($base_ghz |tonumber) end),
      boost_ghz: (if $boost_ghz == "" then null else ($boost_ghz|tonumber) end)
    },
    ram_gb: ($ram_gb|tonumber),
    ram_speed_mts: (if $ram_speed_mts == "" then null else ($ram_speed_mts|tonumber) end),
    ram_channels:  (if $ram_channels  == "" then null else ($ram_channels |tonumber) end),
    storage: {
      model: $disk_model,
      filesystem: $root_fs,
      size_gb: $root_size_gb
    }
  }'
