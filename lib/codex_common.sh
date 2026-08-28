#!/usr/bin/env bash

set -o pipefail

DEFAULT_CLASH_URL=""
DEFAULT_PROXY_URL="http://127.0.0.1:7890"
DEFAULT_MIHOMO_CONTROLLER_URL="http://127.0.0.1:6006"
DEFAULT_CODEX_PROXY_GROUP="CodexProxy"
DEFAULT_PROXY_ENABLED="true"

if [ -z "${CLASH_CODEX_AUTODL_REPO_ROOT:-}" ] && [ -n "${CODEX_AUTODL_REPO_ROOT:-}" ]; then
  CLASH_CODEX_AUTODL_REPO_ROOT="$CODEX_AUTODL_REPO_ROOT"
fi

if [ -z "${CLASH_CODEX_AUTODL_REPO_ROOT:-}" ]; then
  CLASH_CODEX_AUTODL_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
CODEX_AUTODL_REPO_ROOT="$CLASH_CODEX_AUTODL_REPO_ROOT"

log_info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
log_ok() { printf '\033[0;32m[OK]\033[0m %s\n' "$*"; }
log_warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
log_error() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*" >&2; }

normalize_pasted_input() {
  local value="${1:-}" paste_start paste_end
  paste_start=$'\033[200~'
  paste_end=$'\033[201~'
  value="${value//$'\r'/}"
  case "$value" in
    "$paste_start"*) value="${value#"$paste_start"}" ;;
  esac
  case "$value" in
    *"$paste_end") value="${value%"$paste_end"}" ;;
  esac
  printf '%s' "$value"
}

input_has_control_characters() {
  case "${1:-}" in
    *[[:cntrl:]]*) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_required() {
  local label="$1"
  local current="${2:-}"
  local value

  while :; do
    if [ -n "$current" ]; then
      printf '%s [%s]: ' "$label" "$current" >&2
    else
      printf '%s: ' "$label" >&2
    fi
    if ! IFS= read -r value; then
      log_error "输入已结束，配置未完成（$label）"
      return 1
    fi
    value="$(normalize_pasted_input "$value")"
    if input_has_control_characters "$value"; then
      log_warn "$label 包含不可见控制字符，请重新粘贴" >&2
      continue
    fi
    if [ -z "$value" ] && [ -n "$current" ]; then
      value="$current"
    fi
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
    log_warn "$label 不能为空" >&2
  done
}

prompt_secret() {
  local label="$1"
  local value

  while :; do
    if [ -t 0 ]; then
      printf '%s: ' "$label" >&2
      if ! IFS= read -r -s value; then
        printf '\n' >&2
        log_error "输入已结束，配置未完成（$label）"
        return 1
      fi
      printf '\n' >&2
    else
      printf '%s: ' "$label" >&2
      if ! IFS= read -r value; then
        log_error "输入已结束，配置未完成（$label）"
        return 1
      fi
    fi
    value="$(normalize_pasted_input "$value")"
    if input_has_control_characters "$value"; then
      log_warn "$label 包含不可见控制字符，请重新粘贴" >&2
      continue
    fi
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
    log_warn "$label 不能为空" >&2
  done
}

project_config_dir() {
  printf '%s\n' "${CLASH_CODEX_AUTODL_CONFIG_DIR:-${CODEX_AUTODL_CONFIG_DIR:-$HOME/.config/clash-codex-autodl}}"
}

project_config_file() {
  if [ -n "${CLASH_CODEX_AUTODL_CONFIG_FILE:-}" ]; then
    printf '%s\n' "$CLASH_CODEX_AUTODL_CONFIG_FILE"
  elif [ -n "${CODEX_AUTODL_CONFIG_FILE:-}" ]; then
    printf '%s\n' "$CODEX_AUTODL_CONFIG_FILE"
  else
    printf '%s/config.sh\n' "$(project_config_dir)"
  fi
}

apply_project_defaults() {
  CLASH_URL="${CLASH_URL:-$DEFAULT_CLASH_URL}"
  CODEX_PROXY_URL="${CODEX_PROXY_URL:-$DEFAULT_PROXY_URL}"
  CODEX_MIHOMO_CONTROLLER_URL="${CODEX_MIHOMO_CONTROLLER_URL:-$DEFAULT_MIHOMO_CONTROLLER_URL}"
  CODEX_PROXY_GROUP="${CODEX_PROXY_GROUP:-$DEFAULT_CODEX_PROXY_GROUP}"
  if [ -z "${PROXY_ENABLED:-}" ] && [ -n "${AUTO_PROXY_ON_SHELL_START:-}" ]; then
    PROXY_ENABLED="$AUTO_PROXY_ON_SHELL_START"
  fi
  PROXY_ENABLED="${PROXY_ENABLED:-$DEFAULT_PROXY_ENABLED}"
}

