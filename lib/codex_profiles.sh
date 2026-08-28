#!/usr/bin/env bash

# API and ChatGPT credentials stay isolated. Sessions are shared separately.

project_data_dir() {
  printf '%s\n' "${CLASH_CODEX_AUTODL_DATA_DIR:-$HOME/.local/share/clash-codex-autodl}"
}

codex_profiles_dir() {
  printf '%s/codex-homes\n' "$(project_data_dir)"
}

codex_profile_home() {
  case "${1:-}" in
    api | chatgpt) printf '%s/%s\n' "$(codex_profiles_dir)" "$1" ;;
    *) log_error "未知 Codex 配置: ${1:-}"; return 1 ;;
  esac
}

codex_active_auth_file() {
  printf '%s/active-auth\n' "$(project_config_dir)"
}

codex_api_source_file() {
  printf '%s/api-profile.toml\n' "$(project_config_dir)"
}

codex_last_verify_file() {
  printf '%s/last-verify\n' "$(project_config_dir)"
}

codex_sync_lock_dir() {
  printf '%s/codex-sync.lock\n' "$(project_data_dir)"
}

codex_active_auth() {
  local value=""
  if [ -f "$(codex_active_auth_file)" ]; then
    IFS= read -r value < "$(codex_active_auth_file)" || true
  fi
  case "$value" in
    api | chatgpt) printf '%s\n' "$value" ;;
    *) printf 'api\n' ;;
  esac
}

save_codex_active_auth() {
  local profile="$1" file tmp
  codex_profile_home "$profile" >/dev/null || return 1
  file="$(codex_active_auth_file)"
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  printf '%s\n' "$profile" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
}

codex_binary_path() {
  local candidate
  if [ -n "${CLASH_CODEX_AUTODL_CODEX_BINARY:-}" ] && [ -x "$CLASH_CODEX_AUTODL_CODEX_BINARY" ]; then
    printf '%s\n' "$CLASH_CODEX_AUTODL_CODEX_BINARY"
    return 0
  fi
  for candidate in "$HOME/.local/bin/codex" "$(project_data_dir)/bin/codex-real"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  command -v codex 2>/dev/null || return 1
}

toml_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

codex_profile_is_configured() {
  local home
  home="$(codex_profile_home "$1")" || return 1
  [ -s "$home/config.toml" ] && [ -s "$home/auth.json" ]
}

codex_api_source_key() {
  local file="${1:-$(codex_api_source_file)}" value python_bin
  [ -f "$file" ] || return 1
  if python_bin="$(python_command 2>/dev/null)"; then
    value="$("$python_bin" - "$file" <<'PY' 2>/dev/null || true
import sys
import tomllib

with open(sys.argv[1], "rb") as source:
    value = tomllib.load(source).get("api_key", "")
if isinstance(value, str):
    print(value)
PY
)"
  else
    value="$(sed -n 's/^[[:space:]]*api_key[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1)"
  fi
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

codex_api_source_toml_is_valid() {
  local file="${1:-$(codex_api_source_file)}" python_bin
  [ -f "$file" ] || return 1
  if python_bin="$(python_command 2>/dev/null)"; then
    "$python_bin" - "$file" <<'PY' >/dev/null 2>&1
import sys
import tomllib

with open(sys.argv[1], "rb") as source:
    tomllib.load(source)
PY
  fi
}

codex_api_source_is_usable() {
  local file="${1:-$(codex_api_source_file)}" raw_config status
  [ -f "$file" ] || return 1
  codex_api_source_toml_is_valid "$file" || return 1
  codex_api_source_key "$file" >/dev/null 2>&1 || return 1
  raw_config="$(mktemp)"
  status=0
  codex_extract_source_config "$file" "$raw_config" >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 0 ] && ! grep -Eq '^[[:space:]]*model_provider[[:space:]]*=' "$raw_config"; then
    status=1
  fi
  rm -f "$raw_config"
  return "$status"
}

codex_backup_invalid_api_source() {
  local source="${1:-$(codex_api_source_file)}" backup
  [ -f "$source" ] || return 1
  backup="${source}.invalid.$(date -u +%Y%m%dT%H%M%SZ).$$"
  mv "$source" "$backup"
  chmod 600 "$backup" 2>/dev/null || true
  printf '%s\n' "$backup"
}

