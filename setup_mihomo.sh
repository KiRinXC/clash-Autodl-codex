#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/codex_common.sh
. "$SCRIPT_DIR/lib/codex_common.sh"

MIHOMO_VERSION="${MIHOMO_VERSION:-1.19.11}"
YQ_VERSION="${YQ_VERSION:-v4.44.3}"
CLASH_RUNTIME_DIR="${CLASH_CODEX_AUTODL_CLASH_RUNTIME_DIR:-$SCRIPT_DIR/clash}"
BIN_DIR="$CLASH_RUNTIME_DIR/bin"
CONF_DIR="$CLASH_RUNTIME_DIR/conf"
LOG_DIR="$CLASH_RUNTIME_DIR/logs"
CONFIG_FILE="$CONF_DIR/config.yaml"
WORK_CONFIG_FILE=""
GEOIP_METADB_FILE="$CONF_DIR/geoip.metadb"
YQ_BINARY="$BIN_DIR/yq"
MIHOMO_BINARY=""

GITHUB_MIRRORS=(
  "github.com"
  "ghfast.top/https://github.com"
)

usage() {
  echo "用法: bash setup_mihomo.sh [ENV_FILE]"
}

arch_name() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64 | amd64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    armv7*) echo "armv7" ;;
    *) log_error "不支持的 CPU 架构: $machine"; return 1 ;;
  esac
}

download_github_file() {
  local github_path="$1"
  local output_file="$2"
  local description="$3"
  local mirror url retries max_time

  for mirror in "${GITHUB_MIRRORS[@]}"; do
    url="https://${mirror}${github_path}"
    retries=2
    max_time=180
    if [ "$mirror" = "github.com" ]; then
      retries=0
      max_time="$(positive_integer_or_default "${GITHUB_DIRECT_MAX_TIME:-}" 30 GITHUB_DIRECT_MAX_TIME)"
    fi
    log_info "正在从 $mirror 下载 $description"
    if curl -fsSL -C - --retry "$retries" --connect-timeout 10 --max-time "$max_time" \
      -o "$output_file" "$url"; then
      if [ -s "$output_file" ]; then
        log_ok "$description 下载完成"
        return 0
      fi
    fi
  done

  log_error "$description 下载失败"
  return 1
}

url_without_scheme() {
  local value="${1:-}"

  value="${value#http://}"
  value="${value#https://}"
  printf '%s\n' "${value%%/*}"
}

url_port_from_url() {
  local value host_port port

  value="${1:-}"
  host_port="$(url_without_scheme "$value")" || return 1

  case "$host_port" in
    *:*)
      port="${host_port##*:}"
      case "$port" in
        ''|*[!0-9]*)
          log_error "URL 端口无效: $value"
          return 1
          ;;
      esac
      printf '%s\n' "$port"
      ;;
    *)
      log_error "URL 缺少端口: $value"
      return 1
      ;;
  esac
}

url_host_from_url() {
  local value host_port

  value="${1:-}"
  host_port="$(url_without_scheme "$value")" || return 1

  case "$host_port" in
    *:*)
      printf '%s\n' "${host_port%:*}"
      ;;
    *)
      log_error "URL 缺少端口: $value"
      return 1
      ;;
  esac
}

controller_bind_from_url() {
  local host port

  case "$1" in
    http://*) ;;
    *)
      log_error "Mihomo Controller URL 必须使用本机 http:// 地址"
      return 1
      ;;
  esac
  host="$(url_host_from_url "$1")" || return 1
  port="$(url_port_from_url "$1")" || return 1
  case "$host" in
    127.0.0.1 | localhost | '[::1]') ;;
    *)
      log_error "Mihomo Controller 只允许监听回环地址，当前地址: $host"
      return 1
      ;;
  esac
  printf '%s:%s\n' "$host" "$port"
}

install_yq() {
  local arch
  arch="$(arch_name)"
  mkdir -p "$BIN_DIR"

  if [ -x "$YQ_BINARY" ]; then
    return 0
  fi

  case "$arch" in
    armv7) arch="arm" ;;
  esac

  download_github_file "/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}" "$YQ_BINARY" "yq 工具"
  chmod +x "$YQ_BINARY"
}

