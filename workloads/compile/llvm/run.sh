#!/usr/bin/env bash
# Compile LLVM + clang with ninja. The headline Tier 2 workload.
#
# Usage:
#   run.sh --variant {cold_j1|cold_jN|warm_jN|incremental}
#          [--src-root DIR] [--tag llvmorg-22.1.4]
#          [--jobs N]               # overrides default_jobs for jN variants
#
# We build only the `clang` target to keep time reasonable (~15-30 min on modern hw
# instead of 45-90 min for the full tree). Still touches the whole LLVM core.
#
# Toolchain:
#   - clang as the C/C++ compiler (present on mac via xcrun, linux via apt llvm.sh)
#   - ninja as the generator
#   - ccache / sccache DISABLED (honest cold numbers)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$HERE/../../../scripts/common"
CLIB="$HERE/../_lib.sh"
# shellcheck source=../../../scripts/common/lib.sh
source "$COMMON/lib.sh"
# shellcheck source=../_lib.sh
source "$CLIB"

require_cmd git
require_cmd cmake
require_cmd ninja
require_cmd jq
require_cmd clang
require_cmd clang++

variant="cold_jN"
src_root="$HERE/../../_src"
tag="llvmorg-22.1.4"
jobs=""
url="https://github.com/llvm/llvm-project.git"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)   variant="$2";   shift 2 ;;
    --src-root)  src_root="$2";  shift 2 ;;
    --tag)       tag="$2";       shift 2 ;;
    --jobs)      jobs="$2";      shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

case "$variant" in
  cold_j1)        jobs=1 ;;
  cold_jN|warm_jN|incremental)
                  [[ -z "$jobs" ]] && jobs="$(default_jobs)" ;;
  *) die "unknown variant: $variant" ;;
esac

src_root="$(cd "$(dirname "$src_root")" && pwd)/$(basename "$src_root")"
mkdir -p "$src_root"
path="$(ensure_source llvm-project "$url" "$tag" "$src_root")"
build_dir="$path/build"

configure() {
  log_info "cmake configure (build=$build_dir)"
  mkdir -p "$build_dir"
  cmake -S "$path/llvm" -B "$build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS="clang" \
    -DLLVM_TARGETS_TO_BUILD="host" \
    -DLLVM_CCACHE_BUILD=OFF \
    -DLLVM_USE_LINKER="" \
    -DCMAKE_C_COMPILER="$(command -v clang)" \
    -DCMAKE_CXX_COMPILER="$(command -v clang++)" \
    -DLLVM_PARALLEL_LINK_JOBS=2 \
    >/tmp/devbench-llvm-cmake.log 2>&1
}

prep() {
  case "$variant" in
    cold_j1|cold_jN)
      log_info "removing build/ (cold)"
      rm -rf "$build_dir"
      configure
      ;;
    warm_jN)
      log_info "pre-building (warm setup)"
      [[ -d "$build_dir" ]] || configure
      ninja -C "$build_dir" -j "$jobs" clang >/tmp/devbench-llvm-warm-prep.log 2>&1
      ;;
    incremental)
      log_info "pre-build + touch (incremental setup)"
      [[ -d "$build_dir" ]] || configure
      ninja -C "$build_dir" -j "$jobs" clang >/tmp/devbench-llvm-inc-prep.log 2>&1
      local f; f="$(incremental_file_for llvm)"
      [[ -f "$path/$f" ]] || die "incremental file missing: $path/$f"
      touch "$path/$f"
      ;;
  esac
}

prep
log_info "build: variant=$variant jobs=$jobs tag=$tag"
iter_json="$("$COMMON/time_run.sh" \
  --id "compile.llvm.$variant" \
  --cwd "$build_dir" \
  -- ninja -j "$jobs" clang)"

jq \
  --arg variant "$variant" \
  --arg tag "$tag" \
  --argjson jobs "$jobs" \
  --arg tool "cmake+ninja" \
  --arg clang_version "$(clang --version | head -n1)" \
  '. + {
    extra: {
      tool: $tool,
      project: "llvm-project",
      target: "clang",
      tag: $tag,
      variant: $variant,
      jobs: $jobs,
      compiler: $clang_version
    }
  }' <<<"$iter_json"
