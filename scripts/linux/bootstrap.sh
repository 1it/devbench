#!/usr/bin/env bash
# devbench Linux bootstrap.
#
# Usage:
#   bootstrap.sh [--baseline] [--toolchains] [--ai] [--all]
#
# Supports Debian/Ubuntu (apt) and Fedora/RHEL (dnf). Detects and dispatches.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "$SCRIPT_DIR/../common/lib.sh"

want_baseline=0; want_toolchains=0; want_ai=0
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

pm=""
if command -v apt-get >/dev/null 2>&1; then pm="apt"
elif command -v dnf >/dev/null 2>&1; then pm="dnf"
else die "no supported package manager (apt or dnf required)"
fi

SUDO=""
[[ "$(id -u)" != "0" ]] && SUDO="sudo"

install_pkgs() {
  local pkgs=("$@")
  case "$pm" in
    apt) $SUDO apt-get update -qq && $SUDO apt-get install -y --no-install-recommends "${pkgs[@]}" ;;
    dnf) $SUDO dnf install -y "${pkgs[@]}" ;;
  esac
}

if [[ $want_baseline -eq 1 ]]; then
  log_info "--- baseline ---"
  case "$pm" in
    apt)
      install_pkgs jq hyperfine time fio sysbench stress-ng p7zip-full git openssl ca-certificates \
                   fd-find ripgrep dmidecode util-linux findutils gawk sysstat curl
      ;;
    dnf)
      install_pkgs jq hyperfine time fio sysbench stress-ng p7zip git openssl \
                   fd-find ripgrep dmidecode util-linux findutils gawk sysstat curl
      ;;
  esac
fi

if [[ $want_toolchains -eq 1 ]]; then
  log_info "--- toolchains ---"
  case "$pm" in
    apt)
      # LLVM via apt.llvm.org for a current version; basic system packages for the rest.
      install_pkgs build-essential cmake ninja-build python3 python3-pip mold pkg-config
      # Node.js 24 via NodeSource
      curl -fsSL https://deb.nodesource.com/setup_24.x | $SUDO -E bash -
      install_pkgs nodejs
      # LLVM 22 via apt.llvm.org
      curl -fsSL https://apt.llvm.org/llvm.sh | $SUDO bash -s -- 22 all || log_warn "llvm apt.llvm.org script failed; continuing"
      ;;
    dnf)
      install_pkgs gcc gcc-c++ make cmake ninja-build python3 python3-pip mold nodejs clang lld
      ;;
  esac
  # Rust via rustup
  if ! command -v rustup >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
  fi
  # Go: latest via tarball (distro versions lag).
  if ! command -v go >/dev/null 2>&1 || [[ "$(go version | awk '{print $3}' | sed 's/go//')" < "1.26" ]]; then
    log_info "installing go 1.26.2 from tarball"
    arch="$(detect_arch)"
    go_arch="amd64"
    [[ "$arch" == "arm64" ]] && go_arch="arm64"
    url="https://go.dev/dl/go1.26.2.linux-${go_arch}.tar.gz"
    curl -fsSL "$url" | $SUDO tar -C /usr/local -xz
    log_info "ensure /usr/local/go/bin is on PATH"
  fi
  # pnpm, bun, uv, ruff via their installers (fastest moving)
  command -v pnpm >/dev/null 2>&1 || curl -fsSL https://get.pnpm.io/install.sh | sh -
  command -v bun  >/dev/null 2>&1 || curl -fsSL https://bun.sh/install    | bash
  command -v uv   >/dev/null 2>&1 || curl -fsSL https://astral.sh/uv/install.sh  | sh
  command -v ruff >/dev/null 2>&1 || pip3 install --user ruff
fi

if [[ $want_ai -eq 1 ]]; then
  log_info "--- ai inference ---"
  # llama.cpp + whisper.cpp from source (distro packages lag badly).
  tmp="$(mktemp -d)"
  git clone --depth 1 https://github.com/ggerganov/llama.cpp   "$tmp/llama.cpp"
  git clone --depth 1 https://github.com/ggerganov/whisper.cpp "$tmp/whisper.cpp"
  ( cd "$tmp/llama.cpp"   && cmake -B build -DLLAMA_CURL=OFF -DGGML_VULKAN=ON -DGGML_CUDA=OFF && cmake --build build -j )
  ( cd "$tmp/whisper.cpp" && cmake -B build && cmake --build build -j )
  log_info "built in $tmp/{llama,whisper}.cpp — move or symlink binaries as you wish"
fi

log_info "bootstrap done. run: scripts/common/self_test.sh"