load_project_config() {
  local config_file="${1:-$(project_config_file)}"

  if [ -f "$config_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$config_file"
    set +a
  fi

  apply_project_defaults
}

shell_single_quote() {
  local value="${1:-}"
  local escaped
  escaped="$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
  printf "'%s'" "$escaped"
}

write_config_value() {
  local name="$1"
  local value="${!name:-}"

  printf '%s=' "$name"
  shell_single_quote "$value"
  printf '\n'
}

save_project_config() {
  local config_file
  local config_dir
  local tmp_file

  config_file="$(project_config_file)"
  apply_project_defaults
  config_dir="$(dirname "$config_file")"
  mkdir -p "$config_dir"
  tmp_file="$(mktemp)"

  {
    write_config_value CLASH_URL
    write_config_value CODEX_PROXY_URL
    write_config_value CODEX_MIHOMO_CONTROLLER_URL
    write_config_value CODEX_PROXY_GROUP
    write_config_value PROXY_ENABLED
  } > "$tmp_file"

  chmod 600 "$tmp_file" 2>/dev/null || true
  mv "$tmp_file" "$config_file"
  chmod 600 "$config_file" 2>/dev/null || true
}

validate_http_url() {
  local name="$1"
  local value="$2"

  case "$value" in
    http://* | https://*) return 0 ;;
    *)
      log_error "$name 必须以 http:// 或 https:// 开头"
      return 1
      ;;
  esac
}

python_command() {
  local candidate candidate_path

  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
      candidate_path="$(command -v "$candidate")"
      if "$candidate_path" - <<'PY' >/dev/null 2>&1
import sys
PY
      then
        printf '%s\n' "$candidate_path"
        return 0
      fi
    fi
  done

  return 1
}

proxy_env_is_active() {
  [ -n "${http_proxy:-}" ] || [ -n "${https_proxy:-}" ] || [ -n "${HTTP_PROXY:-}" ] || [ -n "${HTTPS_PROXY:-}" ]
}

proxy_url_for_compare() {
  local value="${1:-}"
  value="${value%/}"
  printf '%s\n' "$value"
}

proxy_env_value_matches_configured_proxy() {
  local value="${1:-}"
  local configured="${CODEX_PROXY_URL:-$DEFAULT_PROXY_URL}"

  [ "$(proxy_url_for_compare "$value")" = "$(proxy_url_for_compare "$configured")" ]
}

local_proxy_is_listening() {
  local proxy_url="${1:-$CODEX_PROXY_URL}"
  local host_port host port python_bin

  host_port="${proxy_url#http://}"
  host_port="${host_port#https://}"
  host_port="${host_port%%/*}"
  port="${host_port##*:}"
  host="${host_port%:*}"

  if [ -z "$port" ] || [ "$port" = "$host_port" ]; then
    return 1
  fi

  if [ -z "$host" ] || [ "$host" = "$host_port" ]; then
    host="127.0.0.1"
  fi
  host="${host#[}"
  host="${host%]}"

  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":${port}[[:space:]]" && return 0
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi

  if python_bin="$(python_command)"; then
    PROXY_LISTEN_HOST="$host" PROXY_LISTEN_PORT="$port" "$python_bin" - <<'PY' && return 0
import os
import socket
import sys

host = os.environ["PROXY_LISTEN_HOST"]
port = int(os.environ["PROXY_LISTEN_PORT"])

try:
    with socket.create_connection((host, port), timeout=1):
        pass
except OSError:
    sys.exit(1)
PY
  fi

  curl -sS --max-time 2 -x "$proxy_url" https://example.com >/dev/null 2>&1
}

mihomo_process_text_matches() {
  awk '
    function matches_mihomo(text) {
      return text ~ /(^|[[:space:]\/])(mihomo|mihomo-linux[^[:space:]\/]*|clash|clash-linux[^[:space:]\/]*)($|[[:space:]])/
    }
    { if (matches_mihomo($0)) found = 1 }
    END { exit found ? 0 : 1 }
  '
}

mihomo_pid_is_running() {
  local pid_file="$CODEX_AUTODL_REPO_ROOT/clash/mihomo.pid"
  local pid process_text

  if [ ! -f "$pid_file" ]; then
    return 1
  fi

  pid="$(cat "$pid_file" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac

  kill -0 "$pid" >/dev/null 2>&1 || return 1
  process_text="$(ps -p "$pid" -o comm= -o args= 2>/dev/null || true)"
  [ -n "$process_text" ] || return 1
  printf '%s\n' "$process_text" | mihomo_process_text_matches
}

proxy_process_is_running() {
  {
    ps -eo comm=,args= 2>/dev/null ||
      ps -ef 2>/dev/null ||
      ps 2>/dev/null
  } | mihomo_process_text_matches
}

local_proxy_is_ready() {
  local proxy_url="${1:-$CODEX_PROXY_URL}"

  local_proxy_is_listening "$proxy_url" && {
    mihomo_pid_is_running || proxy_systemd_is_active
  }
}

clear_dead_local_proxy_env() {
  local name value cleared
  cleared="false"

  if local_proxy_is_ready "$CODEX_PROXY_URL"; then
    return 0
  fi

  for name in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
    value="${!name:-}"
    if [ -n "$value" ] && proxy_env_value_matches_configured_proxy "$value"; then
      unset "$name"
      cleared="true"
    fi
  done

  if [ "$cleared" = "true" ]; then
    if ! proxy_env_is_active; then
      unset no_proxy NO_PROXY
    fi
    log_warn "检测到代理环境指向 $CODEX_PROXY_URL，但 Mihomo 未运行或代理端口不可用；已临时清理失效代理环境"
  fi
}

