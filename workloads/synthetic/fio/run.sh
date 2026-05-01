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
scratch_abs="$(cd "$scratch" && pwd -P)"
test_file="$scratch_abs/fiotest"

mount_device="$(df -P "$scratch_abs" | awk 'NR==2{print $1}')"
mount_point="$(df -P "$scratch_abs" | awk 'NR==2{print $6}')"
filesystem=""
case "$(uname -s)" in
  Darwin)
    filesystem="$(diskutil info "$mount_device" 2>/dev/null | awk -F': *' '/Type \(Bundle\)/{print $2; exit}' || true)"
    [[ -z "$filesystem" ]] && filesystem="$(diskutil info "$mount_device" 2>/dev/null | awk -F': *' '/File System Personality/{print $2; exit}' || true)"
    ;;
  Linux)
    if command -v findmnt >/dev/null 2>&1; then
      filesystem="$(findmnt -no FSTYPE -T "$scratch_abs" 2>/dev/null | head -n1 || true)"
    fi
    ;;
esac
[[ -z "$filesystem" ]] && filesystem="unknown"

# Per-profile fio args, all writing to $scratch/fiotest.
# We use --output=<file> rather than capturing stdout, because fio writes
# advisory notes to stdout (e.g. "note: both iodepth >= 1 and synchronous I/O
# engine are selected, queue depth will be capped at 1") that break JSON parsing
# when iodepth > 1 is combined with the default sync ioengine.
#
# On macOS we use the posixaio ioengine so iodepth > 1 actually does what users
# expect; on linux libaio is preferred.
case "$(uname -s)" in
  Darwin) ioengine="posixaio" ;;
  Linux)  ioengine="libaio"   ;;
  *)      ioengine="psync"    ;;
esac

tmpjson="$(mktemp)"
trap 'rm -f "$tmpjson" "$test_file"' EXIT

common_args=(
  "--name=devbench"
  "--filename=$test_file"
  "--size=$size"
  "--runtime=${runtime}s"
  "--time_based"
  "--group_reporting"
  "--output-format=json"
  "--output=$tmpjson"
  "--direct=1"
  "--thread"
  "--ramp_time=2s"
  "--ioengine=$ioengine"
)

case "$profile" in
  4k_qd1)
    rw="randread"
    bs="4k"
    iodepth=1
    numjobs=1
    rwmixread=""
    args=(
      "--rw=$rw"
      "--bs=$bs"
      "--iodepth=$iodepth"
      "--numjobs=$numjobs"
    )
    ;;
  seq)
    rw="read"
    bs="1m"
    iodepth=32
    numjobs=1
    rwmixread=""
    args=(
      "--rw=$rw"
      "--bs=$bs"
      "--iodepth=$iodepth"
      "--numjobs=$numjobs"
    )
    ;;
  mixed)
    rw="randrw"
    bs="16k"
    iodepth=16
    numjobs=4
    rwmixread=70
    args=(
      "--rw=$rw"
      "--rwmixread=$rwmixread"
      "--bs=$bs"
      "--iodepth=$iodepth"
      "--numjobs=$numjobs"
    )
    ;;
  *) die "unknown profile: $profile (expected 4k_qd1|seq|mixed)" ;;
esac

log_info "fio profile=$profile size=$size runtime=${runtime}s scratch=$scratch_abs ioengine=$ioengine fs=$filesystem"

t0="$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')"
fio "${common_args[@]}" "${args[@]}" >/dev/null
t1="$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')"
wall_s="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"

# fio json has jobs[].read and jobs[].write, each with bw (KiB/s), iops, and clat_ns percentiles.
# We combine read+write metrics into one `extra` block for uniformity.
extra="$(jq \
  --arg profile "$profile" \
  --arg size "$size" \
  --argjson rt "$runtime" \
  --arg ioengine "$ioengine" \
  --arg scratch_dir "$scratch_abs" \
  --arg test_file "$test_file" \
  --arg mount_device "$mount_device" \
  --arg mount_point "$mount_point" \
  --arg filesystem "$filesystem" \
  --arg rw "$rw" \
  --arg bs "$bs" \
  --argjson iodepth "$iodepth" \
  --argjson numjobs "$numjobs" \
  --arg rwmixread "$rwmixread" \
  '
  .jobs[0] as $j |
  {
    tool: "fio",
    profile: $profile,
    size: $size,
    runtime_s: $rt,
    ioengine: $ioengine,
    direct: true,
    thread: true,
    ramp_time_s: 2,
    scratch_dir: $scratch_dir,
    test_file: $test_file,
    mount: {
      device: $mount_device,
      point: $mount_point,
      filesystem: $filesystem
    },
    job: {
      rw: $rw,
      bs: $bs,
      iodepth: $iodepth,
      numjobs: $numjobs,
      rwmixread: (if $rwmixread == "" then null else ($rwmixread|tonumber) end)
    },
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
