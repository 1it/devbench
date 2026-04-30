#!/usr/bin/env bash
# Build the Linux kernel (defconfig). Linux/WSL only.
#
# Usage:
#   run.sh --variant {cold_jN|incremental} [--src-root DIR] [--tag v6.18]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$HERE/../../../scripts/common"
CLIB="$HERE/../_lib.sh"
# shellcheck source=../../../scripts/common/lib.sh
source "$COMMON/lib.sh"
# shellcheck source=../_lib.sh
source "$CLIB"

case "$(detect_os)" in
  linux|wsl) : ;;
  *) die "linux kernel build is Linux/WSL only (got $(detect_os))" ;;
esac

require_cmd git
require_cmd make
require_cmd jq

variant="cold_jN"
src_root="$HERE/../../_src"
tag="v6.18"
url="https://github.com/torvalds/linux.git"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)  variant="$2";  shift 2 ;;
    --src-root) src_root="$2"; shift 2 ;;
    --tag)      tag="$2";      shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

src_root="$(cd "$(dirname "$src_root")" && pwd)/$(basename "$src_root")"
mkdir -p "$src_root"
path="$(ensure_source linux "$url" "$tag" "$src_root")"
jobs="$(default_jobs)"

case "$variant" in
  cold_jN)
    log_info "make mrproper + defconfig"
    ( cd "$path" && make mrproper >/dev/null 2>&1 && make defconfig >/dev/null 2>&1 )
    ;;
  incremental)
    log_info "pre-build + touch (incremental)"
    ( cd "$path" && make defconfig >/dev/null 2>&1 && make -j "$jobs" >/tmp/devbench-linux-inc-prep.log 2>&1 )
    f="$(incremental_file_for linux_kernel)"
    [[ -f "$path/$f" ]] || die "incremental file missing: $path/$f"
    touch "$path/$f"
    ;;
  *) die "unknown variant: $variant" ;;
esac

log_info "build: variant=$variant jobs=$jobs tag=$tag"
iter_json="$("$COMMON/time_run.sh" \
  --id "compile.linux_kernel.$variant" \
  --cwd "$path" \
  -- make -j "$jobs")"

jq \
  --arg variant "$variant" \
  --arg tag "$tag" \
  --argjson jobs "$jobs" \
  --arg tool "make" \
  '. + {
    extra: {
      tool: $tool,
      project: "linux",
      tag: $tag,
      variant: $variant,
      jobs: $jobs,
      config: "defconfig"
    }
  }' <<<"$iter_json"
