#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CLASH_CODEX_AUTODL_CONFIG_DIR:-${CODEX_AUTODL_CONFIG_DIR:-$HOME/.config/clash-codex-autodl}}"
DATA_DIR="${CLASH_CODEX_AUTODL_DATA_DIR:-$HOME/.local/share/clash-codex-autodl}"

log_ok() { printf '[OK] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }

remove_bashrc_block() {
  local begin="$1"
  local end="$2"
  [ -f "$HOME/.bashrc" ] || return 0
  sed -i "/# $begin/,/# $end/d" "$HOME/.bashrc"
}

remove_proxy_hook() {
  remove_bashrc_block 'clash-codex-autodl-proxy begin' 'clash-codex-autodl-proxy end'
  rm -f "$CONFIG_DIR/proxy-shell-init.sh"
  log_ok '已移除 proxy-* 命令'
}

remove_codex_hook() {
  remove_bashrc_block 'clash-codex-autodl-codex begin' 'clash-codex-autodl-codex end'
  rm -f "$CONFIG_DIR/codex-shell-init.sh"
  log_ok '已移除 Codex 包装命令'
}

stop_mihomo_processes() {
  local pid old_pids
  local -a old_pid_array

  if [ -f "$SCRIPT_DIR/mihomo.pid" ]; then
    pid="$(cat "$SCRIPT_DIR/mihomo.pid" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      sleep 1
      kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1 || true
    fi
  fi

  old_pids="$(ps -eo pid=,comm= 2>/dev/null | awk '$2 ~ /^(mihomo|mihomo-linux|clash|clash-linux)/ {print $1}' || true)"
  if [ -n "$old_pids" ]; then
    read -r -a old_pid_array <<< "$old_pids"
    kill "${old_pid_array[@]}" >/dev/null 2>&1 || true
  fi
}

uninstall_proxy() {
  stop_mihomo_processes
  rm -f "$SCRIPT_DIR/mihomo.pid"
  rm -rf "${SCRIPT_DIR:?}/bin" "$SCRIPT_DIR/conf" "$SCRIPT_DIR/logs"
  remove_proxy_hook
  log_ok '代理组件已卸载；Codex 认证档案未修改'
}

manifest_value() {
  local name="$1"
  local manifest="$DATA_DIR/install-manifest"
  sed -n "s/^${name}='\(.*\)'$/\1/p" "$manifest" 2>/dev/null | head -n 1
}

uninstall_codex() {
  local installed path
  installed="$(manifest_value INSTALLED_BY_PROJECT)"
  path="$(manifest_value CODEX_BINARY_PATH)"

  if [ "$installed" = 'true' ] && [[ "$path" == "$HOME/.local/bin/"* ]] && [ -f "$path" ]; then
    rm -f "$path"
    log_ok "已移除本项目安装的 Codex CLI: $path"
  elif [ -n "$path" ]; then
    log_warn "保留未由本项目安全管理的 Codex CLI: $path"
  fi

  rm -rf "$DATA_DIR/codex-homes"
  rm -f "$CONFIG_DIR/active-auth" "$CONFIG_DIR/api-base-url"
  remove_codex_hook
  log_ok 'Codex 认证档案已卸载；用户 ~/.codex 未修改'
  if [ -d "$DATA_DIR/codex-shared" ]; then
    log_warn "共享会话已保留: $DATA_DIR/codex-shared"
  fi
}

remove_project_config() {
  rm -rf "$CONFIG_DIR"
  log_ok '已移除项目配置'
}

remove_legacy_project_files() {
  remove_bashrc_block 'clash-autodl-codex begin' 'clash-autodl-codex end'
  remove_bashrc_block 'clash-codex-autodl begin' 'clash-codex-autodl end'
  rm -f "$HOME/.codex/clash-autodl-codex.sh" "$HOME/.codex/clash-codex-autodl.sh"
  rm -rf "$HOME/.config/clash-autodl-codex"
}

remove_global_runtime() {
  local bin_dir="${CLASH_CODEX_AUTODL_USER_BIN_DIR:-$HOME/.local/bin}"
  rm -f "$bin_dir/clash-codex" "$bin_dir/codex-autodl"
  remove_bashrc_block 'clash-codex-autodl-path begin' 'clash-codex-autodl-path end'
  if [ "$SCRIPT_DIR" = "$DATA_DIR/runtime" ]; then
    rm -rf "$DATA_DIR/runtime"
  fi
  rm -f "$DATA_DIR/install-manifest"
  log_ok '已移除全局 clash-codex 命令'
}

usage() {
  cat <<'USAGE'
用法:
  bash uninstall_codex_bootstrap.sh --proxy
  bash uninstall_codex_bootstrap.sh --codex
  bash uninstall_codex_bootstrap.sh --all

兼容参数:
  --remove-codex-config
  --remove-local-config
USAGE
}

if [ "$#" -eq 0 ]; then
  usage
  exit 1
fi

did_work=false
for arg in "$@"; do
  case "$arg" in
    --help | -h)
      usage
      exit 0
      ;;
    --proxy | clash)
      uninstall_proxy
      did_work=true
      ;;
    --codex | codex)
      uninstall_codex
      did_work=true
      ;;
    --all | all)
      uninstall_proxy
      uninstall_codex
      remove_project_config
      remove_legacy_project_files
      remove_global_runtime
      did_work=true
      ;;
    --remove-codex-config)
      uninstall_codex
      did_work=true
      ;;
    --remove-local-config)
      remove_project_config
      did_work=true
      ;;
    *)
      log_warn "未知参数: $arg"
      usage
      exit 1
      ;;
  esac
done

[ "$did_work" = true ]
