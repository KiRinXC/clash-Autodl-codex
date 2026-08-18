#!/usr/bin/env bash

# Codex authentication profiles are isolated with separate CODEX_HOME values.

project_data_dir() {
  printf '%s\n' "${CLASH_CODEX_AUTODL_DATA_DIR:-$HOME/.local/share/clash-codex-autodl}"
}

codex_profiles_dir() {
  printf '%s/codex-homes\n' "$(project_data_dir)"
}

codex_profile_home() {
  case "${1:-}" in
    api | chatgpt)
      printf '%s/%s\n' "$(codex_profiles_dir)" "$1"
      ;;
    *)
      log_error "未知 Codex 认证档案: ${1:-}"
      return 1
      ;;
  esac
}

codex_active_auth_file() {
  printf '%s/active-auth\n' "$(project_config_dir)"
}

codex_api_base_url_file() {
  printf '%s/api-base-url\n' "$(project_config_dir)"
}

codex_active_auth() {
  local state_file value
  state_file="$(codex_active_auth_file)"
  value=""
  if [ -f "$state_file" ]; then
    IFS= read -r value < "$state_file" || true
  fi
  case "$value" in
    api | chatgpt) printf '%s\n' "$value" ;;
    *) printf 'api\n' ;;
  esac
}

save_codex_active_auth() {
  local profile="$1"
  local state_file tmp_file

  codex_profile_home "$profile" >/dev/null || return 1
  state_file="$(codex_active_auth_file)"
  mkdir -p "$(dirname "$state_file")"
  tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
  printf '%s\n' "$profile" > "$tmp_file"
  chmod 600 "$tmp_file" 2>/dev/null || true
  mv "$tmp_file" "$state_file"
}

codex_api_base_url() {
  local url_file profile_config python_bin value
  url_file="$(codex_api_base_url_file)"
  if [ -f "$url_file" ]; then
    head -n 1 "$url_file"
    return 0
  fi

  profile_config="$(codex_profile_home api)/config.toml"
  [ -f "$profile_config" ] || return 0
  value=""
  if python_bin="$(python_command 2>/dev/null)"; then
    value="$("$python_bin" - "$profile_config" <<'PY' 2>/dev/null || true
import sys
import tomllib

with open(sys.argv[1], "rb") as config_file:
    config = tomllib.load(config_file)
provider = config.get("model_providers", {}).get("OpenAI", {})
print(config.get("openai_base_url") or provider.get("base_url", ""))
PY
)"
  fi
  if [ -z "$value" ]; then
    value="$(sed -n 's/^[[:space:]]*base_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$profile_config" | head -n 1)"
  fi
  printf '%s\n' "$value"
}

save_codex_api_base_url() {
  local value="${1:-}"
  local url_file tmp_file

  if [ -n "$value" ]; then
    validate_http_url CODEX_API_BASE_URL "$value" || return 1
  fi

  url_file="$(codex_api_base_url_file)"
  mkdir -p "$(dirname "$url_file")"
  tmp_file="$(mktemp "${url_file}.tmp.XXXXXX")"
  printf '%s\n' "$value" > "$tmp_file"
  chmod 600 "$tmp_file" 2>/dev/null || true
  mv "$tmp_file" "$url_file"
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

  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi

  return 1
}

toml_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

write_codex_profile_config() {
  local profile="$1"
  local home="$2"
  local api_base_url="${3:-}"
  local config_file

  codex_profile_home "$profile" >/dev/null || return 1
  mkdir -p "$home"
  config_file="$home/config.toml"

  {
    printf 'cli_auth_credentials_store = "file"\n'
    printf 'forced_login_method = "%s"\n' "$profile"
    printf 'model_provider = "openai"\n'
    printf 'sqlite_home = "%s"\n' "$(toml_escape "$(codex_shared_sqlite_dir)")"
    if [ -n "${CODEX_MODEL:-}" ]; then
      printf 'model = "%s"\n' "$(toml_escape "$CODEX_MODEL")"
    fi
    if [ -n "${CODEX_REVIEW_MODEL:-}" ]; then
      printf 'review_model = "%s"\n' "$(toml_escape "$CODEX_REVIEW_MODEL")"
    fi
    if [ "$profile" = "api" ] && [ -n "$api_base_url" ]; then
      printf 'openai_base_url = "%s"\n' "$(toml_escape "$api_base_url")"
    fi
  } > "$config_file"

  chmod 600 "$config_file" 2>/dev/null || true
}