codex_extract_source_config() {
  local file="$1" output="$2"
  awk '!/^[[:space:]]*api_key[[:space:]]*=/' "$file" > "$output"
  [ -s "$output" ] || {
    log_error "API 配置中缺少 config.toml 内容"
    return 1
  }
}

codex_write_api_source() {
  local url="$1" key="$2" file tmp
  file="$(codex_api_source_file)"
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  {
    printf '%s\n' '# clash-codex-autodl API profile'
    printf '%s\n' '# 除 api_key 外，其余内容会作为 Codex config.toml。'
    printf 'api_key = "%s"\n' "$(toml_escape "$key")"
    printf '%s\n' 'cli_auth_credentials_store = "file"'
    printf '%s\n' 'forced_login_method = "api"'
    printf '%s\n' 'model_provider = "openai"'
    if [ -n "$url" ]; then
      printf 'openai_base_url = "%s"\n' "$(toml_escape "$url")"
    fi
  } > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  if ! codex_api_source_toml_is_valid "$tmp"; then
    rm -f "$tmp"
    log_error "生成的 API 配置不是有效 TOML；粘贴内容可能含有不可见控制字符"
    return 1
  fi
  mv "$tmp" "$file"
}

codex_config_model_provider() {
  local config_file="$1" value
  value="$(sed -n 's/^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config_file" | head -n 1)"
  printf '%s\n' "${value:-openai}"
}

codex_config_api_url() {
  local config_file="$1" provider value python_bin
  [ -f "$config_file" ] || return 0
  if python_bin="$(python_command 2>/dev/null)"; then
    value="$("$python_bin" - "$config_file" <<'PY' 2>/dev/null || true
import re
import sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
def string_value(pattern):
    match = re.search(pattern, text, re.MULTILINE)
    return match.group(1) if match else ""

provider = string_value(r'^\s*model_provider\s*=\s*"([^"]+)"') or "openai"
url = string_value(r'^\s*openai_base_url\s*=\s*"([^"]+)"')
if not url:
    section = re.search(r'^\s*\[model_providers\.' + re.escape(provider) + r'\]\s*$([\s\S]*?)(?=^\s*\[|\Z)', text, re.MULTILINE)
    if section:
        match = re.search(r'^\s*base_url\s*=\s*"([^"]+)"', section.group(1), re.MULTILINE)
        if match:
            url = match.group(1)
print(url)
PY
)"
    printf '%s\n' "$value"
    return 0
  fi
  value="$(sed -n 's/^[[:space:]]*openai_base_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config_file" | head -n 1)"
  if [ -z "$value" ]; then
    provider="$(codex_config_model_provider "$config_file")"
    value="$(awk -v section="[model_providers.$provider]" '
      $0 == section { found = 1; next }
      found && /^[[:space:]]*\[/ { exit }
      found && /^[[:space:]]*base_url[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*"/, ""); sub(/".*/, ""); print; exit
      }
    ' "$config_file")"
  fi
  printf '%s\n' "$value"
}