install_mihomo() {
  local arch temp_file temp_binary target_file
  arch="$(arch_name)"
  target_file="$BIN_DIR/mihomo-linux-${arch}"
  mkdir -p "$BIN_DIR"

  if [ -x "$target_file" ]; then
    MIHOMO_BINARY="$target_file"
    return 0
  fi

  temp_file="$(mktemp "${TMPDIR:-/tmp}/clash-codex-mihomo-${arch}.XXXXXX.gz")"
  temp_binary="$(mktemp "$BIN_DIR/.mihomo-${arch}.XXXXXX")"
  if ! download_github_file "/MetaCubeX/mihomo/releases/download/v${MIHOMO_VERSION}/mihomo-linux-${arch}-compatible-v${MIHOMO_VERSION}.gz" "$temp_file" "Mihomo（二进制，架构 $arch）" || \
    ! gzip -d -c "$temp_file" > "$temp_binary"; then
    rm -f "$temp_file" "$temp_binary"
    return 1
  fi
  mv "$temp_binary" "$target_file"
  chmod +x "$target_file"
  rm -f "$temp_file"
  MIHOMO_BINARY="$target_file"
}

geoip_metadb_is_ready() {
  local file="$1"
  local min_bytes="${CODEX_GEOIP_METADB_MIN_BYTES:-5242880}"
  local size

  if [ ! -f "$file" ]; then
    return 1
  fi

  size="$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')" || return 1
  case "$size" in
    ''|*[!0-9]*) return 1 ;;
  esac

  [ "$size" -ge "$min_bytes" ]
}

install_geoip_metadb() {
  local pending
  mkdir -p "$CONF_DIR"

  if geoip_metadb_is_ready "$GEOIP_METADB_FILE"; then
    return 0
  fi

  [ ! -f "$GEOIP_METADB_FILE" ] || log_warn "Mihomo GeoIP 数据库不完整，正在重新下载"
  pending="$(mktemp "$CONF_DIR/.geoip.pending.XXXXXX")"
  if ! download_github_file "/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb" "$pending" "Mihomo GeoIP 数据库"; then
    rm -f "$pending"
    return 1
  fi

  if ! geoip_metadb_is_ready "$pending"; then
    rm -f "$pending"
    log_error "Mihomo GeoIP 数据库下载不完整"
    return 1
  fi
  mv "$pending" "$GEOIP_METADB_FILE"
}

download_subscription() {
  mkdir -p "$CONF_DIR"
  log_info "正在下载 Clash/Mihomo 订阅"
  curl -fL --retry 5 --connect-timeout 15 --max-time 120 -o "$WORK_CONFIG_FILE" "$CLASH_URL"
  chmod 600 "$WORK_CONFIG_FILE" 2>/dev/null || true
  log_ok "订阅已下载并暂存"
}

convert_if_needed() {
  local proxy_count
  proxy_count="$("$YQ_BINARY" eval '.proxies | length' "$WORK_CONFIG_FILE" 2>/dev/null || true)"
  case "$proxy_count" in
    '' | *[!0-9]*) ;;
    *) return 0 ;;
  esac

  if [ -x "$SCRIPT_DIR/converter.sh" ] || [ -f "$SCRIPT_DIR/converter.sh" ]; then
    log_warn "订阅不是有效的 Clash YAML，正在尝试使用 converter.sh 转换"
    bash "$SCRIPT_DIR/converter.sh" "$WORK_CONFIG_FILE" "$WORK_CONFIG_FILE"
    proxy_count="$("$YQ_BINARY" eval '.proxies | length' "$WORK_CONFIG_FILE" 2>/dev/null || true)"
    case "$proxy_count" in
      '' | *[!0-9]*)
        log_error "转换结果不是有效的 Clash YAML"
        return 1
        ;;
      *) return 0 ;;
    esac
  fi

  log_error "订阅不是有效的 Clash YAML，且缺少 converter.sh"
  return 1
}