mihomo_arch_name() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64 | amd64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    armv7*) echo "armv7" ;;
    *) return 1 ;;
  esac
}

mihomo_binary_path() {
  local arch candidate
  arch="$(mihomo_arch_name)" || return 1

  for candidate in \
    "$CODEX_AUTODL_REPO_ROOT/clash/bin/mihomo-linux-$arch" \
    "$CODEX_AUTODL_REPO_ROOT/clash/bin/mihomo" \
    "$CODEX_AUTODL_REPO_ROOT/clash/bin/clash"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

start_existing_mihomo() {
  local config_dir config_file log_dir log_file pid_file mihomo_bin mihomo_pid wait_seconds

  if local_proxy_is_ready "$CODEX_PROXY_URL"; then
    return 0
  fi

  config_dir="$CODEX_AUTODL_REPO_ROOT/clash/conf"
  config_file="$config_dir/config.yaml"
  log_dir="$CODEX_AUTODL_REPO_ROOT/clash/logs"
  log_file="$log_dir/mihomo.log"
  pid_file="$CODEX_AUTODL_REPO_ROOT/clash/mihomo.pid"

  if [ ! -f "$config_file" ]; then
    log_warn "Mihomo 配置不存在: $config_file"
    return 1
  fi

  mihomo_bin="$(mihomo_binary_path)" || {
    log_warn "Mihomo 二进制不存在，请先运行 install-clash.sh"
    return 1
  }

  mkdir -p "$log_dir"

  if [ -f "$pid_file" ]; then
    mihomo_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "${mihomo_pid:-}" ] && kill -0 "$mihomo_pid" >/dev/null 2>&1 && \
      ps -p "$mihomo_pid" -o comm= -o args= 2>/dev/null | mihomo_process_text_matches; then
      log_warn "Mihomo 进程存在但未监听 $CODEX_PROXY_URL，正在重启"
      kill "$mihomo_pid" >/dev/null 2>&1 || true
      sleep 1
      if kill -0 "$mihomo_pid" >/dev/null 2>&1; then
        kill -9 "$mihomo_pid" >/dev/null 2>&1 || true
      fi
    fi
  fi

  log_info "正在启动 Mihomo"
  nohup "$mihomo_bin" -d "$config_dir" > "$log_file" 2>&1 </dev/null &
  mihomo_pid="$!"
  echo "$mihomo_pid" > "$pid_file"

  wait_seconds="${CODEX_MIHOMO_START_WAIT_SECONDS:-10}"
  for _ in $(seq 1 "$wait_seconds"); do
    if ! kill -0 "$mihomo_pid" >/dev/null 2>&1; then
      log_warn "Mihomo 在打开代理端口前已退出"
      tail -n 40 "$log_file" >&2 || true
      return 1
    fi

    if local_proxy_is_listening "$CODEX_PROXY_URL"; then
      log_ok "Mihomo 正在监听 $CODEX_PROXY_URL"
      return 0
    fi
    sleep 1
  done

  log_warn "Mihomo 未能监听 $CODEX_PROXY_URL"
  tail -n 40 "$log_file" >&2 || true
  return 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    log_error "缺少命令: $1"
    return 1
  }
}

set_proxy_env() {
  export http_proxy="$CODEX_PROXY_URL"
  export https_proxy="$CODEX_PROXY_URL"
  export HTTP_PROXY="$CODEX_PROXY_URL"
  export HTTPS_PROXY="$CODEX_PROXY_URL"
  export no_proxy="127.0.0.1,localhost"
  export NO_PROXY="127.0.0.1,localhost"
}

enable_proxy_env() {
  if ! start_existing_mihomo; then
    clear_proxy_env
    log_warn "代理未开启: Mihomo 未监听 $CODEX_PROXY_URL"
    return 1
  fi

  set_proxy_env
  log_ok "代理已开启: $CODEX_PROXY_URL"
}

clear_proxy_env() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY
}

disable_proxy_env() {
  clear_proxy_env
  log_ok "代理已关闭"
}

proxy_service_name() {
  printf '%s\n' 'clash-codex-mihomo.service'
}

user_systemd_available() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

proxy_systemd_is_active() {
  user_systemd_available && systemctl --user is-active --quiet "$(proxy_service_name)" >/dev/null 2>&1
}

wait_for_local_proxy() {
  local wait_seconds="${CODEX_MIHOMO_START_WAIT_SECONDS:-10}"
  for _ in $(seq 1 "$wait_seconds"); do
    local_proxy_is_ready "$CODEX_PROXY_URL" && return 0
    sleep 1
  done
  return 1
}

stop_existing_mihomo() {
  local pid_file pid
  pid_file="$CODEX_AUTODL_REPO_ROOT/clash/mihomo.pid"
  if [ -f "$pid_file" ]; then
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    case "$pid" in
      '' | *[!0-9]*) ;;
      *)
        if kill -0 "$pid" >/dev/null 2>&1 && \
          ps -p "$pid" -o comm= -o args= 2>/dev/null | mihomo_process_text_matches; then
          kill "$pid" >/dev/null 2>&1 || true
          for _ in 1 2 3 4 5; do
            kill -0 "$pid" >/dev/null 2>&1 || break
            sleep 1
          done
          if kill -0 "$pid" >/dev/null 2>&1; then
            kill -9 "$pid" >/dev/null 2>&1 || true
          fi
        fi
        ;;
    esac
  fi
  rm -f "$pid_file"
}

