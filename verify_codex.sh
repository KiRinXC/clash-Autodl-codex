#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
用法: bash verify_codex.sh

验证当前 clash-codex 活动认证档案。
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

if [ -x "$HOME/.local/bin/clash-codex" ]; then
  exec "$HOME/.local/bin/clash-codex" verify
fi
exec "$SCRIPT_DIR/clash-codex" verify
