#!/usr/bin/env bash

# Authentication snapshots are stored in the project data directory. Codex
# itself always runs against the user's native CODEX_HOME. Switching replaces
# auth.json completely and merges only profile-related config.toml fields.

project_data_dir() {
  printf '%s\n' "${CLASH_CODEX_AUTODL_DATA_DIR:-$HOME/.local/share/clash-codex-autodl}"
}

codex_profiles_dir() {
  printf '%s/codex-profiles\n' "$(project_data_dir)"
}

codex_legacy_profiles_dir() {
  printf '%s/codex-homes\n' "$(project_data_dir)"
}

codex_native_home() {
  printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"
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

codex_last_sync_file() {
  printf '%s/last-sync\n' "$(project_config_dir)"
}

codex_sync_lock_dir() {
  printf '%s/codex-sync.lock\n' "$(project_data_dir)"
}

codex_native_config_file() {
  printf '%s/config.toml\n' "$(codex_native_home)"
}

codex_native_auth_file() {
  printf '%s/auth.json\n' "$(codex_native_home)"
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
  if [ -n "${CLASH_CODEX_AUTODL_CODEX_BINARY:-}" ] && \
    codex_cli_is_usable "$CLASH_CODEX_AUTODL_CODEX_BINARY"; then
    printf '%s\n' "$CLASH_CODEX_AUTODL_CODEX_BINARY"
    return 0
  fi
  for candidate in "$HOME/.local/bin/codex" "$(project_data_dir)/bin/codex-real"; do
    if codex_cli_is_usable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  candidate="$(command -v codex 2>/dev/null || true)"
  [ -n "$candidate" ] && codex_cli_is_usable "$candidate" || return 1
  printf '%s\n' "$candidate"
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

codex_auth_method_from_file() {
  local file="$1" value python_bin
  [ -s "$file" ] || return 1

  if python_bin="$(python_command 2>/dev/null)"; then
    value="$("$python_bin" - "$file" <<'PY' 2>/dev/null || true
import json
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as source:
        auth = json.load(source)
except Exception:
    raise SystemExit(0)

mode = re.sub(r"[^a-z]", "", str(auth.get("auth_mode", "")).lower())
if mode in {"chatgpt", "chatgptauthtokens"}:
    print("chatgpt")
elif mode in {"api", "apikey"}:
    print("api")
elif isinstance(auth.get("OPENAI_API_KEY"), str) and auth["OPENAI_API_KEY"].strip():
    print("api")
elif isinstance(auth.get("tokens"), dict) and any(auth["tokens"].values()):
    print("chatgpt")
PY
)"
    case "$value" in
      api | chatgpt) printf '%s\n' "$value"; return 0 ;;
    esac
  fi

  if grep -Eqi '"auth_mode"[[:space:]]*:[[:space:]]*"(chatgpt|chatgpt[_-]?auth[_-]?tokens)"' "$file" ||
    grep -Eq '"tokens"[[:space:]]*:[[:space:]]*\{' "$file"; then
    printf 'chatgpt\n'
    return 0
  fi
  if grep -Eqi '"auth_mode"[[:space:]]*:[[:space:]]*"(api|api[_-]?key)"' "$file" ||
    grep -Eq '"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"[^"[:space:]][^"]*"' "$file"; then
    printf 'api\n'
    return 0
  fi
  return 1
}

codex_login_status_method() {
  local home="$1" codex_bin output="" method=""
  codex_bin="$(codex_binary_path)" || return 1
  if command -v timeout >/dev/null 2>&1; then
    output="$(CODEX_HOME="$home" timeout 15 "$codex_bin" login status 2>&1 || true)"
  else
    output="$(CODEX_HOME="$home" "$codex_bin" login status 2>&1 || true)"
  fi
  case "$output" in
    *'Logged in using ChatGPT'*) method="chatgpt" ;;
    *'Logged in using an API key'*) method="api" ;;
    *'Logged in using personal access token'*) method="personal-access-token" ;;
    *'Logged in using access token'*) method="access-token" ;;
    *'Logged in using workload identity'*) method="workload-identity" ;;
    *'Logged in using Amazon Bedrock'*) method="amazon-bedrock" ;;
  esac
  [ -n "$method" ] || return 1
  printf '%s\n' "$method"
}

codex_detect_native_profile() {
  local native_home method
  CODEX_NATIVE_HOME="$(codex_native_home)"
  CODEX_NATIVE_AUTH_METHOD=""
  CODEX_NATIVE_AUTH_STORAGE="none"
  native_home="${CODEX_NATIVE_HOME%/}"

  # Prefer parsing file credentials. Running `codex login status` while an old
  # forced_login_method disagrees with auth.json can make Codex log out.
  method="$(codex_auth_method_from_file "$native_home/auth.json" 2>/dev/null || true)"
  if [ -n "$method" ]; then
    # Consumed by install-codex.sh after this detector returns.
    # shellcheck disable=SC2034
    CODEX_NATIVE_AUTH_STORAGE="file"
  else
    method="$(codex_login_status_method "$native_home" 2>/dev/null || true)"
    [ -n "$method" ] || return 1
    # Consumed by install-codex.sh after this detector returns.
    # shellcheck disable=SC2034
    CODEX_NATIVE_AUTH_STORAGE="keyring"
  fi
  case "$method" in
    api | chatgpt | personal-access-token | access-token | workload-identity | amazon-bedrock) ;;
    *) return 1 ;;
  esac
  # Consumed by install-codex.sh after this detector returns.
  # shellcheck disable=SC2034
  CODEX_NATIVE_AUTH_METHOD="$method"
}