enable_proxy_service() {
  if user_systemd_available && [ -f "$HOME/.config/systemd/user/$(proxy_service_name)" ]; then
    systemctl --user enable --now "$(proxy_service_name)" >/dev/null
  else
    start_existing_mihomo
  fi
}

disable_proxy_service() {
  if user_systemd_available && [ -f "$HOME/.config/systemd/user/$(proxy_service_name)" ]; then
    systemctl --user disable --now "$(proxy_service_name)" >/dev/null 2>&1 || true
  fi
  stop_existing_mihomo
}

proxy_enable_persistent() {
  load_project_config
  PROXY_ENABLED="true"
  save_project_config
  if enable_proxy_service && wait_for_local_proxy; then
    log_ok "代理已永久开启: $CODEX_PROXY_URL"
    return 0
  fi
  log_error "代理开启失败: Mihomo 未监听 $CODEX_PROXY_URL"
  return 1
}

proxy_disable_persistent() {
  load_project_config
  PROXY_ENABLED="false"
  save_project_config
  disable_proxy_service
  log_ok "代理已永久关闭"
}

proxy_print_env() {
  load_project_config
  if [ "$PROXY_ENABLED" = "true" ] && local_proxy_is_ready "$CODEX_PROXY_URL"; then
    printf 'export http_proxy=%q https_proxy=%q HTTP_PROXY=%q HTTPS_PROXY=%q\n' \
      "$CODEX_PROXY_URL" "$CODEX_PROXY_URL" "$CODEX_PROXY_URL" "$CODEX_PROXY_URL"
    printf 'export no_proxy=%q NO_PROXY=%q\n' '127.0.0.1,localhost' '127.0.0.1,localhost'
  else
    printf 'unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY\n'
    return 1
  fi
}

proxy_print_unset_env() {
  printf 'unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY\n'
}

proxy_shell_start() {
  local node
  load_project_config
  if [ "$PROXY_ENABLED" != "true" ]; then
    proxy_print_unset_env
    printf '[proxy] 已关闭\n' >&2
    return 0
  fi
  if ! local_proxy_is_ready "$CODEX_PROXY_URL"; then
    enable_proxy_service >/dev/null 2>&1 || true
  fi
  if local_proxy_is_ready "$CODEX_PROXY_URL" || wait_for_local_proxy; then
    proxy_print_env
    node="$(current_proxy_node)"
    printf '[proxy] 已开启 | 节点: %s\n' "$node" >&2
    return 0
  fi
  proxy_print_unset_env
  printf '[proxy] 启动失败: %s\n' "$CODEX_PROXY_URL" >&2
  return 1
}

current_proxy_node() {
  local tmp_py python_bin yq_bin payload node
  if ! python_bin="$(python_command)"; then
    yq_bin="$CODEX_AUTODL_REPO_ROOT/clash/bin/yq"
    if [ -x "$yq_bin" ] && command -v curl >/dev/null 2>&1; then
      payload="$(curl --noproxy '*' -fsS --max-time 3 \
        "${CODEX_MIHOMO_CONTROLLER_URL%/}/proxies/$CODEX_PROXY_GROUP" 2>/dev/null || true)"
      if [ -z "$payload" ]; then
        printf 'unknown\n'
        return 0
      fi
      node="$(printf '%s' "$payload" | "$yq_bin" eval -r '.now // "DIRECT"' - 2>/dev/null || true)"
      printf '%s\n' "${node:-unknown}"
      return 0
    fi
    printf 'unknown\n'
    return 0
  fi

  tmp_py="$(mktemp)"
  cat > "$tmp_py" <<'PY'
import json
import os
import urllib.error
import urllib.request

base = os.environ.get("CODEX_MIHOMO_CONTROLLER_URL", "http://127.0.0.1:6006").rstrip("/")
group = os.environ.get("CODEX_PROXY_GROUP", "CodexProxy")

try:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f"{base}/proxies/{group}", timeout=3) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    print(payload.get("now") or "DIRECT")
except Exception:
    print("unknown")
PY
  CODEX_MIHOMO_CONTROLLER_URL="$CODEX_MIHOMO_CONTROLLER_URL" \
    CODEX_PROXY_GROUP="$CODEX_PROXY_GROUP" \
    "$python_bin" "$tmp_py"
  rm -f "$tmp_py"
}

function proxy-status {
  local node running="false"
  load_project_config

  if [ "$PROXY_ENABLED" = "true" ]; then
    log_ok "永久代理: 已开启"
  else
    log_warn "永久代理: 已关闭"
  fi
  if proxy_env_is_active; then
    log_ok "当前终端环境: 已开启"
  else
    log_warn "当前终端环境: 未开启"
  fi
  log_info "地址: $CODEX_PROXY_URL"
  if mihomo_pid_is_running || proxy_systemd_is_active; then
    running="true"
    log_ok "Mihomo: 运行中"
  else
    log_warn "Mihomo: 未运行"
  fi
  if [ "$running" = "true" ]; then
    node="$(current_proxy_node)"
  else
    node="unknown"
  fi
  if [ "$node" = "unknown" ]; then
    log_warn "当前节点: unknown"
  else
    log_ok "当前节点: $node"
  fi
}

