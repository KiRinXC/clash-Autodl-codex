#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
用法: bash bootstrap_codex.sh

安装 Codex CLI。认证请使用：
  clash-codex auth api
  clash-codex auth chatgpt
USAGE
}

case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
  "") ;;
  *)
    usage
    exit 1
    ;;
esac

bash "$SCRIPT_DIR/install.sh"
"${CLASH_CODEX_AUTODL_USER_BIN_DIR:-$HOME/.local/bin}/clash-codex" setup codex