rewrite_codex_profile_config_for_shared_sessions() {
  local profile="$1"
  local home="$2"
  local config_file endpoint shared_sqlite tmp_file

  config_file="$home/config.toml"
  [ -f "$config_file" ] || return 0
  endpoint=""
  if [ "$profile" = "api" ]; then
    endpoint="$(codex_api_base_url)"
  fi
  shared_sqlite="$(codex_shared_sqlite_dir)"
  tmp_file="$(mktemp "${config_file}.tmp.XXXXXX")"

  CODEX_SYNC_SQLITE_HOME="$(toml_escape "$shared_sqlite")" \
  CODEX_SYNC_API_BASE_URL="$(toml_escape "$endpoint")" \
  CODEX_SYNC_PROFILE="$profile" \
  awk '
    function write_shared_settings() {
      print "model_provider = \"openai\""
      print "sqlite_home = \"" ENVIRON["CODEX_SYNC_SQLITE_HOME"] "\""
      if (ENVIRON["CODEX_SYNC_PROFILE"] == "api" && ENVIRON["CODEX_SYNC_API_BASE_URL"] != "") {
        print "openai_base_url = \"" ENVIRON["CODEX_SYNC_API_BASE_URL"] "\""
      }
    }
    !inserted && /^[[:space:]]*\[/ {
      write_shared_settings()
      print ""
      inserted = 1
    }
    !inserted && /^[[:space:]]*(model_provider|sqlite_home|openai_base_url)[[:space:]]*=/ { next }
    { print }
    END {
      if (!inserted) {
        write_shared_settings()
      }
    }
  ' "$config_file" > "$tmp_file"
  chmod 600 "$tmp_file" 2>/dev/null || true
  mv "$tmp_file" "$config_file"
}

codex_profile_is_valid() {
  local profile="$1"
  local home codex_bin

  home="$(codex_profile_home "$profile")" || return 1
  [ -d "$home" ] || return 1
  codex_bin="$(codex_binary_path)" || return 1
  CODEX_HOME="$home" "$codex_bin" login status >/dev/null 2>&1
}

legacy_codex_auth_is_api() {
  local auth_file="$HOME/.codex/auth.json"
  local python_bin

  [ -f "$auth_file" ] || return 1
  if python_bin="$(python_command 2>/dev/null)"; then
    "$python_bin" - "$auth_file" <<'PY' >/dev/null 2>&1
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as auth_file:
    auth = json.load(auth_file)
if not auth.get("OPENAI_API_KEY"):
    raise SystemExit(1)
PY
    return
  fi

  grep -Eq '"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"[^"]+"' "$auth_file"
}

migrate_legacy_api_profile() {
  local home root pending codex_bin legacy_config

  home="$(codex_profile_home api)" || return 1
  [ ! -d "$home" ] || return 0
  legacy_codex_auth_is_api || return 0
  codex_bin="$(codex_binary_path)" || return 0

  root="$(codex_profiles_dir)"
  mkdir -p "$root"
  pending="$(mktemp -d "$root/.api.pending.XXXXXX")"
  cp "$HOME/.codex/auth.json" "$pending/auth.json"
  legacy_config="$HOME/.codex/config.toml"
  if [ -f "$legacy_config" ]; then
    cp "$legacy_config" "$pending/config.toml"
  else
    write_codex_profile_config api "$pending"
  fi
  chmod 600 "$pending/auth.json" "$pending/config.toml" 2>/dev/null || true

  if CODEX_HOME="$pending" "$codex_bin" login status >/dev/null 2>&1; then
    replace_codex_profile_dir api "$pending"
    save_codex_active_auth api
    log_ok "已导入旧版 API 认证到独立档案；~/.codex 未修改"
  else
    rm -rf "$pending"
    log_warn "检测到旧版 API 配置，但验证失败，未导入"
  fi
}

codex_profile_action_prompt() {
  local profile="$1"
  local answer

  printf '直接按 Enter 使用现有配置，输入 m 修改配置，输入 v 重新验证，输入 q 取消: ' >&2
  IFS= read -r answer || answer=""
  case "${answer:-}" in
    "") printf 'use\n' ;;
    m | M) printf 'edit\n' ;;
    v | V) printf 'verify\n' ;;
    q | Q) printf 'cancel\n' ;;
    *)
      log_warn "未知选项，使用现有配置"
      printf 'use\n'
      ;;
  esac
}