ensure_local_bin_on_path() {
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
  esac
}

codex_install_manifest() {
  printf '%s/install-manifest\n' "${CLASH_CODEX_AUTODL_DATA_DIR:-$HOME/.local/share/clash-codex-autodl}"
}

file_fingerprint() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print "sha256:" $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print "sha256:" $1}'
  else
    cksum "$path" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

codex_cli_is_usable() {
  local binary_path="$1"
  [ -x "$binary_path" ] || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 "$binary_path" --version >/dev/null 2>&1
  else
    "$binary_path" --version >/dev/null 2>&1
  fi
}

record_project_codex_install() {
  local binary_path="$1" method="${2:-binary}"
  local manifest tmp_file fingerprint
  fingerprint="$(file_fingerprint "$binary_path")" || {
    log_error "无法记录 Codex CLI 文件指纹: $binary_path"
    return 1
  }
  manifest="$(codex_install_manifest)"
  mkdir -p "$(dirname "$manifest")"
  tmp_file="$(mktemp "${manifest}.tmp.XXXXXX")"
  {
    printf 'INSTALLED_BY_PROJECT='
    shell_single_quote true
    printf '\n'
    printf 'CODEX_BINARY_PATH='
    shell_single_quote "$binary_path"
    printf '\n'
    printf 'CODEX_BINARY_FINGERPRINT='
    shell_single_quote "$fingerprint"
    printf '\n'
    printf 'CODEX_INSTALL_METHOD='
    shell_single_quote "$method"
    printf '\n'
  } > "$tmp_file"
  chmod 600 "$tmp_file" 2>/dev/null || true
  mv "$tmp_file" "$manifest"
}

codex_release_archive_name() {
  local machine

  machine="$(uname -m)"
  case "$machine" in
    x86_64 | amd64)
      printf '%s\n' "codex-x86_64-unknown-linux-musl.tar.gz"
      ;;
    aarch64 | arm64)
      printf '%s\n' "codex-aarch64-unknown-linux-musl.tar.gz"
      ;;
    *)
      log_warn "不支持通过 GitHub Release 自动安装 Codex CLI 的 CPU 架构: $machine"
      return 1
      ;;
  esac
}

install_codex_cli_from_github_release() {
  local archive_name
  local github_path
  local mirror
  local url
  local tmp_dir
  local archive_file
  local extract_dir
  local codex_binary
  local mirrors
  local retries
  local max_time

  command -v curl >/dev/null 2>&1 || return 1
  command -v tar >/dev/null 2>&1 || return 1

  archive_name="$(codex_release_archive_name)" || return 1
  github_path="/openai/codex/releases/latest/download/${archive_name}"
  mirrors="github.com ghfast.top/https://github.com"
  tmp_dir="$(mktemp -d)"
  archive_file="$tmp_dir/$archive_name"
  extract_dir="$tmp_dir/extract"
  mkdir -p "$extract_dir" "$HOME/.local/bin"

  for mirror in $mirrors; do
    url="https://${mirror}${github_path}"
    retries=2
    max_time=240
    if [ "$mirror" = "github.com" ]; then
      retries=0
      max_time="${GITHUB_DIRECT_MAX_TIME:-30}"
    fi
    log_info "正在从 $mirror 下载 Codex CLI"
    if curl -fsSL -C - --retry "$retries" --connect-timeout 10 --max-time "$max_time" \
      -o "$archive_file" "$url"; then
      rm -rf "$extract_dir"
      mkdir -p "$extract_dir"
      if tar -xzf "$archive_file" -C "$extract_dir"; then
        codex_binary="$(find "$extract_dir" -type f -name 'codex*' | head -n 1)"
        if [ -n "$codex_binary" ]; then
          cp "$codex_binary" "$HOME/.local/bin/codex"
          chmod +x "$HOME/.local/bin/codex"
          ensure_local_bin_on_path
          if ! codex_cli_is_usable "$HOME/.local/bin/codex"; then
            log_warn "下载的 Codex CLI 无法运行"
            rm -f "$HOME/.local/bin/codex"
            continue
          fi
          record_project_codex_install "$HOME/.local/bin/codex" github-release
          rm -rf "$tmp_dir"
          log_ok "已通过 GitHub Release 安装 Codex CLI: $HOME/.local/bin/codex"
          return 0
        fi
      fi
    fi
  done

  rm -rf "$tmp_dir"
  return 1
}

