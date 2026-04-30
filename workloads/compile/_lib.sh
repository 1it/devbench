#!/usr/bin/env bash
# Shared helpers for compile workloads.
# Source me. Depends on scripts/common/lib.sh being sourced first.

# ensure_source <name> <git_url> <tag> <src_root>
#   Clones the repo if missing, fetches and checks out the pinned tag.
#   Idempotent. Leaves $src_root/$name checked out at $tag.
#   Echoes the absolute path to the checkout on success.
ensure_source() {
  local name="$1" url="$2" tag="$3" src_root="$4"
  require_cmd git
  mkdir -p "$src_root"
  local path="$src_root/$name"
  if [[ ! -d "$path/.git" ]]; then
    log_info "cloning $url @ $tag -> $path"
    # Not shallow: many build systems call `git describe` and break on shallow.
    git clone --quiet "$url" "$path"
  fi
  (
    cd "$path"
    # Only fetch if we're not already on the target tag.
    local cur
    cur="$(git describe --tags --exact-match 2>/dev/null || true)"
    if [[ "$cur" != "$tag" ]]; then
      log_info "fetching $name to $tag (currently: ${cur:-<untagged>})"
      git fetch --quiet --tags origin "$tag:$tag" 2>/dev/null || git fetch --quiet --tags origin
      git checkout --quiet "$tag"
    fi
    # Reset any local mutations (incremental touch leaves mtime diff, not content; safe).
    git reset --quiet --hard "$tag"
    git clean --quiet -fdx
  )
  echo "$path"
}

# incremental_file_for <project_key>
#   Returns the pinned file to `touch` for a given project (llvm|ripgrep|typescript|kubernetes|duckdb|linux_kernel)
incremental_file_for() {
  case "$1" in
    llvm)          echo "llvm/lib/Analysis/ValueTracking.cpp" ;;
    ripgrep)       echo "crates/core/flags/defs.rs" ;;
    typescript)    echo "src/compiler/checker.ts" ;;
    kubernetes)    echo "pkg/scheduler/schedule_one.go" ;;
    duckdb)        echo "src/execution/operator/join/physical_hash_join.cpp" ;;
    linux_kernel)  echo "mm/page_alloc.c" ;;
    *) return 1 ;;
  esac
}

# default_jobs — parallelism for -jN builds.
default_jobs() {
  case "$(detect_os)" in
    macos)     sysctl -n hw.logicalcpu ;;
    linux|wsl) nproc 2>/dev/null || echo 4 ;;
    *) echo 4 ;;
  esac
}

# wall_seconds <cmd...> — run cmd, echo wall-clock seconds (3dp) to stdout.
# user/sys not captured here; use time_run.sh for that. Useful for sub-phases.
wall_seconds() {
  local t0 t1
  t0="$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')"
  "$@" >/dev/null 2>&1 || return $?
  t1="$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')"
  awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}'
}
