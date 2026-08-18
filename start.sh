#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
用法:
  bash start.sh
  bash start.sh --reconfigure
  bash start.sh --reconfigure-clash
  bash start.sh --reconfigure-codex

该脚本是兼容入口。安装后可在任意目录使用 clash-codex 命令。
USAGE
}

case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
  "" | --reconfigure | --reconfigure-clash | --reconfigure-codex)
    ;;
  *)
    usage
    exit 1
    ;;
esac

bash "$SCRIPT_DIR/install.sh"
command_path="${CLASH_CODEX_AUTODL_USER_BIN_DIR:-$HOME/.local/bin}/clash-codex"

case "${1:-}" in
  --reconfigure-clash)
    "$command_path" setup clash
    ;;
  --reconfigure-codex)
    "$command_path" setup codex
    "$command_path" auth api
    ;;
  "" | --reconfigure)
    "$command_path" setup
    ;;
esac

printf '\033[1;33m[WARN]\033[0m 请重新打开终端，使 proxy-* 和 codex 包装命令生效。\n'
