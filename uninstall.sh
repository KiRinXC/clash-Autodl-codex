#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CLASH_CODEX_AUTODL_CONFIG_DIR:-${CODEX_AUTODL_CONFIG_DIR:-$HOME/.config/clash-codex-autodl}}"
DATA_DIR="${CLASH_CODEX_AUTODL_DATA_DIR:-$HOME/.local/share/clash-codex-autodl}"
BIN_DIR="${CLASH_CODEX_AUTODL_USER_BIN_DIR:-$HOME/.local/bin}"
if [ "$SCRIPT_DIR" = "$DATA_DIR/runtime" ]; then
  RUNTIME_DIR="$SCRIPT_DIR"
else
  RUNTIME_DIR="$DATA_DIR/runtime"
fi

log_ok() { printf '[OK] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }

remove_bashrc_block() {
  local begin="$1" end="$2"
  [ -f "$HOME/.bashrc" ] || return 0
  sed -i "/# $begin/,/# $end/d" "$HOME/.bashrc"
}

cleanup_runtime_if_unused() {
  if [ ! -e "$RUNTIME_DIR/.clash-installed" ] && [ ! -e "$RUNTIME_DIR/.codex-installed" ]; then
    remove_bashrc_block 'clash-codex-autodl-path begin' 'clash-codex-autodl-path end'
    rm -rf "$RUNTIME_DIR"
    log_ok "公共运行文件已移除"
  fi
}

stop_proxy() {
  local unit="$HOME/.config/systemd/user/clash-codex-mihomo.service" pid_file pid
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user disable --now clash-codex-mihomo.service >/dev/null 2>&1 || true
  fi
  rm -f "$unit"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  pid_file="$RUNTIME_DIR/clash/mihomo.pid"
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  case "$pid" in
    '' | *[!0-9]*) ;;
    *) kill "$pid" >/dev/null 2>&1 || true ;;
  esac
}

uninstall_clash() {
  stop_proxy
  rm -rf "$RUNTIME_DIR/clash"
  rm -f "$RUNTIME_DIR/.clash-installed"
  rm -f "$BIN_DIR/proxy-on" "$BIN_DIR/proxy-off" "$BIN_DIR/proxy-switch" "$BIN_DIR/proxy-status" "$BIN_DIR/proxy-pick"
  remove_bashrc_block 'clash-codex-autodl-proxy begin' 'clash-codex-autodl-proxy end'
  rm -f "$CONFIG_DIR/proxy-shell-init.sh"
  log_ok "Clash/Mihomo 已卸载；订阅 URL 等用户数据已保留"
  cleanup_runtime_if_unused
}

manifest_value() {
  local name="$1" manifest="$DATA_DIR/install-manifest"
  [ -f "$manifest" ] || return 0
  sed -n "s/^${name}='\(.*\)'$/\1/p" "$manifest" | head -n 1
}

uninstall_codex() {
  local installed path
  installed="$(manifest_value INSTALLED_BY_PROJECT)"
  path="$(manifest_value CODEX_BINARY_PATH)"
  if [ "$installed" = true ] && [[ "$path" == "$HOME/.local/bin/"* ]] && [ -f "$path" ]; then
    rm -f "$path"
    log_ok "已移除本项目安装的 Codex CLI: $path"
  elif [ -n "$path" ]; then
    log_warn "保留不满足安全删除条件的 Codex CLI: $path"
  fi
  rm -f "$DATA_DIR/install-manifest" "$RUNTIME_DIR/.codex-installed"
  rm -f "$BIN_DIR/codex-verify" "$BIN_DIR/codex-status" "$BIN_DIR/codex-switch" "$BIN_DIR/codex-sync" "$BIN_DIR/codex-config"
  rm -f "$BIN_DIR/clash-codex" "$BIN_DIR/codex-autodl"
  remove_bashrc_block 'clash-codex-autodl-codex begin' 'clash-codex-autodl-codex end'
  rm -f "$CONFIG_DIR/codex-shell-init.sh"
  log_ok "Codex 组件已卸载；双认证配置和会话数据已保留"
  cleanup_runtime_if_unused
}

delete_user_data() {
  local confirmed="${1:-}"
  log_warn "将永久删除以下用户数据："
  printf '  %s\n' "$CONFIG_DIR" "$DATA_DIR/codex-homes" "$DATA_DIR/codex-shared"
  if [ "$confirmed" != --yes ]; then
    printf '输入 DELETE 确认: ' >&2
    IFS= read -r answer || answer=""
    [ "$answer" = DELETE ] || { log_warn "已取消"; return 1; }
  fi
  rm -rf "$CONFIG_DIR" "$DATA_DIR/codex-homes" "$DATA_DIR/codex-shared" "$DATA_DIR/codex-sync.lock"
  log_ok "用户数据已永久删除，无法恢复"
}

usage() {
  cat <<'USAGE'
用法:
  bash uninstall.sh clash
  bash uninstall.sh codex
  bash uninstall.sh data [--yes]

卸载组件默认保留订阅、认证配置和会话。只有 data 会删除用户数据。
USAGE
}

case "${1:-}" in
  clash) [ "$#" -eq 1 ] || { usage; exit 1; }; uninstall_clash ;;
  codex) [ "$#" -eq 1 ] || { usage; exit 1; }; uninstall_codex ;;
  data) [ "$#" -le 2 ] || { usage; exit 1; }; delete_user_data "${2:-}" ;;
  --help | -h | help) usage ;;
  *) usage; exit 1 ;;
esac
