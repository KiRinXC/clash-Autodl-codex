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

stop_mihomo_pid() {
  local pid="$1"
  case "$pid" in
    '' | *[!0-9]*) return 0 ;;
  esac
  if ! kill -0 "$pid" >/dev/null 2>&1 || ! \
    ps -p "$pid" -o comm= -o args= 2>/dev/null | \
      grep -Eq '(^|[[:space:]/])(mihomo|mihomo-linux[^[:space:]/]*|clash|clash-linux[^[:space:]/]*)($|[[:space:]])'; then
    return 0
  fi
  kill "$pid" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    kill -0 "$pid" >/dev/null 2>&1 || return 0
    sleep 1
  done
  kill -9 "$pid" >/dev/null 2>&1 || true
}

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
  stop_mihomo_pid "$pid"
  rm -f "$pid_file"
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
  local installed path fingerprint method current_fingerprint safe_path="false"
  installed="$(manifest_value INSTALLED_BY_PROJECT)"
  path="$(manifest_value CODEX_BINARY_PATH)"
  fingerprint="$(manifest_value CODEX_BINARY_FINGERPRINT)"
  method="$(manifest_value CODEX_INSTALL_METHOD)"
  case "$path" in
    "$HOME"/*) safe_path="true" ;;
  esac
  current_fingerprint=""
  if [ -f "$path" ] && [ -n "$fingerprint" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      current_fingerprint="sha256:$(sha256sum "$path" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      current_fingerprint="sha256:$(shasum -a 256 "$path" | awk '{print $1}')"
    else
      current_fingerprint="$(cksum "$path" | awk '{print "cksum:" $1 ":" $2}')"
    fi
  fi
  if [ "$installed" = true ] && [ -n "$fingerprint" ] && \
    [ "$fingerprint" = "$current_fingerprint" ]; then
    if [ "$method" = npm ] && command -v npm >/dev/null 2>&1; then
      npm uninstall -g @openai/codex >/dev/null 2>&1 || true
    fi
    if [ -f "$path" ] && [ "$safe_path" = "true" ]; then
      rm -f "$path"
    fi
    if [ ! -e "$path" ]; then
      log_ok "已移除本项目安装的 Codex CLI: $path"
    else
      log_warn "Codex CLI 位于用户目录之外，未直接删除: $path"
    fi
  elif [ -n "$path" ]; then
    log_warn "Codex CLI 已被替换或缺少安装指纹，已保留: $path"
  fi
  rm -f "$DATA_DIR/install-manifest" "$RUNTIME_DIR/.codex-installed"
  rm -f "$BIN_DIR/codex-verify" "$BIN_DIR/codex-status" "$BIN_DIR/codex-switch" "$BIN_DIR/codex-sync" "$BIN_DIR/codex-config"
  rm -f "$BIN_DIR/clash-codex" "$BIN_DIR/codex-autodl"
  remove_bashrc_block 'clash-codex-autodl-codex begin' 'clash-codex-autodl-codex end'
  rm -f "$CONFIG_DIR/codex-shell-init.sh"
  log_ok "Codex 组件已卸载；项目认证快照和原生 CODEX_HOME 数据已保留"
  cleanup_runtime_if_unused
}

delete_user_data() {
  local confirmed="${1:-}" pid_file pid
  if ps -eo pid=,comm=,args= 2>/dev/null | awk -v self="$$" '
    $1 != self && ($2 ~ /^(codex|codex-cli)$/ || $0 ~ /(^|[[:space:]])codex(-cli)?([[:space:]]|$)/ || $0 ~ /\/@openai\/codex\/[^[:space:]]*/) { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
    log_warn "检测到 Codex CLI / Codex App 正在运行；请关闭后再删除认证和会话数据"
    return 1
  fi
  log_warn "将永久删除以下用户数据："
  printf '  %s\n' \
    "$CONFIG_DIR 中的订阅 URL 和 Codex 认证配置" \
    "$RUNTIME_DIR/clash/conf/config.yaml 和运行日志" \
    "$DATA_DIR/codex-profiles（以及旧版本遗留的 codex-homes/codex-shared）"
  log_warn "不会删除或清空原生 $HOME/.codex"
  if [ "$confirmed" != --yes ]; then
    printf '输入 DELETE 确认: ' >&2
    IFS= read -r answer || answer=""
    [ "$answer" = DELETE ] || { log_warn "已取消"; return 1; }
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user disable --now clash-codex-mihomo.service >/dev/null 2>&1 || true
  fi
  pid_file="$RUNTIME_DIR/clash/mihomo.pid"
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  stop_mihomo_pid "$pid"
  rm -f "$pid_file"
  rm -rf "$RUNTIME_DIR/clash/conf" "$RUNTIME_DIR/clash/logs"
  [ ! -e "$RUNTIME_DIR/.clash-installed" ] || mkdir -p "$RUNTIME_DIR/clash/conf"
  rm -rf "$DATA_DIR/codex-profiles" "$DATA_DIR/codex-homes" \
    "$DATA_DIR/codex-shared" "$DATA_DIR/codex-sync.lock"
  rm -f "$CONFIG_DIR/config.sh" "$CONFIG_DIR/api-profile.toml" \
    "$CONFIG_DIR/active-auth" "$CONFIG_DIR/last-verify" "$CONFIG_DIR/last-sync" \
    "$CONFIG_DIR"/api-profile.toml.invalid.*
  if [ -e "$RUNTIME_DIR/.clash-installed" ]; then
    mkdir -p "$CONFIG_DIR"
    {
      printf '%s\n' "CLASH_URL=''"
      printf '%s\n' "CODEX_PROXY_URL='http://127.0.0.1:7890'"
      printf '%s\n' "CODEX_MIHOMO_CONTROLLER_URL='http://127.0.0.1:6006'"
      printf '%s\n' "CODEX_PROXY_GROUP='CodexProxy'"
      printf '%s\n' "PROXY_ENABLED='false'"
    } > "$CONFIG_DIR/config.sh"
    chmod 600 "$CONFIG_DIR/config.sh" 2>/dev/null || true
  fi
  rmdir "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null || true
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