ensure_codex_cli() {
  local existing
  ensure_local_bin_on_path

  if command -v codex >/dev/null 2>&1; then
    existing="$(command -v codex)"
    if codex_cli_is_usable "$existing"; then
      log_ok "已找到现有 Codex CLI: $existing"
      log_info "将复用该 Codex CLI；本项目只安装 codex-* 管理命令和独立认证配置，不会覆盖它"
      return 0
    fi
    log_warn "发现 codex 命令但无法运行，将继续安装可用的 Codex CLI: $existing"
  fi

  log_info "未找到 Codex CLI，尝试官方独立安装器"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL --connect-timeout 10 --max-time 60 https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh; then
      if command -v codex >/dev/null 2>&1 && codex_cli_is_usable "$(command -v codex)"; then
        record_project_codex_install "$(command -v codex)" official-installer
        log_ok "已通过官方独立安装器安装 Codex CLI"
        return 0
      fi
    fi
    log_warn "独立安装器没有生成可用的 codex 命令"
  fi

  log_info "尝试从 GitHub Release 下载 Codex CLI"
  if install_codex_cli_from_github_release; then
    return 0
  fi
  log_warn "GitHub Release 没有生成可用的 codex 命令"

  log_info "尝试使用 npm 方式安装 @openai/codex"
  if command -v npm >/dev/null 2>&1; then
    npm install -g @openai/codex
    if command -v codex >/dev/null 2>&1 && codex_cli_is_usable "$(command -v codex)"; then
      record_project_codex_install "$(command -v codex)" npm
      log_ok "已通过 npm 安装 Codex CLI"
      return 0
    fi
  fi

  log_error "缺少 Codex CLI。请先安装 Codex，或者安装 Node.js/npm 后重新执行脚本。"
  return 1
}

internal_command_path() {
  printf '%s/command.sh\n' "$CODEX_AUTODL_REPO_ROOT"
}

remove_legacy_shell_hook_blocks() {
  rm -f "$HOME/.codex/clash-autodl-codex.sh" "$HOME/.codex/clash-codex-autodl.sh"
  touch "$HOME/.bashrc"
  sed -i '/# clash-autodl-codex begin/,/# clash-autodl-codex end/d' "$HOME/.bashrc"
  sed -i '/# clash-codex-autodl begin/,/# clash-codex-autodl end/d' "$HOME/.bashrc"
}

install_proxy_systemd_service() {
  local user_dir unit_file mihomo_bin config_dir log_dir
  user_systemd_available || {
    log_info "当前环境不支持 systemd --user，将在首个交互终端中启动 Mihomo"
    return 0
  }
  mihomo_bin="$(mihomo_binary_path)" || return 1
  config_dir="$CODEX_AUTODL_REPO_ROOT/clash/conf"
  log_dir="$CODEX_AUTODL_REPO_ROOT/clash/logs"
  user_dir="$HOME/.config/systemd/user"
  unit_file="$user_dir/$(proxy_service_name)"
  mkdir -p "$user_dir" "$log_dir"
  cat > "$unit_file" <<EOF
[Unit]
Description=clash-codex-autodl Mihomo proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart="$mihomo_bin" -d "$config_dir"
Restart=on-failure
RestartSec=3
StandardOutput="append:$log_dir/mihomo.log"
StandardError="append:$log_dir/mihomo.log"

[Install]
WantedBy=default.target
EOF
  chmod 600 "$unit_file" 2>/dev/null || true
  systemctl --user daemon-reload
  if command -v loginctl >/dev/null 2>&1; then
    if ! loginctl enable-linger "${USER:-$(id -un)}" >/dev/null 2>&1; then
      log_warn "无法启用 systemd linger；注销后将由首个交互终端启动代理"
    fi
  fi
  log_ok "已安装用户级 Mihomo 开机服务"
}

install_proxy_shell_hook() {
  local config_dir data_dir bin_dir hook_file command_path
  config_dir="$(project_config_dir)"
  data_dir="${CLASH_CODEX_AUTODL_DATA_DIR:-$HOME/.local/share/clash-codex-autodl}"
  bin_dir="${CLASH_CODEX_AUTODL_USER_BIN_DIR:-$HOME/.local/bin}"
  hook_file="$config_dir/proxy-shell-init.sh"
  command_path="$(internal_command_path)"
  mkdir -p "$config_dir"
  remove_legacy_shell_hook_blocks

  cat > "$hook_file" <<EOF
# 由 clash-codex-autodl 管理
export CLASH_CODEX_AUTODL_CONFIG_DIR="$config_dir"
export CODEX_AUTODL_CONFIG_DIR="$config_dir"
export CLASH_CODEX_AUTODL_DATA_DIR="$data_dir"
export CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin_dir"
export PATH="$bin_dir:\$PATH"
proxy-on() { "$command_path" proxy enable && eval "\$("$command_path" proxy env)"; }
proxy-off() { "$command_path" proxy disable; eval "\$("$command_path" proxy env-off)"; }
proxy-switch() { "$command_path" proxy switch; }
proxy-status() { "$command_path" proxy status; }
case \$- in
  *i*) eval "\$("$command_path" proxy shell-start)" || true ;;
esac
EOF
  chmod 600 "$hook_file" 2>/dev/null || true
  sed -i '/# clash-codex-autodl-proxy begin/,/# clash-codex-autodl-proxy end/d' "$HOME/.bashrc"
  {
    echo "# clash-codex-autodl-proxy begin"
    echo "[ -f \"$hook_file\" ] && . \"$hook_file\""
    echo "# clash-codex-autodl-proxy end"
  } >> "$HOME/.bashrc"
  log_ok "已安装全局 proxy-* 命令"
}