codex_inject_managed_config() {
  local source="$1" output="$2" sqlite_home
  sqlite_home="$(toml_escape "$(codex_shared_sqlite_dir)")"
  CODEX_SHARED_SQLITE_HOME="$sqlite_home" awk '
    function managed() { print "sqlite_home = \"" ENVIRON["CODEX_SHARED_SQLITE_HOME"] "\"" }
    !inserted && /^[[:space:]]*\[/ { managed(); print ""; inserted = 1 }
    !inserted && /^[[:space:]]*sqlite_home[[:space:]]*=/ { next }
    { print }
    END { if (!inserted) managed() }
  ' "$source" > "$output"
}

replace_codex_profile_dir() {
  local profile="$1" pending="$2" root home backup
  root="$(codex_profiles_dir)"
  home="$(codex_profile_home "$profile")" || return 1
  backup="$root/.${profile}.previous"
  rm -rf "$backup"
  [ ! -d "$home" ] || mv "$home" "$backup"
  if mv "$pending" "$home"; then
    rm -rf "$backup"
    return 0
  fi
  [ ! -d "$backup" ] || mv "$backup" "$home"
  return 1
}

apply_codex_api_source() {
  local source root pending raw_config key codex_bin
  source="$(codex_api_source_file)"
  [ -f "$source" ] || { log_error "API 配置不存在: $source"; return 1; }
  codex_api_source_toml_is_valid "$source" || {
    log_error "API 配置不是有效 TOML: $source"
    log_error "请运行 codex-config 修复；右键粘贴时请避免带入换行或不可见控制字符"
    return 1
  }
  key="$(codex_api_source_key "$source")" || {
    log_error "API 配置中的 api_key 不能为空"
    return 1
  }
  codex_bin="$(codex_binary_path)" || { log_error "未找到 Codex CLI"; return 1; }
  root="$(codex_profiles_dir)"
  mkdir -p "$root"
  pending="$(mktemp -d "$root/.api.pending.XXXXXX")"
  raw_config="$(mktemp)"
  if ! codex_extract_source_config "$source" "$raw_config" || \
     ! grep -Eq '^[[:space:]]*model_provider[[:space:]]*=' "$raw_config"; then
    rm -rf "$pending" "$raw_config"
    log_error "API 配置必须包含 model_provider"
    return 1
  fi
  codex_inject_managed_config "$raw_config" "$pending/config.toml"
  rm -f "$raw_config"
  chmod 600 "$pending/config.toml" 2>/dev/null || true
  codex_link_profile_shared_sessions "$pending" api-pending
  if ! printf '%s\n' "$key" | CODEX_HOME="$pending" "$codex_bin" login --with-api-key >/dev/null; then
    rm -rf "$pending"
    log_error "Codex CLI 未能保存 API 凭据；原运行配置未修改"
    return 1
  fi
  unset key
  replace_codex_profile_dir api "$pending" || return 1
  log_ok "API 配置已保存（尚未进行模型调用验证）"
}

configure_codex_api_initial() {
  local current_url="${1:-}" url key source
  source="$(codex_api_source_file)"
  if [ -z "$current_url" ] && [ -f "$source" ]; then
    current_url="$(codex_config_api_url "$source")"
  fi
  if [ -z "$current_url" ] && [ -f "$(codex_profile_home api)/config.toml" ]; then
    current_url="$(codex_config_api_url "$(codex_profile_home api)/config.toml")"
  fi
  log_info "API 文本配置将保存到: $source"
  log_info "Codex CLI 可执行文件不是配置文件，请不要使用 cat 或编辑器打开 codex 二进制文件"
  url="$(prompt_required "请输入 API 地址" "$current_url")"
  validate_http_url CODEX_API_BASE_URL "$url" || return 1
  log_info "API Key 使用隐藏输入：右键粘贴后屏幕不会显示字符，按 Enter 即可"
  key="$(prompt_secret "请输入 API Key")"
  if ! codex_write_api_source "$url" "$key"; then
    unset key
    return 1
  fi
  unset key
  apply_codex_api_source
  save_codex_active_auth api
}

configure_codex_chatgpt_profile() {
  local root pending codex_bin raw
  codex_bin="$(codex_binary_path)" || { log_error "未找到 Codex CLI"; return 1; }
  root="$(codex_profiles_dir)"
  mkdir -p "$root"
  pending="$(mktemp -d "$root/.chatgpt.pending.XXXXXX")"
  raw="$(mktemp)"
  {
    printf '%s\n' 'cli_auth_credentials_store = "file"'
    printf '%s\n' 'forced_login_method = "chatgpt"'
    printf '%s\n' 'model_provider = "openai"'
  } > "$raw"
  codex_inject_managed_config "$raw" "$pending/config.toml"
  rm -f "$raw"
  chmod 600 "$pending/config.toml" 2>/dev/null || true
  codex_link_profile_shared_sessions "$pending" chatgpt-pending
  if ! CODEX_HOME="$pending" "$codex_bin" login --device-auth; then
    rm -rf "$pending"
    log_error "ChatGPT 登录失败；原配置未修改"
    return 1
  fi
  replace_codex_profile_dir chatgpt "$pending" || return 1
  log_ok "ChatGPT 登录已保存"
}

codex_pick_editor() {
  if [ -n "${CODEX_CONFIG_EDITOR:-}" ]; then printf '%s\n' "$CODEX_CONFIG_EDITOR"; return; fi
  if [ -n "${VISUAL:-}" ]; then printf '%s\n' "$VISUAL"; return; fi
  if [ -n "${EDITOR:-}" ]; then printf '%s\n' "$EDITOR"; return; fi
  command -v nano 2>/dev/null || command -v vim 2>/dev/null || command -v vi 2>/dev/null || return 1
}

open_codex_api_source() {
  local file editor
  file="$(codex_api_source_file)"
  if [ ! -f "$file" ]; then
    log_warn "API 文本配置不存在，将重新创建: $file"
    configure_codex_api_initial
    return
  fi
  editor="$(codex_pick_editor)" || { log_error "未找到编辑器，请设置 EDITOR"; return 1; }
  log_info "正在编辑 API 文本配置: $file"
  log_info "请勿编辑或 cat Codex CLI 可执行文件；保存此 TOML 后会自动生成运行配置"
  sh -c "$editor \"\$1\"" sh "$file" || return 1
  apply_codex_api_source
}

codex_acquire_sync_lock() {
  local lock pid
  lock="$(codex_sync_lock_dir)"
  mkdir -p "$(dirname "$lock")"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid"
    return 0
  fi
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && ! kill -0 "$pid" >/dev/null 2>&1; then
    rm -rf "$lock"
    mkdir "$lock"
    printf '%s\n' "$$" > "$lock/pid"
    return 0
  fi
  log_error "另一个 Codex 切换或同步正在进行"
  return 1
}

codex_release_sync_lock() {
  local lock
  lock="$(codex_sync_lock_dir)"
  [ "$(cat "$lock/pid" 2>/dev/null || true)" != "$$" ] || rm -rf "$lock"
}

codex_sync_profile() {
  local profile="$1" provider status
  codex_profile_is_configured "$profile" || { log_error "$profile 配置尚未完成"; return 1; }
  if codex_process_is_running; then
    log_error "同步前请先关闭其他 Codex CLI / Codex App 进程"
    return 1
  fi
  codex_acquire_sync_lock || return 1
  provider="$(codex_config_model_provider "$(codex_profile_home "$profile")/config.toml")"
  status=0
  codex_initialize_session_sync true "$provider" || status=$?
  codex_release_sync_lock
  return "$status"
}

codex_switch_profile() {
  local active target
  active="$(codex_active_auth)"
  if [ "$active" = api ]; then target=chatgpt; else target=api; fi
  if ! codex_profile_is_configured "$target"; then
    case "$target" in
      api) apply_codex_api_source ;;
      chatgpt) configure_codex_chatgpt_profile ;;
    esac || return 1
  fi
  codex_sync_profile "$target" || return 1
  save_codex_active_auth "$target"
  log_ok "已切换到 $target 配置并同步会话"
}

