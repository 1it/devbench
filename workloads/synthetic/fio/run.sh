#!/usr/bin/env bash
# fio storage benchmark with predefined profiles.
#
# Usage:
#   run.sh --profile {4k_qd1|seq|mixed} --scratch-dir PATH
#          [--size 1G] [--runtime 15]
#
# Emits a single iteration JSON. Scratch dir MUST be on the disk you want to test.
# The test file is cleaned up after each run.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$HERE/../../../scripts/common"
# shellcheck source=../../../scripts/common/lib.sh
source "$COMMON/lib.sh"
require_cmd fio
require_cmd jq

profile=""
scratch=""
size="1G"
runtime=15
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)     profile="$2";  shift 2 ;;
    --scratch-dir) scratch="$2";  shift 2 ;;
    --size)        size="$2";     shift 2 ;;
    --runtime)     runtime="$2";  shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$profile" ]] || die "--profile required"
[[ -n "$scratch" ]] || die "--scratch-dir required"
mkdir -p "$scratch"

# Per-profile fio args, all writing to $scratch/fiotest.
common_args=(
  "--name=devbench"
  "--filename=$scratch/fiotest"
  "--size=$size"
  "--runtime=${runtime}s"
  "--time_based"
  "--group_reporting"
  "--output-format=json"
  "--direct=1"    # bypass page cache for honest numbers
  "--thread"
  "--ramp_time=2s"
)

case "$profile" in
  4k_qd1)
    args=(
      "--rw=randread"
      "--bs=4k"
      "--iodepth=1"
      "--numjobs=1"
    )
    ;;
  seq)
    args=(
      "--rw=read"
      "--bs=1m"
      "--iodepth=32"
      "--numjobs=1"
    )
    ;;
  mixed)
    args=(
      "--rw=randrw"
      "--rwmixread=70"
      "--bs=16k"
      "--iodepth=16"
      "--numjobs=4"
    )
    ;;
  *) die "unknown profile: $profile (expected 4k_qd1|seq|mixed)" ;;
esac

log_info "fio profile=$profile size=$size runtime=${runtime}s scratch=$scratch"

tmpjson="$(mktemp)"
trap 'rm -f "$tmpjson" "$scratch/fiotest"' EXIT

t0="$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')"
fio "${common_args[@]}" "${args[@]}" > "$tmpjson"
t1="$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')"
wall_s="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"

# fio json has jobs[].read and jobs[].write, each with bw (KiB/s), iops, and clat_ns percentiles.
# We combine read+write metrics into one `extra` block for uniformity.
extra="$(jq --arg profile "$profile" --arg size "$size" --argjson rt "$runtime" '
  .jobs[0] as $j |
  {
    tool: "fio",
    profile: $profile,
    size: $size,
    runtime_s: $rt,
    read: {
      bw_kib_s: ($j.read.bw // 0),
      iops: ($j.read.iops // 0),
      clat_ns_mean: ($j.read.clat_ns.mean // null),
      clat_ns_p99:  ($j.read.clat_ns.percentile."99.000000" // null)
    },
    write: {
      bw_kib_s: ($j.write.bw // 0),
      iops: ($j.write.iops // 0),
      clat_ns_mean: ($j.write.clat_ns.mean // null),
      clat_ns_p99:  ($j.write.clat_ns.percentile."99.000000" // null)
    }
  }
' "$tmpjson")"

emit_iteration --wallclock "$wall_s" --extra "$extra"
