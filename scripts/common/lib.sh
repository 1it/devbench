#!/usr/bin/env bash
# devbench shared bash helpers. Source me; don't run me.
#
# Contract:
#   - All log_* functions write to stderr so stdout stays clean for JSON output.
#   - emit_json takes a jq filter + zero or more --arg / --argjson pairs.
#   - require_cmd aborts with a clear message if a dep is missing.

set -euo pipefail

DEVBENCH_VERSION="0.1.0"
DEVBENCH_SCHEMA_VERSION="1"

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_info()  { printf '[\033[32minfo\033[0m %s] %s\n'  "$(_ts)" "$*" >&2; }
log_warn()  { printf '[\033[33mwarn\033[0m %s] %s\n'  "$(_ts)" "$*" >&2; }
log_err()   { printf '[\033[31merr \033[0m %s] %s\n'  "$(_ts)" "$*" >&2; }
log_debug() { [[ "${DEVBENCH_DEBUG:-0}" == "1" ]] && printf '[debug %s] %s\n' "$(_ts)" "$*" >&2 || true; }

die() { log_err "$*"; exit 1; }

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "required command not found: $cmd (install via scripts/\$os/bootstrap.sh)"
  fi
}

# detect_os -> echoes macos|linux|wsl|unknown
detect_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl
      else echo linux
      fi
      ;;
    *) echo unknown ;;
  esac
}

# detect_arch -> arm64|x86_64|unknown
detect_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo arm64 ;;
    x86_64|amd64)  echo x86_64 ;;
    *) echo unknown ;;
  esac
}

# null_if_empty <val> -> echoes "null" if empty, otherwise the literal value
null_if_empty() { [[ -z "${1:-}" ]] && echo "null" || echo "$1"; }

# JSON string escape via jq (safer than manual sed).
json_str() {
  require_cmd jq
  jq -Rs . <<< "$1"
}