codex_manual_sync() {
  local active
  active="$(codex_active_auth)"
  codex_sync_profile "$active"
  codex_sessions_status
}

codex_profiles_status() {
  local active profile home url last
  active="$(codex_active_auth)"
  if [ "$active" = api ]; then
    url="$(codex_config_api_url "$(codex_profile_home api)/config.toml")"
    log_info "当前配置: API"
    log_info "API URL: ${url:-OpenAI 默认地址}"
  else
    log_info "当前配置: ChatGPT"
  fi
  for profile in api chatgpt; do
    home="$(codex_profile_home "$profile")"
    if codex_profile_is_configured "$profile"; then
      log_ok "$profile: 已配置"
    else
      log_warn "$profile: 未配置"
    fi
  done
  last="$(codex_last_verify_file)"
  [ ! -s "$last" ] || log_info "最近验证: $(cat "$last")"
}

codex_shell_status() {
  local active home url shared rollout_count sync_state
  active="$(codex_active_auth)"
  home="$(codex_profile_home "$active")"
  if codex_profile_is_configured "$active"; then
    if [ "$active" = api ]; then
      url="$(codex_config_api_url "$home/config.toml")"
      printf '[codex] API | %s\n' "${url:-OpenAI 默认地址}"
    else
      printf '[codex] ChatGPT\n'
    fi
  else
    printf '[codex] 未配置\n'
  fi

  shared="$(codex_shared_state_dir)"
  rollout_count="$(codex_session_rollout_count)"
  if ! codex_session_sync_is_initialized; then
    sync_state="待初始化"
  elif [ -L "$home/sessions" ] && [ "$(readlink "$home/sessions" 2>/dev/null || true)" = "$shared/sessions" ]; then
    sync_state="已同步"
  else
    sync_state="待同步"
  fi
  printf '[sync] %s | %s 个会话\n' "$sync_state" "$rollout_count"
}