install_codex_shell_hook() {
  local config_dir data_dir bin_dir hook_file command_path
  config_dir="$(project_config_dir)"
  data_dir="${CLASH_CODEX_AUTODL_DATA_DIR:-$HOME/.local/share/clash-codex-autodl}"
  bin_dir="${CLASH_CODEX_AUTODL_USER_BIN_DIR:-$HOME/.local/bin}"
  hook_file="$config_dir/codex-shell-init.sh"
  command_path="$(internal_command_path)"
  mkdir -p "$config_dir"
  remove_legacy_shell_hook_blocks

  cat > "$hook_file" <<EOF
# 由 clash-codex-autodl 管理
export CLASH_CODEX_AUTODL_CONFIG_DIR="$config_dir"
export CODEX_AUTODL_CONFIG_DIR="$config_dir"
export CLASH_CODEX_AUTODL_DATA_DIR="$data_dir"
export CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin_dir"
export PATH="$bin_dir:\$PATH"
codex() { "$command_path" run "\$@"; }
codex-status() { "$command_path" codex status; }
codex-verify() { "$command_path" codex verify; }
codex-switch() { "$command_path" codex switch; }
codex-sync() { "$command_path" codex sync; }
codex-config() { "$command_path" codex config; }
case \$- in
  *i*) "$command_path" codex shell-status || true ;;
esac
EOF
  chmod 600 "$hook_file" 2>/dev/null || true
  sed -i '/# clash-codex-autodl-codex begin/,/# clash-codex-autodl-codex end/d' "$HOME/.bashrc"
  {
    echo "# clash-codex-autodl-codex begin"
    echo "[ -f \"$hook_file\" ] && . \"$hook_file\""
    echo "# clash-codex-autodl-codex end"
  } >> "$HOME/.bashrc"
  log_ok "已安装 Codex 认证包装命令"
}

install_shell_hook() {
  install_proxy_shell_hook
  install_codex_shell_hook
}

print_daily_commands() {
  cat <<'TEXT'

代理命令:
  proxy-on
  proxy-off
  proxy-switch
  proxy-status

Codex 命令:
  codex-verify
  codex-status
  codex-switch
  codex-sync
  codex-config
TEXT
}

function proxy-switch {
  load_project_config
  local tmp_py python_bin

  python_bin="$(python_command)" || {
    proxy_switch_with_yq
    return
  }

  tmp_py="$(mktemp)"
  cat > "$tmp_py" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

base = os.environ.get("CODEX_MIHOMO_CONTROLLER_URL", "http://127.0.0.1:6006").rstrip("/")
group = os.environ.get("CODEX_PROXY_GROUP", "CodexProxy")
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def fetch_state():
    with opener.open(f"{base}/proxies/{group}", timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


def set_proxy(name):
    payload = json.dumps({"name": name}).encode("utf-8")
    req = urllib.request.Request(
        f"{base}/proxies/{group}",
        data=payload,
        method="PUT",
        headers={"Content-Type": "application/json"},
    )
    with opener.open(req, timeout=10) as resp:
        resp.read()


def render_state(state):
    current = state.get("now") or "DIRECT"
    all_names = state.get("all") or []
    choices = []
    for name in all_names:
        if name not in choices:
            choices.append(name)
    print(f"当前选择: {current}")
    print(f"选择组: {group}")
    print("可用节点:")
    for idx, name in enumerate(choices, 1):
        marker = " [当前]" if name == current else ""
        print(f"  {idx}. {name}{marker}")
    return choices


try:
    choices = render_state(fetch_state())
except urllib.error.URLError as exc:
    print(f"无法连接 Mihomo 控制器 {base}: {exc}", file=sys.stderr)
    raise SystemExit(1)

while True:
    try:
        answer = input("请输入节点编号（r=刷新，q=退出）: ").strip().lower()
    except EOFError:
        print(file=sys.stderr)
        raise SystemExit(1)

    if answer in {"q", "quit", "exit"}:
        raise SystemExit(0)
    if answer in {"r", "refresh"}:
        choices = render_state(fetch_state())
        continue
    if answer.isdigit():
        index = int(answer)
        if 1 <= index <= len(choices):
            target = choices[index - 1]
            try:
                set_proxy(target)
            except urllib.error.URLError as exc:
                print(f"切换 {group} 失败: {exc}", file=sys.stderr)
                raise SystemExit(1)
            print(f"已选择: {target}")
            raise SystemExit(0)
    print("无效选择")
PY
  if CODEX_MIHOMO_CONTROLLER_URL="$CODEX_MIHOMO_CONTROLLER_URL" \
    CODEX_PROXY_GROUP="$CODEX_PROXY_GROUP" \
    "$python_bin" "$tmp_py"; then
    rm -f "$tmp_py"
    return 0
  else
    rm -f "$tmp_py"
    return 1
  fi
}

proxy_switch_with_yq() {
  local yq_bin base state current answer target payload index
  local -a choices
  yq_bin="$CODEX_AUTODL_REPO_ROOT/clash/bin/yq"
  [ -x "$yq_bin" ] || { log_error "缺少可用的 Python 或 yq"; return 1; }
  command -v curl >/dev/null 2>&1 || { log_error "缺少 curl"; return 1; }
  base="${CODEX_MIHOMO_CONTROLLER_URL%/}/proxies/$CODEX_PROXY_GROUP"

  while :; do
    state="$(curl --noproxy '*' -fsS --max-time 10 "$base")" || {
      log_error "无法连接 Mihomo 控制器: $CODEX_MIHOMO_CONTROLLER_URL"
      return 1
    }
    current="$(printf '%s' "$state" | "$yq_bin" eval -r '.now // "DIRECT"' -)"
    mapfile -t choices < <(printf '%s' "$state" | "$yq_bin" eval -r '.all[]' - | awk '!seen[$0]++')
    if [ "${#choices[@]}" -eq 0 ]; then
      log_error "代理选择组中没有可用节点"
      return 1
    fi
    printf '当前选择: %s\n选择组: %s\n可用节点:\n' "$current" "$CODEX_PROXY_GROUP"
    for index in "${!choices[@]}"; do
      if [ "${choices[$index]}" = "$current" ]; then
        printf '  %s. %s [当前]\n' "$((index + 1))" "${choices[$index]}"
      else
        printf '  %s. %s\n' "$((index + 1))" "${choices[$index]}"
      fi
    done
    printf '请输入节点编号（r=刷新，q=退出）: '
    IFS= read -r answer || return 1
    case "$answer" in
      q | Q) return 0 ;;
      r | R) continue ;;
      '' | *[!0-9]*) log_warn "无效选择"; continue ;;
    esac
    if [ "$answer" -lt 1 ] || [ "$answer" -gt "${#choices[@]}" ]; then
      log_warn "无效选择"
      continue
    fi
    target="${choices[$((answer - 1))]}"
    payload="$(CODEX_PROXY_TARGET="$target" "$yq_bin" -n -o=json '{"name": strenv(CODEX_PROXY_TARGET)}')"
    curl --noproxy '*' -fsS --max-time 10 -X PUT \
      -H 'Content-Type: application/json' --data "$payload" "$base" >/dev/null
    printf '已选择: %s\n' "$target"
    return 0
  done
}

