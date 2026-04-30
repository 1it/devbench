#!/usr/bin/env bash
# devbench Linux host probe.
# Emits the `host` portion of a devbench run.json (per docs/schema.json) to stdout.
# stderr is used for logs only.
#
# Notes:
#  - dmidecode requires root. We try it for RAM speed/channels, fall back to null if denied.
#  - P/E core detection on Intel hybrid uses /sys/devices/cpu_core and /sys/devices/cpu_atom.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "$SCRIPT_DIR/../common/lib.sh"

require_cmd jq
require_cmd lscpu

case "$(detect_os)" in
  linux|wsl) : ;;
  *) die "linux probe invoked on $(detect_os)" ;;
esac

hostname_v="$(hostname -s 2>/dev/null || cat /etc/hostname)"

# OS
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  os_version="${VERSION_ID:-}${VERSION_CODENAME:+ ($VERSION_CODENAME)}"
  os_pretty="${PRETTY_NAME:-linux}"
else
  os_version="$(uname -r)"
  os_pretty="linux"
fi
kernel="$(uname -r)"
arch="$(detect_arch)"

# CPU via lscpu JSON.
lscpu_json="$(lscpu -J)"
cpu_model="$(jq -r '.lscpu[] | select(.field=="Model name:") | .data' <<<"$lscpu_json" | head -n1)"
cpu_vendor="$(jq -r '.lscpu[] | select(.field=="Vendor ID:")  | .data' <<<"$lscpu_json" | head -n1)"
threads_total="$(jq -r '.lscpu[] | select(.field=="CPU(s):") | .data' <<<"$lscpu_json" | head -n1)"
cores_per_socket="$(jq -r '.lscpu[] | select(.field=="Core(s) per socket:") | .data' <<<"$lscpu_json" | head -n1)"
sockets="$(jq -r '.lscpu[] | select(.field=="Socket(s):") | .data' <<<"$lscpu_json" | head -n1)"
cores_total="$(( ${cores_per_socket:-0} * ${sockets:-1} ))"
[[ $cores_total -le 0 ]] && cores_total="$threads_total"

# Boost / base (MHz from lscpu).
base_mhz="$(jq -r '.lscpu[] | select(.field=="CPU min MHz:") | .data' <<<"$lscpu_json" | head -n1)"
boost_mhz="$(jq -r '.lscpu[] | select(.field=="CPU max MHz:") | .data' <<<"$lscpu_json" | head -n1)"
base_ghz=""
boost_ghz=""
[[ -n "$base_mhz" && "$base_mhz" != "null" ]]  && base_ghz="$(awk -v v="$base_mhz"  'BEGIN{printf "%.2f", v/1000}')"
[[ -n "$boost_mhz" && "$boost_mhz" != "null" ]] && boost_ghz="$(awk -v v="$boost_mhz" 'BEGIN{printf "%.2f", v/1000}')"

# Intel hybrid P/E cores (Alder Lake+): presence of /sys/devices/cpu_core + /sys/devices/cpu_atom.
cores_p=""
cores_e=""
if [[ -d /sys/devices/cpu_core && -d /sys/devices/cpu_atom ]]; then
  # cpus files list online logical CPUs; divide by threads-per-core for Pcores (HT).
  p_logical="$(< /sys/devices/cpu_core/cpus)"
  e_logical="$(< /sys/devices/cpu_atom/cpus)"
  # Parse comma/range-separated lists.
  count_cpus() {
    local spec="$1" n=0
    IFS=',' read -ra parts <<<"$spec"
    for p in "${parts[@]}"; do
      if [[ "$p" == *-* ]]; then
        local a="${p%-*}" b="${p#*-}"
        n=$((n + b - a + 1))
      elif [[ -n "$p" ]]; then
        n=$((n + 1))
      fi
    done
    echo "$n"
  }
  p_threads="$(count_cpus "$p_logical")"
  e_threads="$(count_cpus "$e_logical")"
  # P cores typically have HT (2 threads/core); E cores have 1 thread/core.
  # If total threads == total cores, no HT.
  if [[ "$threads_total" -gt "$cores_total" ]]; then
    cores_p="$(( p_threads / 2 ))"
  else
    cores_p="$p_threads"
  fi
  cores_e="$e_threads"
fi
# Apple Silicon via asahi etc: /sys/devices/system/cpu/cpu*/topology/cluster_id can expose clusters.
# Leave as null for now; hard to be universal.

ram_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
ram_gb="$(awk -v k="$ram_kb" 'BEGIN{printf "%.2f", k/1048576}')"

# RAM speed / channels via dmidecode (needs root). Silently null out if not allowed.
ram_speed_mts=""
ram_channels=""
if command -v dmidecode >/dev/null 2>&1 && [[ -r /dev/mem || "$(id -u)" == "0" ]]; then
  # Use configured (not max) speed, in MT/s.
  ram_speed_mts="$(sudo -n dmidecode -t memory 2>/dev/null | awk -F': *' '
    /Configured Memory Speed/ && $2 ~ /MT\/s/ { gsub(/[^0-9]/,"",$2); print $2; exit }
  ')"
  # Channels: count populated "Locator:" entries with a non-"No Module Installed" size.
  ram_channels="$(sudo -n dmidecode -t memory 2>/dev/null | awk '
    /^Memory Device/ { in_dev=1; size_ok=0; next }
    in_dev && /Size:/ && $0 !~ /No Module Installed/ && $0 ~ /[0-9]/ { size_ok=1 }
    in_dev && /^$/ { if (size_ok) n++; in_dev=0 }
    END { print n+0 }
  ')"
fi

# Root FS + physical device.
root_fs="$(findmnt -T / -n -o FSTYPE)"
root_dev="$(findmnt -T / -n -o SOURCE)"
root_size_gb="$(df -BG --output=size / | awk 'NR==2{gsub("G",""); print $1}')"

# Physical disk (walk up from LUKS/LVM/partition to the /dev/sdX or /dev/nvmeXnY).
phys_disk=""
if command -v lsblk >/dev/null 2>&1; then
  phys_disk="$(lsblk -no PKNAME "$root_dev" 2>/dev/null | tail -n1)"
  [[ -z "$phys_disk" ]] && phys_disk="$(basename "$root_dev")"
fi
disk_model=""
if [[ -n "$phys_disk" && -r "/sys/block/$phys_disk/device/model" ]]; then
  disk_model="$(tr -d '\n' < "/sys/block/$phys_disk/device/model" | sed -e 's/[[:space:]]*$//')"
fi
[[ -z "$disk_model" ]] && disk_model="unknown"

jq -n \
  --arg hostname "$hostname_v" \
  --arg os_version "$os_version" \
  --arg os_pretty "$os_pretty" \
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
  --arg root_size_gb "$root_size_gb" \
  '{
    hostname: $hostname,
    os: {
      name: "linux",
      version: $os_version,
      pretty: $os_pretty,
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
    ram_channels:  (if $ram_channels  == "" or $ram_channels == "0" then null else ($ram_channels|tonumber) end),
    storage: {
      model: $disk_model,
      filesystem: $root_fs,
      size_gb: ($root_size_gb|tonumber)
    }
  }'