codex_api_source_key() {
  local file="${1:-$(codex_api_source_file)}" value="" python_bin
  [ -f "$file" ] || return 1
  if python_bin="$(python_command 2>/dev/null)"; then
    value="$("$python_bin" - "$file" <<'PY' 2>/dev/null || true
import sys
try:
    import tomllib
except ModuleNotFoundError:
    raise SystemExit(0)
with open(sys.argv[1], "rb") as source:
    value = tomllib.load(source).get("api_key", "")
if isinstance(value, str):
    print(value)
PY
)"
  fi
  if [ -z "$value" ]; then
    value="$(sed -n 's/^[[:space:]]*api_key[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1)"
  fi
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

codex_auth_api_key() {
  local file="$1" value="" python_bin
  [ -s "$file" ] || return 1
  if python_bin="$(python_command 2>/dev/null)"; then
    value="$("$python_bin" - "$file" <<'PY' 2>/dev/null || true
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as source:
        value = json.load(source).get("OPENAI_API_KEY", "")
    if isinstance(value, str):
        print(value)
except Exception:
    pass
PY
)"
  fi
  if [ -z "$value" ]; then
    value="$(sed -n 's/.*"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1)"
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
try:
    import tomllib
except ModuleNotFoundError:
    raise SystemExit(0)
with open(sys.argv[1], "rb") as source:
    tomllib.load(source)
PY
  fi
}

codex_extract_source_config() {
  local file="$1" output="$2"
  awk '!/^[[:space:]]*api_key[[:space:]]*=/' "$file" > "$output"
  [ -s "$output" ] || { log_error "API 配置中缺少 config.toml 内容"; return 1; }
}

codex_config_model_provider() {
  local config_file="$1" value
  value="$(sed -n 's/^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config_file" 2>/dev/null | head -n 1)"
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

codex_api_source_is_usable() {
  local file="${1:-$(codex_api_source_file)}" raw_config status url
  [ -f "$file" ] || return 1
  codex_api_source_toml_is_valid "$file" || return 1
  codex_api_source_key "$file" >/dev/null 2>&1 || return 1
  raw_config="$(mktemp)"
  status=0
  codex_extract_source_config "$file" "$raw_config" >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    url="$(codex_config_api_url "$file")"
    if [ -n "$url" ]; then
      case "$url" in http://* | https://*) ;; *) status=1 ;; esac
    fi
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

codex_write_api_source() {
  local url="$1" key="$2" file tmp
  file="$(codex_api_source_file)"
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  {
    printf '%s\n' '# clash-codex-autodl API profile'
    printf '%s\n' '# 除 api_key 外，其余内容用于定向更新原生 Codex config.toml。'
    printf 'api_key = "%s"\n' "$(toml_escape "$key")"
    printf '%s\n' 'cli_auth_credentials_store = "file"'
    printf '%s\n' 'forced_login_method = "api"'
    printf '%s\n' 'model_provider = "OpenAI"'
    printf '%s\n' 'model = "gpt-5.6-sol"'
    printf '%s\n' 'review_model = "gpt-5.4"'
    printf '%s\n' 'model_reasoning_effort = "xhigh"'
    printf '%s\n' 'model_context_window = 1000000'
    printf '%s\n' 'model_auto_compact_token_limit = 900000'
    printf '\n[model_providers.OpenAI]\n'
    printf '%s\n' 'name = "OpenAI"'
    printf 'base_url = "%s"\n' "$(toml_escape "$url")"
    printf '%s\n' 'wire_api = "responses"'
    printf '%s\n' 'requires_openai_auth = true'
    printf '\n[sandbox_workspace_write]\n'
    printf '%s\n' 'network_access = true'
  } > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  if ! codex_api_source_toml_is_valid "$tmp"; then
    rm -f "$tmp"
    log_error "生成的 API 配置不是有效 TOML；粘贴内容可能含不可见控制字符"
    return 1
  fi
  mv "$tmp" "$file"
}

codex_prepare_profile_config() {
  local profile="$1" source="$2" output="$3" has_provider="false"
  case "$profile" in api | chatgpt) ;; *) return 1 ;; esac
  [ -s "$source" ] && grep -Eq '^[[:space:]]*model_provider[[:space:]]*=' "$source" && has_provider="true"
  {
    printf '%s\n' 'cli_auth_credentials_store = "file"'
    printf 'forced_login_method = "%s"\n' "$profile"
    if [ "$has_provider" = false ]; then
      printf '%s\n' 'model_provider = "openai"'
    fi
    if [ -s "$source" ]; then
      awk -v profile="$profile" '
        BEGIN { in_table = 0 }
        /^[[:space:]]*\[/ { in_table = 1 }
        !in_table && /^[[:space:]]*api_key[[:space:]]*=/ { next }
        /^[[:space:]]*(cli_auth_credentials_store|forced_login_method|sqlite_home)[[:space:]]*=/ { next }
        profile == "api" && /^[[:space:]]*forced_chatgpt_workspace_id[[:space:]]*=/ { next }
        { print }
      ' "$source"
    fi
  } > "$output"
}