inject_proxy_settings() {
  local proxy_count
  local proxy_port
  local controller_bind

  log_info "正在配置 Mihomo 端口、控制器和代理选择组"
  proxy_port="$(url_port_from_url "$CODEX_PROXY_URL")" || return 1
  controller_bind="$(controller_bind_from_url "$CODEX_MIHOMO_CONTROLLER_URL")" || return 1

  proxy_count="$("$YQ_BINARY" eval '.proxies | length' "$WORK_CONFIG_FILE" 2>/dev/null || echo 0)"
  case "$proxy_count" in
    '' | *[!0-9]* | 0)
      log_error "转换后的订阅中没有找到可用代理节点"
      return 1
      ;;
  esac

  CODEX_PROXY_PORT="$proxy_port" \
  CODEX_MIHOMO_CONTROLLER_BIND="$controller_bind" \
  CODEX_PROXY_GROUP_NAME="$CODEX_PROXY_GROUP" "$YQ_BINARY" eval -i '
    del(.port, ."socks-port", ."redir-port", ."tproxy-port") |
    ."mixed-port" = (strenv(CODEX_PROXY_PORT) | tonumber) |
    .mode = "rule" |
    ."external-controller" = strenv(CODEX_MIHOMO_CONTROLLER_BIND) |
    del(.secret) |
    ."external-ui" = "dashboard" |
    .profile = (.profile // {}) |
    .profile."store-selected" = true |
    .rules = (.rules // []) |
    ."proxy-groups" = (
      [{
        "name": strenv(CODEX_PROXY_GROUP_NAME),
        "type": "select",
        "proxies": (((.proxies // []) | map(.name) | map(select(. != "DIRECT"))) + ["DIRECT"])
      }] +
      ((."proxy-groups" // []) | map(select(.name != strenv(CODEX_PROXY_GROUP_NAME))))
    )
  ' "$WORK_CONFIG_FILE"

  log_ok "已配置代理选择组: $CODEX_PROXY_GROUP"
}

start_mihomo() {
  local mihomo_bin="$1"
  local mihomo_pid wait_seconds attempt

  mkdir -p "$LOG_DIR"
  stop_existing_mihomo

  nohup "$mihomo_bin" -d "$CONF_DIR" > "$LOG_DIR/mihomo.log" 2>&1 </dev/null &
  mihomo_pid="$!"
  echo "$mihomo_pid" > "$CLASH_RUNTIME_DIR/mihomo.pid"

  wait_seconds="$(mihomo_start_wait_seconds)"
  for ((attempt = 1; attempt <= wait_seconds; attempt++)); do
    if mihomo_log_has_bind_conflict "$LOG_DIR/mihomo.log"; then
      log_error "Mihomo 启动失败：配置的本地端口已被其他进程占用"
      tail -n 80 "$LOG_DIR/mihomo.log" >&2 || true
      stop_existing_mihomo
      return 1
    fi
    if ! kill -0 "$mihomo_pid" >/dev/null 2>&1; then
      log_error "Mihomo 在打开代理端口前已退出"
      tail -n 80 "$LOG_DIR/mihomo.log" >&2 || true
      stop_existing_mihomo
      return 1
    fi

    if mihomo_is_ready; then
      log_ok "Mihomo 代理端口、Controller 和 $CODEX_PROXY_GROUP 均已就绪"
      return 0
    fi
    sleep 1
  done

  if local_proxy_is_listening "$CODEX_PROXY_URL"; then
    log_error "Mihomo 代理端口已启动，但 $(mihomo_controller_status_text)"
  else
    log_error "Mihomo 未能监听 $CODEX_PROXY_URL"
  fi
  tail -n 80 "$LOG_DIR/mihomo.log" >&2 || true
  stop_existing_mihomo
  return 1
}

activate_config_and_start() {
  local backup_file had_previous="false"
  backup_file="$(mktemp "$CONF_DIR/.config.backup.XXXXXX")"
  if [ -f "$CONFIG_FILE" ]; then
    cp -p "$CONFIG_FILE" "$backup_file"
    had_previous="true"
  fi

  mv "$WORK_CONFIG_FILE" "$CONFIG_FILE"
  WORK_CONFIG_FILE=""
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  if start_mihomo "$MIHOMO_BINARY"; then
    rm -f "$backup_file"
    return 0
  fi

  stop_existing_mihomo
  rm -f "$CONFIG_FILE"
  if [ "$had_previous" = "true" ]; then
    mv "$backup_file" "$CONFIG_FILE"
    log_warn "新配置启动失败，已恢复原有 Clash 配置"
    if ! start_mihomo "$MIHOMO_BINARY"; then
      log_error "原有 Clash 配置已恢复，但 Mihomo 未能重新启动"
    fi
  else
    rm -f "$backup_file"
  fi
  return 1
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

env_file="${1:-.env}"
load_project_config "$env_file"
clear_dead_local_proxy_env

if [ -z "${CLASH_URL:-}" ]; then
  log_error "CLASH_URL 为空。请先在目标主机的 $env_file 中填写 Clash 订阅地址。"
  exit 1
fi

mkdir -p "$CONF_DIR"
WORK_CONFIG_FILE="$(mktemp "$CONF_DIR/.config.pending.XXXXXX")"
trap '[ -z "${WORK_CONFIG_FILE:-}" ] || rm -f "$WORK_CONFIG_FILE"' EXIT

install_yq
download_subscription
convert_if_needed
inject_proxy_settings
install_mihomo
install_geoip_metadb
activate_config_and_start
