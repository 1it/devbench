#!/usr/bin/env bash
# devbench macOS bootstrap.
#
# Usage:
#   bootstrap.sh [--baseline] [--toolchains] [--ai] [--all]
#
# --baseline    (default) Probe + self-test + Tier 1 synthetic deps.
# --toolchains  Compile tier deps (rust, go, node, python, llvm, ninja, cmake, mold_not_mac).
# --ai          Tier 7 local AI inference deps (llama.cpp via tap, mlx via pip).
# --all         = --baseline --toolchains --ai
#
# Apple Silicon assumed; script also works on Intel Macs. Requires Homebrew.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "$SCRIPT_DIR/../common/lib.sh"

want_baseline=0
want_toolchains=0
want_ai=0

if [[ $# -eq 0 ]]; then want_baseline=1; fi
for arg in "$@"; do
  case "$arg" in
    --baseline)   want_baseline=1 ;;
    --toolchains) want_toolchains=1 ;;
    --ai)         want_ai=1 ;;
    --all)        want_baseline=1; want_toolchains=1; want_ai=1 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $arg" ;;
  esac
done

require_cmd brew

brew_install_if_missing() {
  local pkg="$1"
  if brew list --formula "$pkg" >/dev/null 2>&1 || brew list --cask "$pkg" >/dev/null 2>&1; then
    log_info "already installed: $pkg"
  else
    log_info "installing: $pkg"
    brew install "$pkg"
  fi
}

if [[ $want_baseline -eq 1 ]]; then
  log_info "--- baseline ---"
  for p in jq hyperfine gnu-time coreutils fio sysbench stress-ng p7zip git openssl@3 fd ripgrep; do
    brew_install_if_missing "$p"
  done
fi

if [[ $want_toolchains -eq 1 ]]; then
  log_info "--- toolchains ---"
  # Compilers & build tools
  for p in cmake ninja llvm@22 go node python@3.13 pnpm bun uv ruff; do
    brew_install_if_missing "$p" || true
  done
  # rustup (preferred over brew's rust) if not already present
  if ! command -v rustup >/dev/null 2>&1; then
    log_info "installing rustup (runs official rustup-init)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
  fi
fi

if [[ $want_ai -eq 1 ]]; then
  log_info "--- ai inference ---"
  for p in llama.cpp whisper-cpp; do
    brew_install_if_missing "$p" || log_warn "$p not in homebrew-core; consider building from source"
  done
  # MLX via pip (system python).
  if command -v python3 >/dev/null 2>&1; then
    python3 -m pip install --user --upgrade mlx mlx-lm || log_warn "mlx pip install failed"
  fi
fi

log_info "bootstrap done. run: scripts/common/self_test.sh"
