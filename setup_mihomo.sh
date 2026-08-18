#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/codex_common.sh
. "$SCRIPT_DIR/lib/codex_common.sh"

MIHOMO_VERSION="${MIHOMO_VERSION:-1.19.11}"
YQ_VERSION="${YQ_VERSION:-v4.44.3}"
BIN_DIR="$SCRIPT_DIR/bin"
CONF_DIR="$SCRIPT_DIR/conf"
LOG_DIR="$SCRIPT_DIR/logs"
CONFIG_FILE="$CONF_DIR/config.yaml"
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
  local mirror url

  for mirror in "${GITHUB_MIRRORS[@]}"; do
    url="https://${mirror}${github_path}"
    log_info "正在从 $mirror 下载 $description"
    if curl -fL -C - --retry 2 --connect-timeout 10 --max-time 180 -o "$output_file" "$url"; then
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

  host="$(url_host_from_url "$1")" || return 1
  port="$(url_port_from_url "$1")" || return 1
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
  local arch temp_file target_file
  arch="$(arch_name)"
  temp_file="/tmp/mihomo-${arch}.gz"
  target_file="$BIN_DIR/mihomo-linux-${arch}"
  mkdir -p "$BIN_DIR"

  if [ -x "$target_file" ]; then
    MIHOMO_BINARY="$target_file"
    return 0
  fi

  download_github_file "/MetaCubeX/mihomo/releases/download/v${MIHOMO_VERSION}/mihomo-linux-${arch}-compatible-v${MIHOMO_VERSION}.gz" "$temp_file" "Mihomo（二进制，架构 $arch）"
  gzip -d -c "$temp_file" > "$target_file"
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
  mkdir -p "$CONF_DIR"

  if geoip_metadb_is_ready "$GEOIP_METADB_FILE"; then
    return 0
  fi

  if [ -f "$GEOIP_METADB_FILE" ]; then
    log_warn "Mihomo GeoIP 数据库不完整，正在重新下载"
    rm -f "$GEOIP_METADB_FILE"
  fi

  download_github_file "/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb" "$GEOIP_METADB_FILE" "Mihomo GeoIP 数据库"

  if ! geoip_metadb_is_ready "$GEOIP_METADB_FILE"; then
    log_error "Mihomo GeoIP 数据库下载不完整"
    return 1
  fi
}

download_subscription() {
  mkdir -p "$CONF_DIR"
  log_info "正在下载 Clash/Mihomo 订阅"
  curl -fL --retry 5 --connect-timeout 15 --max-time 120 -o "$CONFIG_FILE" "$CLASH_URL"
  log_ok "订阅已下载到 $CONFIG_FILE"
}

convert_if_needed() {
  if "$YQ_BINARY" eval '.proxies | length' "$CONFIG_FILE" >/dev/null 2>&1; then
    return 0
  fi

  if [ -x "$SCRIPT_DIR/converter.sh" ] || [ -f "$SCRIPT_DIR/converter.sh" ]; then
    log_warn "订阅不是有效的 Clash YAML，正在尝试使用 converter.sh 转换"
    bash "$SCRIPT_DIR/converter.sh" "$CONFIG_FILE" "$CONFIG_FILE"
    "$YQ_BINARY" eval '.proxies | length' "$CONFIG_FILE" >/dev/null
    return 0
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

  CODEX_PROXY_PORT="$proxy_port" \
  CODEX_MIHOMO_CONTROLLER_BIND="$controller_bind" \
  CODEX_PROXY_GROUP_NAME="$CODEX_PROXY_GROUP" "$YQ_BINARY" eval -i '
    ."mixed-port" = (strenv(CODEX_PROXY_PORT) | tonumber) |
    .mode = "rule" |
    ."external-controller" = strenv(CODEX_MIHOMO_CONTROLLER_BIND) |
    ."external-ui" = "dashboard" |
    .rules = (.rules // []) |
    ."proxy-groups" = (
      [{
        "name": strenv(CODEX_PROXY_GROUP_NAME),
        "type": "select",
        "proxies": ((.proxies // []) | map(.name))
      }] +
      ((."proxy-groups" // []) | map(select(.name != strenv(CODEX_PROXY_GROUP_NAME))))
    )
  ' "$CONFIG_FILE"

  proxy_count="$(CODEX_PROXY_GROUP_NAME="$CODEX_PROXY_GROUP" "$YQ_BINARY" eval '."proxy-groups"[] | select(.name == strenv(CODEX_PROXY_GROUP_NAME)) | (.proxies // []) | length' "$CONFIG_FILE" 2>/dev/null || echo 0)"
  if [ "${proxy_count:-0}" -eq 0 ]; then
    log_error "转换后的订阅中没有找到可用代理节点"
    return 1
  fi

  log_ok "已配置代理选择组: $CODEX_PROXY_GROUP"
}

start_mihomo() {
  local mihomo_bin="$1"
  local mihomo_pid
  local old_pids
  local -a old_pid_array

  mkdir -p "$LOG_DIR"

  old_pids="$(ps -eo pid=,comm= 2>/dev/null | awk '$2 ~ /^(mihomo|mihomo-linux|clash|clash-linux)/ {print $1}' || true)"
  if [ -n "$old_pids" ]; then
    log_warn "重启前正在停止已有的 Mihomo/Clash 进程"
    read -r -a old_pid_array <<< "$old_pids"
    kill "${old_pid_array[@]}" >/dev/null 2>&1 || true
    sleep 2
    old_pids="$(ps -eo pid=,comm= 2>/dev/null | awk '$2 ~ /^(mihomo|mihomo-linux|clash|clash-linux)/ {print $1}' || true)"
    if [ -n "$old_pids" ]; then
      read -r -a old_pid_array <<< "$old_pids"
      kill -9 "${old_pid_array[@]}" >/dev/null 2>&1 || true
    fi
  fi

  nohup "$mihomo_bin" -d "$CONF_DIR" > "$LOG_DIR/mihomo.log" 2>&1 </dev/null &
  mihomo_pid="$!"
  echo "$mihomo_pid" > "$SCRIPT_DIR/mihomo.pid"

  for _ in $(seq 1 20); do
    if ! kill -0 "$mihomo_pid" >/dev/null 2>&1; then
      log_error "Mihomo 在打开代理端口前已退出"
      tail -n 80 "$LOG_DIR/mihomo.log" >&2 || true
      return 1
    fi

    if local_proxy_is_listening "$CODEX_PROXY_URL"; then
      log_ok "Mihomo 正在监听 $CODEX_PROXY_URL"
      return 0
    fi
    sleep 1
  done

  log_error "Mihomo 未能监听 $CODEX_PROXY_URL"
  tail -n 80 "$LOG_DIR/mihomo.log" >&2 || true
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

install_yq
download_subscription
convert_if_needed
inject_proxy_settings
install_mihomo
install_geoip_metadb
start_mihomo "$MIHOMO_BINARY"