codex_smoke_log_summary() {
  local log_file="$1"
  local reason=""

  if [ ! -s "$log_file" ]; then
    return 0
  fi

  if grep -q 'stream disconnected before completion' "$log_file"; then
    reason="$(grep 'stream disconnected before completion' "$log_file" | tail -n 1 | sed 's/^ERROR:[[:space:]]*//')"
  elif grep -q '^ERROR:' "$log_file"; then
    reason="$(grep '^ERROR:' "$log_file" | tail -n 1 | sed 's/^ERROR:[[:space:]]*//')"
  elif grep -qi 'timed out\|timeout' "$log_file"; then
    reason="$(grep -i 'timed out\|timeout' "$log_file" | tail -n 1)"
  fi

  if [ -n "$reason" ]; then
    log_error "原因: $reason"
  fi
}

codex_smoke_test() {
  local codex_status
  local codex_command="${CODEX_CLI_COMMAND:-codex}"
  local had_errexit
  local smoke_timeout="${CODEX_SMOKE_TIMEOUT:-180}"
  local quiet="${CODEX_SMOKE_TEST_QUIET:-false}"
  local tmp_log
  local tmp_output
  local prompt='请只回复: CODEX_READY'

  if [[ "$codex_command" == */* ]]; then
    [ -x "$codex_command" ] || {
      log_error "Codex CLI 不可执行: $codex_command"
      return 1
    }
  else
    require_command "$codex_command" || return 1
  fi
  tmp_log="$(mktemp)"
  tmp_output="$(mktemp)"
  had_errexit="false"
  case "$-" in
    *e*) had_errexit="true" ;;
  esac

  if command -v timeout >/dev/null 2>&1; then
    set +e
    timeout --kill-after=10s "${smoke_timeout}s" \
      "$codex_command" exec --skip-git-repo-check --ephemeral --output-last-message "$tmp_output" "$prompt" \
        </dev/null > "$tmp_log" 2>&1
    codex_status="$?"
  else
    set +e
    "$codex_command" exec --skip-git-repo-check --ephemeral --output-last-message "$tmp_output" "$prompt" \
      </dev/null > "$tmp_log" 2>&1
    codex_status="$?"
  fi

  if [ "$had_errexit" = "true" ]; then
    set -e
  else
    set +e
  fi

  cp "$tmp_log" /tmp/codex-bootstrap-smoke.log 2>/dev/null || true

  if [ "$codex_status" != "0" ]; then
    if [ "$codex_status" = "124" ]; then
      log_error "Codex 验证失败，退出码: 124"
      log_error "原因: 超时（${smoke_timeout}s）"
    else
      log_error "Codex 验证失败，退出码: $codex_status"
    fi
    printf '\033[1;34m[INFO]\033[0m 详细日志: /tmp/codex-bootstrap-smoke.log\n' >&2
    codex_smoke_log_summary "$tmp_log"
    rm -f "$tmp_output" "$tmp_log"
    return 1
  fi

  if grep -Fxq 'CODEX_READY' "$tmp_output"; then
    rm -f "$tmp_output" "$tmp_log"
    if [ "$quiet" != "true" ]; then
      log_ok "Codex 可用"
    fi
    return 0
  fi

  log_error "Codex 验证失败，退出码: 1"
  printf '\033[1;34m[INFO]\033[0m 详细日志: /tmp/codex-bootstrap-smoke.log\n' >&2
  codex_smoke_log_summary "$tmp_log"
  rm -f "$tmp_output" "$tmp_log"
  return 1
}

function codex-verify {
  load_project_config
  codex_smoke_test
}