codex_profile_managed_top_lines() {
  local source="$1"
  awk '
    BEGIN { in_table = 0 }
    /^[[:space:]]*\[/ { in_table = 1 }
    !in_table && /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ &&
      !/^[[:space:]]*(api_key|sqlite_home)[[:space:]]*=/ { print }
  ' "$source"
}

codex_extract_table_prefix() {
  local source="$1" prefix="$2"
  awk -v prefix="$prefix" '
    function trim(value) { sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); return value }
    /^[[:space:]]*\[/ {
      header = trim($0)
      wanted = (header == "[" prefix "]" || index(header, "[" prefix ".") == 1)
    }
    wanted { print }
  ' "$source"
}

codex_config_has_table_prefix() {
  local source="$1" prefix="$2"
  codex_extract_table_prefix "$source" "$prefix" | grep -q .
}

codex_merge_profile_config() {
  local target_config="$1" live_config="$2" output="$3" previous_config="${4:-}"
  local target_provider previous_provider managed_lines managed_keys stripped table_headers python_bin python_status helper
  target_provider="$(codex_config_model_provider "$target_config")"
  if [ -s "$previous_config" ]; then
    previous_provider="$(codex_config_model_provider "$previous_config")"
  else
    previous_provider="$(codex_config_model_provider "$live_config")"
  fi
  helper="$CODEX_AUTODL_REPO_ROOT/lib/codex_toml_merge.py"
  if [ -f "$helper" ] && python_bin="$(python_command 2>/dev/null)"; then
    if "$python_bin" "$helper" "$target_config" "$live_config" "$output"; then
      python_status=0
    else
      python_status="$?"
    fi
    if [ "$python_status" -eq 0 ]; then
      return 0
    fi
    if [ "$python_status" -ne 2 ]; then
      log_error "config.toml 递归合并失败；原生配置未修改"
      return 1
    fi
  fi
  managed_lines="$(mktemp)"
  managed_keys="$(mktemp)"
  stripped="$(mktemp)"
  codex_profile_managed_top_lines "$target_config" > "$managed_lines"
  awk -F= '{ key=$1; gsub(/[[:space:]]/, "", key); if (key != "") print key }' "$managed_lines" > "$managed_keys"
  table_headers="$(mktemp)"
  awk '/^[[:space:]]*\[/ { line=$0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line); print line }' \
    "$target_config" > "$table_headers"

  if [ -s "$live_config" ]; then
    awk -v keys_file="$managed_keys" -v table_file="$table_headers" -v old_provider="$previous_provider" \
      -v new_provider="$target_provider" '
      function trim(value) { sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); return value }
      function provider_header(header, provider) {
        if (provider == "" || provider == "openai" || provider == "ollama" || provider == "lmstudio") return 0
        return header == "[model_providers." provider "]" || index(header, "[model_providers." provider ".") == 1
      }
      function target_table(header, position) {
        for (position in tables) {
          if (header == tables[position] || index(header, tables[position] ".") == 1) return 1
        }
        return 0
      }
      BEGIN {
        while ((getline key < keys_file) > 0) replace_key[key] = 1
        close(keys_file)
        table_count = 0
        while ((getline header < table_file) > 0) tables[++table_count] = header
        close(table_file)
        in_table = 0
        skip_table = 0
      }
      /^[[:space:]]*\[/ {
        in_table = 1
        header = trim($0)
        skip_table = provider_header(header, old_provider) || provider_header(header, new_provider) || target_table(header)
        if (skip_table) next
      }
      skip_table { next }
      !in_table && /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ {
        key = $0
        sub(/[[:space:]]*=.*/, "", key)
        gsub(/[[:space:]]/, "", key)
        if ((key == "forced_login_method" || key == "cli_auth_credentials_store" ||
          key == "forced_chatgpt_workspace_id" || key == "openai_base_url" ||
          key == "chatgpt_base_url" || key == "experimental_realtime_ws_base_url" ||
          key == "apps_mcp_product_sku" || key == "oss_provider") && !replace_key[key]) next
        if (replace_key[key]) next
      }
      { print }
    ' "$live_config" > "$stripped"
  else
    : > "$stripped"
  fi

  {
    cat "$managed_lines"
    if [ -s "$stripped" ]; then printf '\n'; cat "$stripped"; fi
    if [ -s "$table_headers" ]; then
      printf '\n'
      awk 'started || /^[[:space:]]*\[/ { started = 1; if (started) print }' "$target_config"
    fi
  } > "$output"
  rm -f "$managed_lines" "$managed_keys" "$stripped" "$table_headers"
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

codex_record_sync() {
  local profile="$1" file tmp
  file="$(codex_last_sync_file)"
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$profile" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
}

codex_capture_native_profile() {
  local profile="$1" quiet="${2:-false}" record_sync="${3:-true}"
  local native config auth method root pending source_config
  native="$(codex_native_home)"
  config="$native/config.toml"
  auth="$native/auth.json"
  method="$(codex_auth_method_from_file "$auth" 2>/dev/null || true)"
  [ "$method" = "$profile" ] || {
    log_error "原生 CODEX_HOME 的认证不是 $profile，无法保存该配置"
    return 1
  }
  root="$(codex_profiles_dir)"
  mkdir -p "$root"
  chmod 700 "$root" 2>/dev/null || true
  pending="$(mktemp -d "$root/.${profile}.capture.XXXXXX")"
  source_config="$config"
  if [ ! -s "$source_config" ]; then
    source_config="$(mktemp)"
    : > "$source_config"
  fi
  if ! codex_prepare_profile_config "$profile" "$source_config" "$pending/config.toml" ||
    ! cp "$auth" "$pending/auth.json"; then
    [ "$source_config" = "$config" ] || rm -f "$source_config"
    rm -rf "$pending"
    return 1
  fi
  [ "$source_config" = "$config" ] || rm -f "$source_config"
  chmod 600 "$pending/config.toml" "$pending/auth.json" 2>/dev/null || true
  replace_codex_profile_dir "$profile" "$pending" || return 1
  if [ "$record_sync" = true ]; then codex_record_sync "$profile"; fi
  [ "$quiet" = true ] || log_ok "已保存原生 Codex $profile 认证快照"
}

codex_import_native_profile() {
  local profile="$1" native_home="$2" current_native
  current_native="$(codex_native_home)"
  [ "${native_home%/}" = "${current_native%/}" ] || {
    log_error "当前实现只接管正在使用的原生 CODEX_HOME: $current_native"
    return 1
  }
  codex_capture_native_profile "$profile"
}

codex_native_backup_create() {
  local backup_dir="$1" native
  native="$(codex_native_home)"
  mkdir -p "$backup_dir"
  if [ -f "$native/config.toml" ]; then
    cp -p "$native/config.toml" "$backup_dir/config.toml"
    printf 'true\n' > "$backup_dir/had-config"
  else
    printf 'false\n' > "$backup_dir/had-config"
  fi
  if [ -f "$native/auth.json" ]; then
    cp -p "$native/auth.json" "$backup_dir/auth.json"
    printf 'true\n' > "$backup_dir/had-auth"
  else
    printf 'false\n' > "$backup_dir/had-auth"
  fi
}

codex_native_backup_restore() {
  local backup_dir="$1" native
  native="$(codex_native_home)"
  [ -d "$native" ] || return 0
  if [ "$(cat "$backup_dir/had-config" 2>/dev/null || true)" = true ]; then
    cp "$backup_dir/config.toml" "$native/config.toml"
    chmod 600 "$native/config.toml" 2>/dev/null || true
  else
    rm -f "$native/config.toml"
  fi
  if [ "$(cat "$backup_dir/had-auth" 2>/dev/null || true)" = true ]; then
    cp "$backup_dir/auth.json" "$native/auth.json"
    chmod 600 "$native/auth.json" 2>/dev/null || true
  else
    rm -f "$native/auth.json"
  fi
}

codex_apply_profile_dir_to_native() {
  local profile="$1" profile_dir="$2" previous_config="${3:-}" native work live_config auth_method
  native="$(codex_native_home)"
  [ -d "$native" ] || {
    log_error "原生 CODEX_HOME 不存在: $native；请先通过 codex-config 完成原生登录"
    return 1
  }
  auth_method="$(codex_auth_method_from_file "$profile_dir/auth.json" 2>/dev/null || true)"
  [ "$auth_method" = "$profile" ] || {
    log_error "$profile 认证快照中的 auth.json 无效"
    return 1
  }
  mkdir -p "$(project_data_dir)"
  work="$(mktemp -d "$(project_data_dir)/.native-apply.XXXXXX")"
  live_config="$native/config.toml"
  codex_native_backup_create "$work/backup"
  codex_merge_profile_config "$profile_dir/config.toml" "$live_config" "$work/config.toml" "$previous_config" || {
    rm -rf "$work"
    return 1
  }
  cp "$profile_dir/auth.json" "$work/auth.json"
  chmod 600 "$work/config.toml" "$work/auth.json" 2>/dev/null || true
  if ! cp "$work/config.toml" "$native/config.toml" ||
    ! cp "$work/auth.json" "$native/auth.json"; then
    codex_native_backup_restore "$work/backup"
    rm -rf "$work"
    log_error "切换原生 Codex 认证失败，已恢复原 auth.json/config.toml"
    return 1
  fi
  chmod 600 "$native/config.toml" "$native/auth.json" 2>/dev/null || true
  rm -rf "$work"
}

codex_apply_config_to_native() {
  local target_config="$1" previous_config="${2:-}" native work live_config
  native="$(codex_native_home)"
  # Creating CODEX_HOME itself is unavoidable on a first native login. The
  # project creates no custom child path: only the allowed config.toml is put
  # there before Codex performs its own login.
  mkdir -p "$native" "$(project_data_dir)"
  work="$(mktemp -d "$(project_data_dir)/.native-config.XXXXXX")"
  live_config="$native/config.toml"
  if ! codex_merge_profile_config "$target_config" "$live_config" "$work/config.toml" "$previous_config" ||
    ! cp "$work/config.toml" "$native/config.toml"; then
    rm -rf "$work"
    return 1
  fi
  chmod 600 "$native/config.toml" 2>/dev/null || true
  rm -rf "$work"
}

codex_apply_saved_profile() {
  local profile="$1" previous="${2:-$(codex_active_auth)}" previous_config=""
  local target_provider work
  codex_profile_is_configured "$profile" || { log_error "$profile 配置尚未完成"; return 1; }
  if codex_profile_is_configured "$previous"; then
    previous_config="$(codex_profile_home "$previous")/config.toml"
  fi
  target_provider="$(codex_config_model_provider "$(codex_profile_home "$profile")/config.toml")"
  mkdir -p "$(project_data_dir)"
  work="$(mktemp -d "$(project_data_dir)/.saved-profile-apply.XXXXXX")"
  codex_native_backup_create "$work/backup"
  if ! codex_apply_profile_dir_to_native "$profile" "$(codex_profile_home "$profile")" "$previous_config"; then
    rm -rf "$work"
    return 1
  fi
  if ! codex_rewrite_native_session_providers "$target_provider"; then
    codex_native_backup_restore "$work/backup"
    rm -rf "$work"
    return 1
  fi
  rm -rf "$work"
  save_codex_active_auth "$profile"
  codex_record_sync "$profile"
}

codex_api_source_native_login() {
  local key="$1" codex_bin native
  codex_bin="$(codex_binary_path)" || { log_error "未找到 Codex CLI"; return 1; }
  native="$(codex_native_home)"
  printf '%s\n' "$key" | CODEX_HOME="$native" "$codex_bin" login --with-api-key >/dev/null
}

apply_codex_api_source() {
  local source key url root pending raw_config native work previous previous_config
  local target_provider status=0
  source="$(codex_api_source_file)"
  [ -f "$source" ] || { log_error "API 配置不存在: $source"; return 1; }
  codex_api_source_toml_is_valid "$source" || { log_error "API 配置不是有效 TOML: $source"; return 1; }
  key="$(codex_api_source_key "$source")" || { log_error "API 配置中的 api_key 不能为空"; return 1; }
  url="$(codex_config_api_url "$source")"
  if [ -n "$url" ]; then
    validate_http_url CODEX_API_BASE_URL "$url" || { unset key; return 1; }
  fi
  codex_process_is_running && { unset key; log_error "配置认证前请先关闭其他 Codex CLI / Codex App 进程"; return 1; }
  codex_acquire_sync_lock || { unset key; return 1; }
  previous="$(codex_active_auth)"
  if codex_profile_is_configured "$previous" &&
    [ "$(codex_auth_method_from_file "$(codex_native_auth_file)" 2>/dev/null || true)" = "$previous" ]; then
    codex_capture_native_profile "$previous" true || true
  fi
  previous_config=""
  codex_profile_is_configured "$previous" && previous_config="$(codex_profile_home "$previous")/config.toml"
  root="$(codex_profiles_dir)"
  mkdir -p "$root" "$(project_data_dir)"
  chmod 700 "$root" 2>/dev/null || true
  pending="$(mktemp -d "$root/.api.pending.XXXXXX")"
  work="$(mktemp -d "$(project_data_dir)/.api-login.XXXXXX")"
  codex_native_backup_create "$work/backup"
  raw_config="$(mktemp)"
  if ! codex_extract_source_config "$source" "$raw_config" ||
    ! codex_prepare_profile_config api "$raw_config" "$pending/config.toml"; then
    status=1
  fi
  rm -f "$raw_config"
  if [ "$status" -eq 0 ] && ! codex_apply_config_to_native "$pending/config.toml" "$previous_config"; then
    log_error "无法定向更新原生 Codex config.toml"
    status=1
  fi
  if [ "$status" -eq 0 ] && ! codex_api_source_native_login "$key"; then
    log_error "Codex CLI 未能通过原生 CODEX_HOME 保存 API 凭据"
    status=1
  fi
  unset key
  native="$(codex_native_home)"
  if [ "$status" -eq 0 ] &&
    [ "$(codex_auth_method_from_file "$native/auth.json" 2>/dev/null || true)" != api ]; then
    log_error "原生 Codex 未生成有效的 API auth.json"
    status=1
  fi
  if [ "$status" -eq 0 ]; then
    cp "$native/auth.json" "$pending/auth.json"
    chmod 600 "$pending/config.toml" "$pending/auth.json" 2>/dev/null || true
    if ! codex_apply_profile_dir_to_native api "$pending" "$previous_config"; then status=1; fi
  fi
  if [ "$status" -eq 0 ]; then
    target_provider="$(codex_config_model_provider "$pending/config.toml")"
  fi
  if [ "$status" -eq 0 ]; then
    codex_rewrite_native_session_providers "$target_provider" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    replace_codex_profile_dir api "$pending" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    save_codex_active_auth api
    codex_record_sync api
    log_ok "API 认证已由 Codex CLI 写入原生 CODEX_HOME（尚未进行模型调用验证）"
  else
    codex_native_backup_restore "$work/backup"
    rm -rf "$pending"
    log_error "API 配置失败，原生 auth.json/config.toml 已恢复"
  fi
  rm -rf "$work"
  codex_release_sync_lock
  return "$status"
}

configure_codex_api_initial() {
  local current_url="${1:-}" url key source
  source="$(codex_api_source_file)"
  if [ -z "$current_url" ] && [ -f "$source" ]; then current_url="$(codex_config_api_url "$source")"; fi
  if [ -z "$current_url" ] && [ -f "$(codex_profile_home api)/config.toml" ]; then
    current_url="$(codex_config_api_url "$(codex_profile_home api)/config.toml")"
  fi
  log_info "API 文本配置将保存到: $source"
  log_info "Codex CLI 可执行文件不是配置文件，请不要使用 cat 或编辑器打开 codex 二进制文件"
  url="$(prompt_required "请输入 API 地址" "$current_url")"
  validate_http_url CODEX_API_BASE_URL "$url" || return 1
  log_info "API Key 使用隐藏输入：粘贴后屏幕不显示字符，按 Enter 即可"
  key="$(prompt_secret "请输入 API Key")"
  if ! codex_write_api_source "$url" "$key"; then unset key; return 1; fi
  unset key
  apply_codex_api_source
}

configure_codex_api_profile() {
  local source current_url="" backup
  source="$(codex_api_source_file)"
  if [ -f "$source" ] && ! codex_api_source_is_usable "$source"; then
    current_url="$(codex_config_api_url "$source")"
    backup="$(codex_backup_invalid_api_source "$source")"
    log_warn "检测到空白或无效的 API 文本配置，已备份到: $backup"
  fi
  configure_codex_api_initial "$current_url"
}

codex_force_chatgpt_profile_config() {
  local source="$1" output="$2" prepared
  prepared="$(mktemp)"
  codex_prepare_profile_config chatgpt "$source" "$prepared" || { rm -f "$prepared"; return 1; }
  {
    printf '%s\n' 'model_provider = "openai"'
    awk '
      BEGIN { in_table = 0 }
      /^[[:space:]]*\[/ { in_table = 1 }
      !in_table && /^[[:space:]]*model_provider[[:space:]]*=/ { next }
      { print }
    ' "$prepared"
  } > "$output"
  rm -f "$prepared"
}

configure_codex_chatgpt_profile() {
  local codex_bin native root pending work previous previous_config source_config
  local target_provider status=0
  codex_bin="$(codex_binary_path)" || { log_error "未找到 Codex CLI"; return 1; }
  codex_process_is_running && { log_error "配置认证前请先关闭其他 Codex CLI / Codex App 进程"; return 1; }
  codex_acquire_sync_lock || return 1
  previous="$(codex_active_auth)"
  if codex_profile_is_configured "$previous" &&
    [ "$(codex_auth_method_from_file "$(codex_native_auth_file)" 2>/dev/null || true)" = "$previous" ]; then
    codex_capture_native_profile "$previous" true || true
  fi
  previous_config=""
  codex_profile_is_configured "$previous" && previous_config="$(codex_profile_home "$previous")/config.toml"
  native="$(codex_native_home)"
  root="$(codex_profiles_dir)"
  mkdir -p "$root" "$(project_data_dir)"
  chmod 700 "$root" 2>/dev/null || true
  pending="$(mktemp -d "$root/.chatgpt.pending.XXXXXX")"
  work="$(mktemp -d "$(project_data_dir)/.chatgpt-login.XXXXXX")"
  codex_native_backup_create "$work/backup"
  source_config="$native/config.toml"
  if [ ! -s "$source_config" ]; then source_config="$work/empty.toml"; : > "$source_config"; fi
  codex_force_chatgpt_profile_config "$source_config" "$pending/config.toml" || status=1
  if [ "$status" -eq 0 ]; then
    log_info "正在使用 Codex 原生 ChatGPT 设备码登录"
    if ! codex_apply_config_to_native "$pending/config.toml" "$previous_config"; then
      log_error "无法定向更新原生 Codex config.toml"
      status=1
    elif ! CODEX_HOME="$native" "$codex_bin" login --device-auth; then
      log_error "ChatGPT 原生登录失败"
      status=1
    fi
  fi
  if [ "$status" -eq 0 ] &&
    [ "$(codex_auth_method_from_file "$native/auth.json" 2>/dev/null || true)" != chatgpt ]; then
    log_error "Codex 未生成有效的 ChatGPT auth.json"
    status=1
  fi
  if [ "$status" -eq 0 ]; then
    cp "$native/auth.json" "$pending/auth.json"
    chmod 600 "$pending/config.toml" "$pending/auth.json" 2>/dev/null || true
    if ! codex_apply_profile_dir_to_native chatgpt "$pending" "$previous_config"; then status=1; fi
  fi
  if [ "$status" -eq 0 ]; then
    target_provider="$(codex_config_model_provider "$pending/config.toml")"
  fi
  if [ "$status" -eq 0 ]; then
    codex_rewrite_native_session_providers "$target_provider" || status=1
  fi
  if [ "$status" -eq 0 ]; then replace_codex_profile_dir chatgpt "$pending" || status=1; fi
  if [ "$status" -eq 0 ]; then
    save_codex_active_auth chatgpt
    codex_record_sync chatgpt
    log_ok "ChatGPT 原生登录已保存"
  else
    codex_native_backup_restore "$work/backup"
    rm -rf "$pending"
    log_error "ChatGPT 配置失败，原生 auth.json/config.toml 已恢复"
  fi
  rm -rf "$work"
  codex_release_sync_lock
  return "$status"
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
  if [ ! -f "$file" ]; then configure_codex_api_initial ""; return; fi
  editor="$(codex_pick_editor)" || { log_error "未找到编辑器，请设置 EDITOR"; return 1; }
  log_info "正在编辑 API 文本配置: $file"
  sh -c "$editor \"\$1\"" sh "$file" || return 1
  apply_codex_api_source
}

codex_acquire_sync_lock() {
  local lock pid
  lock="$(codex_sync_lock_dir)"
  mkdir -p "$(dirname "$lock")"
  if mkdir "$lock" 2>/dev/null; then printf '%s\n' "$$" > "$lock/pid"; return 0; fi
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && ! kill -0 "$pid" >/dev/null 2>&1; then
    rm -rf "$lock"; mkdir "$lock"; printf '%s\n' "$$" > "$lock/pid"; return 0
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
  local profile="$1" method status=0
  [ "$profile" = "$(codex_active_auth)" ] || { log_error "只能同步当前活动认证"; return 1; }
  codex_process_is_running && { log_error "同步前请先关闭其他 Codex CLI / Codex App 进程"; return 1; }
  method="$(codex_auth_method_from_file "$(codex_native_auth_file)" 2>/dev/null || true)"
  [ "$method" = "$profile" ] || { log_error "原生 CODEX_HOME 当前不是 $profile 认证"; return 1; }
  codex_acquire_sync_lock || return 1
  codex_capture_native_profile "$profile" false false || status=$?
  if [ "$status" -eq 0 ]; then
    codex_sync_native_sessions_to_profile "$profile" || status=$?
  fi
  if [ "$status" -eq 0 ]; then codex_record_sync "$profile"; fi
  codex_release_sync_lock
  return "$status"
}

codex_switch_profile() {
  local active target method
  active="$(codex_active_auth)"
  if [ "$active" = api ]; then target=chatgpt; else target=api; fi
  codex_process_is_running && { log_error "切换前请先关闭其他 Codex CLI / Codex App 进程"; return 1; }
  method="$(codex_auth_method_from_file "$(codex_native_auth_file)" 2>/dev/null || true)"
  if [ "$method" = "$active" ]; then codex_sync_profile "$active" || return 1; fi
  if ! codex_profile_is_configured "$target"; then
    case "$target" in
      api)
        if codex_api_source_is_usable "$(codex_api_source_file)"; then apply_codex_api_source; else configure_codex_api_profile; fi
        ;;
      chatgpt) configure_codex_chatgpt_profile ;;
    esac || return 1
  else
    codex_acquire_sync_lock || return 1
    if ! codex_apply_saved_profile "$target" "$active"; then codex_release_sync_lock; return 1; fi
    codex_release_sync_lock
  fi
  log_ok "已切换到 $target；auth.json 已完整替换，config.toml 已定向更新"
}

codex_manual_sync() {
  local active
  active="$(codex_active_auth)"
  codex_sync_profile "$active" || return 1
  codex_sessions_status
}

codex_native_auth_matches_profile() {
  local profile="$1"
  codex_profile_is_configured "$profile" || return 1
  cmp -s "$(codex_native_auth_file)" "$(codex_profile_home "$profile")/auth.json"
}

codex_profiles_status() {
  local active profile home url last method
  active="$(codex_active_auth)"
  method="$(codex_auth_method_from_file "$(codex_native_auth_file)" 2>/dev/null || true)"
  if ! codex_profile_is_configured "$active"; then
    log_warn "当前配置: $active（尚未完成）"
  elif [ "$active" = api ]; then
    url="$(codex_config_api_url "$(codex_profile_home api)/config.toml")"
    log_info "当前配置: API"
    log_info "API URL: ${url:-OpenAI 默认地址}"
  else
    log_info "当前配置: ChatGPT"
  fi
  if [ "$method" = "$active" ]; then log_ok "原生 CODEX_HOME: 认证一致"; else log_warn "原生 CODEX_HOME: 当前认证与项目指针不一致"; fi
  for profile in api chatgpt; do
    home="$(codex_profile_home "$profile")"
    if codex_profile_is_configured "$profile"; then log_ok "$profile: 已保存"; else log_warn "$profile: 未配置"; fi
  done
  last="$(codex_last_sync_file)"; [ ! -s "$last" ] || log_info "最近同步: $(cat "$last")"
  last="$(codex_last_verify_file)"; [ ! -s "$last" ] || log_info "最近验证: $(cat "$last")"
  codex_sessions_status
}

codex_shell_status() {
  local active home url method sync_state rollout_count
  active="$(codex_active_auth)"
  home="$(codex_profile_home "$active")"
  method="$(codex_auth_method_from_file "$(codex_native_auth_file)" 2>/dev/null || true)"
  if codex_profile_is_configured "$active" && [ "$method" = "$active" ]; then
    if [ "$active" = api ]; then
      url="$(codex_config_api_url "$home/config.toml")"
      printf '[codex] API | %s\n' "${url:-OpenAI 默认地址}"
    else
      printf '[codex] ChatGPT\n'
    fi
  elif codex_profile_is_configured "$active"; then
    printf '[codex] 配置不一致 | 运行 codex-switch 或 codex-config 修复\n'
  else
    printf '[codex] 未配置\n'
  fi
  if codex_native_auth_matches_profile "$active"; then sync_state="已同步"; else sync_state="待同步"; fi
  rollout_count="$(codex_session_rollout_count)"
  printf '[sync] %s | 原生会话 %s 个\n' "$sync_state" "$rollout_count"
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

codex_ensure_native_active() {
  local active method
  active="$(codex_active_auth)"
  codex_profile_is_configured "$active" || { log_error "$active 配置尚未完成"; return 1; }
  method="$(codex_auth_method_from_file "$(codex_native_auth_file)" 2>/dev/null || true)"
  [ "$method" = "$active" ] && return 0
  codex_process_is_running && { log_error "原生认证不一致，且另一个 Codex 进程正在运行"; return 1; }
  codex_acquire_sync_lock || return 1
  if ! codex_apply_saved_profile "$active" "$active"; then codex_release_sync_lock; return 1; fi
  codex_release_sync_lock
}

verify_active_codex_profile() {
  local active native codex_bin
  active="$(codex_active_auth)"
  codex_ensure_native_active || return 1
  native="$(codex_native_home)"
  codex_bin="$(codex_binary_path)" || { log_error "未找到 Codex CLI"; return 1; }
  if CODEX_HOME="$native" CODEX_CLI_COMMAND="$codex_bin" codex_smoke_test; then
    codex_record_verify success
    [ "$(codex_auth_method_from_file "$native/auth.json" 2>/dev/null || true)" != "$active" ] || codex_capture_native_profile "$active" true
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
  local active native codex_bin status
  active="$(codex_active_auth)"
  codex_ensure_native_active || return 1
  native="$(codex_native_home)"
  codex_bin="$(codex_binary_path)" || { log_error "未找到 Codex CLI"; return 1; }
  if CODEX_HOME="$native" "$codex_bin" "$@"; then status=0; else status=$?; fi
  if ! codex_process_is_running &&
    [ "$(codex_auth_method_from_file "$native/auth.json" 2>/dev/null || true)" = "$active" ]; then
    codex_acquire_sync_lock >/dev/null 2>&1 || return "$status"
    codex_capture_native_profile "$active" true || true
    codex_release_sync_lock
  fi
  return "$status"
}

codex_migrate_legacy_profiles() {
  local legacy profile source target pending method
  legacy="$(codex_legacy_profiles_dir)"
  [ -d "$legacy" ] || return 0
  for profile in api chatgpt; do
    codex_profile_is_configured "$profile" && continue
    source="$legacy/$profile"
    if [ ! -s "$source/config.toml" ] || [ ! -s "$source/auth.json" ]; then
      continue
    fi
    method="$(codex_auth_method_from_file "$source/auth.json" 2>/dev/null || true)"
    [ "$method" = "$profile" ] || continue
    target="$(codex_profiles_dir)"
    mkdir -p "$target"
    pending="$(mktemp -d "$target/.${profile}.legacy.XXXXXX")"
    if codex_prepare_profile_config "$profile" "$source/config.toml" "$pending/config.toml" &&
      cp "$source/auth.json" "$pending/auth.json"; then
      chmod 600 "$pending/config.toml" "$pending/auth.json" 2>/dev/null || true
      replace_codex_profile_dir "$profile" "$pending"
      log_ok "已迁移旧 $profile 认证快照；旧会话目录未导入、未改写"
    else
      rm -rf "$pending"
    fi
  done
}

codex_migrate_api_source() {
  local home source config auth key pending backup
  source="$(codex_api_source_file)"
  codex_api_source_is_usable "$source" && return 0
  home="$(codex_profile_home api)"
  config="$home/config.toml"
  auth="$home/auth.json"
  [ -s "$config" ] && [ -s "$auth" ] || return 0
  key="$(codex_auth_api_key "$auth" 2>/dev/null || true)"
  [ -n "$key" ] || { log_warn "已有 API 快照无法提取 API Key；codex-config 时需要重新输入"; return 0; }
  mkdir -p "$(dirname "$source")"
  pending="$(mktemp "${source}.migrate.XXXXXX")"
  {
    printf '%s\n' '# clash-codex-autodl API profile (migrated)'
    printf 'api_key = "%s"\n' "$(toml_escape "$key")"
    awk '!/^[[:space:]]*sqlite_home[[:space:]]*=/' "$config"
  } > "$pending"
  chmod 600 "$pending" 2>/dev/null || true
  if ! codex_api_source_is_usable "$pending"; then rm -f "$pending"; unset key; return 0; fi
  if [ -f "$source" ]; then backup="$(codex_backup_invalid_api_source "$source")"; log_warn "已备份无效的旧 API 文本配置: $backup"; fi
  mv "$pending" "$source"
  unset key
  log_ok "已迁移旧 API 配置到单文件数据源"
}
