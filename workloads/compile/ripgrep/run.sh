#!/usr/bin/env bash
# Compile ripgrep (release) with cargo.
#
# Usage:
#   run.sh --variant {cold|warm|incremental|cold_mold} [--src-root DIR] [--tag 15.1.0]
#
# Emits one iteration JSON to stdout.
#
# Variants:
#   cold         : clean target/, fresh cargo build --release
#   warm         : second cargo build --release with nothing changed
#   incremental  : touch pinned file, cargo build --release
#   cold_mold    : Linux-only; clean build with mold linker
#
# Note: cargo's own incremental cache is ON by default. We keep it on for "warm" and
# "incremental" (realistic). `cold` wipes target/ so it's a true from-scratch build.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$HERE/../../../scripts/common"
CLIB="$HERE/../_lib.sh"
# shellcheck source=../../../scripts/common/lib.sh
source "$COMMON/lib.sh"
# shellcheck source=../_lib.sh
source "$CLIB"

require_cmd cargo
require_cmd git
require_cmd jq

variant="cold"
src_root="$HERE/../../_src"
tag="15.1.0"
url="https://github.com/BurntSushi/ripgrep.git"
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
path="$(ensure_source ripgrep "$url" "$tag" "$src_root")"

linker_flags=()
cargo_env=()
case "$variant" in
  cold|warm|incremental) : ;;
  cold_mold)
    [[ "$(detect_os)" == "linux" || "$(detect_os)" == "wsl" ]] || die "cold_mold is Linux-only"
    require_cmd mold
    cargo_env=(RUSTFLAGS="-C link-arg=-fuse-ld=mold")
    ;;
  *) die "unknown variant: $variant" ;;
esac

prep() {
  case "$variant" in
    cold|cold_mold)
      log_info "removing target/ (cold build)"
      rm -rf "$path/target"
      ;;
    warm)
      # Pre-build so the second run is a no-op.
      log_info "pre-build (warm setup)"
      ( cd "$path" && env "${cargo_env[@]}" cargo build --release --quiet )
      ;;
    incremental)
      # Pre-build, then touch the pinned file so the next build is truly incremental.
      log_info "pre-build + touch (incremental setup)"
      ( cd "$path" && env "${cargo_env[@]}" cargo build --release --quiet )
      local f; f="$(incremental_file_for ripgrep)"
      [[ -f "$path/$f" ]] || die "incremental file missing: $path/$f"
      touch "$path/$f"
      ;;
  esac
}

prep
log_info "build: variant=$variant tag=$tag"

iter_json="$("$COMMON/time_run.sh" \
  --id "compile.ripgrep.$variant" \
  --cwd "$path" \
  -- env "${cargo_env[@]}" cargo build --release --quiet)"

# Enrich with compile-specific extras.
jq \
  --arg variant "$variant" \
  --arg tag "$tag" \
  --arg linker "$( [[ "$variant" == "cold_mold" ]] && echo mold || echo default )" \
  --argjson jobs "$(default_jobs)" \
  --arg tool "cargo" \
  --arg rustc_version "$(rustc --version 2>/dev/null | awk '{print $2}')" \
  '. + {
    extra: {
      tool: $tool,
      project: "ripgrep",
      tag: $tag,
      variant: $variant,
      linker: $linker,
      jobs: $jobs,
      rustc_version: $rustc_version
    }
  }' <<<"$iter_json"