codex_record_verify() {
  local result="$1" file tmp
  file="$(codex_last_verify_file)"
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$result" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
}

verify_active_codex_profile() {
  local active home codex_bin
  active="$(codex_active_auth)"
  codex_profile_is_configured "$active" || { log_error "$active 配置尚未完成"; return 1; }
  home="$(codex_profile_home "$active")"
  codex_bin="$(codex_binary_path)" || { log_error "未找到 Codex CLI"; return 1; }
  if CODEX_HOME="$home" CODEX_CLI_COMMAND="$codex_bin" codex_smoke_test; then
    codex_record_verify success
    return 0
  fi
  codex_record_verify failed
  return 1
}

configure_active_codex_profile() {
  case "$(codex_active_auth)" in
    api) open_codex_api_source ;;
    chatgpt) configure_codex_chatgpt_profile ;;
  esac
}

run_codex_with_active_profile() {
  local active home codex_bin provider
  active="$(codex_active_auth)"
  codex_profile_is_configured "$active" || { log_error "$active 配置尚未完成"; return 1; }
  home="$(codex_profile_home "$active")"
  provider="$(codex_config_model_provider "$home/config.toml")"
  codex_initialize_session_sync false "$provider" || return 1
  codex_bin="$(codex_binary_path)" || { log_error "未找到 Codex CLI"; return 1; }
  CODEX_HOME="$home" exec "$codex_bin" "$@"
}

codex_migrate_api_source() {
  local home source config auth key python_bin pending backup
  source="$(codex_api_source_file)"
  codex_api_source_is_usable "$source" && return 0
  home="$(codex_profile_home api)"
  config="$home/config.toml"
  auth="$home/auth.json"
  [ -s "$config" ] && [ -s "$auth" ] || return 0
  key=""
  if python_bin="$(python_command 2>/dev/null)"; then
    key="$("$python_bin" - "$auth" <<'PY' 2>/dev/null || true
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8")).get("OPENAI_API_KEY", "")
    print(value)
except Exception:
    pass
PY
)"
  fi
  [ -n "$key" ] || key="$(sed -n 's/.*"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$auth" | head -n 1)"
  [ -n "$key" ] || {
    log_warn "已有 API 档案无法提取 API Key；运行 codex-config 前需要重新安装 Codex 配置"
    return 0
  }
  mkdir -p "$(dirname "$source")"
  pending="$(mktemp "${source}.migrate.XXXXXX")"
  {
    printf '%s\n' '# clash-codex-autodl API profile (migrated)'
    printf 'api_key = "%s"\n' "$(toml_escape "$key")"
    sed '/^[[:space:]]*sqlite_home[[:space:]]*=/d' "$config"
  } > "$pending"
  chmod 600 "$pending" 2>/dev/null || true
  if ! codex_api_source_is_usable "$pending"; then
    rm -f "$pending"
    unset key
    log_warn "已有 API 档案无法生成有效的单文件配置"
    return 0
  fi
  if [ -f "$source" ]; then
    backup="$(codex_backup_invalid_api_source "$source")"
    log_warn "已备份无效的旧 API 文本配置: $backup"
  fi
  mv "$pending" "$source"
  unset key
  log_ok "已迁移旧 API 配置到单文件数据源"
}