prompt_optional_url() {
  local label="$1"
  local current="${2:-}"
  local value

  if [ -n "$current" ]; then
    printf '%s [%s]（输入 - 恢复官方默认）: ' "$label" "$current" >&2
  else
    printf '%s（直接回车使用官方地址）: ' "$label" >&2
  fi
  IFS= read -r value || value=""
  if [ -z "$value" ]; then
    value="$current"
  elif [ "$value" = "-" ]; then
    value=""
  fi
  if [ -n "$value" ]; then
    validate_http_url CODEX_API_BASE_URL "$value" || return 1
  fi
  printf '%s\n' "$value"
}

prompt_yes_no_default_no() {
  local label="$1"
  local answer
  printf '%s [y/N]: ' "$label" >&2
  IFS= read -r answer || answer=""
  case "$answer" in
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

replace_codex_profile_dir() {
  local profile="$1"
  local pending="$2"
  local root home backup

  root="$(codex_profiles_dir)"
  home="$(codex_profile_home "$profile")" || return 1
  backup="$root/.${profile}.previous"

  rm -rf "$backup"
  if [ -d "$home" ]; then
    mv "$home" "$backup"
  fi
  if mv "$pending" "$home"; then
    rm -rf "$backup"
    return 0
  fi

  if [ -d "$backup" ]; then
    mv "$backup" "$home"
  fi
  return 1
}

configure_codex_api_profile() {
  local home root pending current_url new_url codex_bin api_key replace_key

  root="$(codex_profiles_dir)"
  home="$(codex_profile_home api)" || return 1
  codex_bin="$(codex_binary_path)" || {
    log_error "未找到 Codex CLI，请先运行 clash-codex setup codex"
    return 1
  }
  mkdir -p "$root"

  current_url="$(codex_api_base_url)"
  new_url="$(prompt_optional_url "API Endpoint" "$current_url")" || return 1
  replace_key="true"
  if codex_profile_is_valid api; then
    if ! prompt_yes_no_default_no "是否更换 API Key？"; then
      replace_key="false"
    fi
  fi

  pending="$(mktemp -d "$root/.api.pending.XXXXXX")"
  if [ "$replace_key" = "false" ] && [ -d "$home" ]; then
    cp -a "$home/." "$pending/"
  fi
  write_codex_profile_config api "$pending" "$new_url"
  codex_link_profile_shared_sessions "$pending" api-pending

  if [ "$replace_key" = "true" ]; then
    api_key="$(prompt_secret "请输入 OpenAI API Key")"
    if ! printf '%s\n' "$api_key" | CODEX_HOME="$pending" "$codex_bin" login --with-api-key; then
      rm -rf "$pending"
      log_error "API 认证失败，已保留原配置"
      return 1
    fi
    unset api_key
  fi

  if ! CODEX_HOME="$pending" "$codex_bin" login status >/dev/null 2>&1; then
    rm -rf "$pending"
    log_error "API 认证验证失败，已保留原配置"
    return 1
  fi

  replace_codex_profile_dir api "$pending" || return 1
  save_codex_api_base_url "$new_url"
  save_codex_active_auth api
  log_ok "已保存并启用 API 认证档案"
}

configure_codex_chatgpt_profile() {
  local root pending codex_bin

  root="$(codex_profiles_dir)"
  codex_bin="$(codex_binary_path)" || {
    log_error "未找到 Codex CLI，请先运行 clash-codex setup codex"
    return 1
  }
  mkdir -p "$root"
  pending="$(mktemp -d "$root/.chatgpt.pending.XXXXXX")"
  write_codex_profile_config chatgpt "$pending"
  codex_link_profile_shared_sessions "$pending" chatgpt-pending

  if ! CODEX_HOME="$pending" "$codex_bin" login --device-auth; then
    rm -rf "$pending"
    log_error "ChatGPT 认证失败，已保留原配置"
    return 1
  fi
  if ! CODEX_HOME="$pending" "$codex_bin" login status >/dev/null 2>&1; then
    rm -rf "$pending"
    log_error "ChatGPT 认证验证失败，已保留原配置"
    return 1
  fi

  replace_codex_profile_dir chatgpt "$pending" || return 1
  save_codex_active_auth chatgpt
  log_ok "已保存并启用 ChatGPT 认证档案"
}

use_codex_auth_profile() {
  local profile="$1"

  if ! codex_profile_is_valid "$profile"; then
    log_error "$profile 认证档案不存在或已经失效"
    return 1
  fi
  save_codex_active_auth "$profile"
  log_ok "已切换到 $profile 认证"
}

manage_codex_auth_profile() {
  local profile="$1"
  local mode="${2:-interactive}"
  local action

  codex_profile_home "$profile" >/dev/null || return 1
  if [ "$profile" = "api" ]; then
    migrate_legacy_api_profile
  fi
  codex_initialize_session_sync
  case "$mode" in
    use)
      use_codex_auth_profile "$profile"
      return
      ;;
    edit)
      action="edit"
      ;;
    interactive)
      if codex_profile_is_valid "$profile"; then
        log_ok "$profile 认证已配置且有效"
        action="$(codex_profile_action_prompt "$profile")"
      else
        log_warn "$profile 认证尚未配置或已经失效"
        action="edit"
      fi
      ;;
    *)
      log_error "未知认证操作: $mode"
      return 1
      ;;
  esac

  case "$action" in
    use)
      use_codex_auth_profile "$profile"
      ;;
    verify)
      use_codex_auth_profile "$profile"
      ;;
    edit)
      case "$profile" in
        api) configure_codex_api_profile ;;
        chatgpt) configure_codex_chatgpt_profile ;;
      esac
      ;;
    cancel)
      log_info "已取消认证切换"
      ;;
  esac
}

codex_auth_command() {
  local profile="${1:-}"
  local option="${2:-}"
  local mode="interactive"

  if [ "$#" -gt 2 ]; then
    log_error "用法: clash-codex auth [api|chatgpt|status] [--use|--edit]"
    return 1
  fi

  case "$profile" in
    api | chatgpt) ;;
    status | "")
      if [ -n "$option" ]; then
        log_error "用法: clash-codex auth [api|chatgpt|status] [--use|--edit]"
        return 1
      fi
      codex_profiles_status
      return
      ;;
    *)
      log_error "用法: clash-codex auth [api|chatgpt|status] [--use|--edit]"
      return 1
      ;;
  esac

  case "$option" in
    "") mode="interactive" ;;
    --use) mode="use" ;;
    --edit | --reset) mode="edit" ;;
    *)
      log_error "未知参数: $option"
      return 1
      ;;
  esac
  manage_codex_auth_profile "$profile" "$mode"
}

codex_profiles_status() {
  local active profile
  active="$(codex_active_auth)"
  log_info "当前 Codex 认证: $active"
  for profile in api chatgpt; do
    if codex_profile_is_valid "$profile"; then
      log_ok "$profile 认证: 已配置"
    else
      log_warn "$profile 认证: 未配置或已失效"
    fi
  done
  log_info "Codex Home: $(codex_profile_home "$active")"
}

run_codex_with_active_profile() {
  local active home codex_bin
  active="$(codex_active_auth)"
  codex_initialize_session_sync
  home="$(codex_profile_home "$active")" || return 1
  codex_bin="$(codex_binary_path)" || {
    log_error "未找到 Codex CLI"
    return 1
  }
  if [ ! -d "$home" ]; then
    log_error "$active 认证尚未配置，请先运行 clash-codex auth $active"
    return 1
  fi
  CODEX_HOME="$home" exec "$codex_bin" "$@"
}
