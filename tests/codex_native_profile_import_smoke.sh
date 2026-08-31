#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"

cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

make_fake_codex() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${CODEX_HOME:-}" "$*" >> "${CODEX_FAKE_LOG:?}"
case "${1:-}" in
  --version)
    printf 'codex-cli native-import-test\n'
    ;;
  login)
    case "${2:-}" in
      status)
        if [ "${CODEX_HOME:-}" = "${FAKE_KEYRING_HOME:-disabled}" ]; then
          case "${FAKE_KEYRING_METHOD:-chatgpt}" in
            chatgpt) printf 'Logged in using ChatGPT\n' >&2 ;;
            access-token) printf 'Logged in using access token\n' >&2 ;;
            *) exit 2 ;;
          esac
        elif grep -Eqi '"auth_mode"[[:space:]]*:[[:space:]]*"chatgpt"' "${CODEX_HOME:?}/auth.json" 2>/dev/null ||
          grep -q '"tokens"' "$CODEX_HOME/auth.json" 2>/dev/null; then
          printf 'Logged in using ChatGPT\n' >&2
        elif grep -Eq '"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"[^"[:space:]]' "$CODEX_HOME/auth.json" 2>/dev/null; then
          printf 'Logged in using an API key - sk-test***value\n' >&2
        else
          printf 'Not logged in\n' >&2
          exit 1
        fi
        ;;
      --with-api-key)
        IFS= read -r key
        printf '{"auth_mode":"apiKey","OPENAI_API_KEY":"%s"}\n' "$key" > "${CODEX_HOME:?}/auth.json"
        ;;
      --device-auth)
        printf '{"auth_mode":"chatgpt","tokens":{"access_token":"new-token"}}\n' > "${CODEX_HOME:?}/auth.json"
        ;;
      *) exit 2 ;;
    esac
    ;;
esac
SH
  chmod +x "$bin_dir/codex"
}

run_native_chatgpt_case() {
  local root="$tmp_dir/chatgpt" home native config data bin log before_auth status
  root="$tmp_dir/chatgpt"
  home="$root/home"
  native="$home/.codex"
  config="$root/config"
  data="$root/data"
  bin="$home/.local/bin"
  log="$root/codex.log"
  mkdir -p "$native"
  make_fake_codex "$bin"
  cat > "$native/config.toml" <<'TOML'
model = "existing-chat-model"
model_provider = "native_chat"
cli_auth_credentials_store = "file"

[model_providers.native_chat]
name = "Native Chat"
base_url = "https://chat-relay.example.invalid/v1"
requires_openai_auth = true
TOML
  printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":"native-chat-token"}}' > "$native/auth.json"
  before_auth="$(cksum "$native/auth.json")"
  : > "$log"

  env HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
    CODEX_FAKE_LOG="$log" \
    bash "$repo_root/install-codex.sh" </dev/null >/dev/null

  [ "$(cat "$config/active-auth")" = chatgpt ]
  [ -s "$data/codex-profiles/chatgpt/auth.json" ]
  grep -q '^forced_login_method = "chatgpt"$' "$data/codex-profiles/chatgpt/config.toml"
  grep -q '^cli_auth_credentials_store = "file"$' "$data/codex-profiles/chatgpt/config.toml"
  grep -q '^model_provider = "native_chat"$' "$data/codex-profiles/chatgpt/config.toml"
  grep -q '^base_url = "https://chat-relay.example.invalid/v1"$' "$data/codex-profiles/chatgpt/config.toml"
  [ ! -e "$config/api-profile.toml" ]
  [ "$(cksum "$native/auth.json")" = "$before_auth" ]
  grep -q '^forced_login_method = "chatgpt"$' "$native/config.toml"
  grep -q '^model_provider = "native_chat"$' "$native/config.toml"
  [ ! -e "$data/codex-shared" ]
  ! grep -q '|login --' "$log"

  status="$(env HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CODEX_FAKE_LOG="$log" "$bin/codex-status")"
  grep -q '当前配置: ChatGPT' <<< "$status"

  printf '%s\n%s\n' 'https://new-api.example.invalid/v1' 'new-api-test-key' | env \
    HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
    CODEX_FAKE_LOG="$log" "$bin/codex-switch" >/dev/null
  [ "$(cat "$config/active-auth")" = api ]
  grep -q '^base_url = "https://new-api.example.invalid/v1"$' "$data/codex-profiles/api/config.toml"
  grep -q '^forced_login_method = "api"$' "$native/config.toml"
}

run_native_api_case() {
  local root="$tmp_dir/api" home native config data bin log before_auth status
  root="$tmp_dir/api"
  home="$root/home"
  native="$home/.codex"
  config="$root/config"
  data="$root/data"
  bin="$home/.local/bin"
  log="$root/codex.log"
  mkdir -p "$native"
  make_fake_codex "$bin"
  cat > "$native/config.toml" <<'TOML'
model = "existing-api-model"
model_provider = "relay_native"
cli_auth_credentials_store = "file"

[model_providers.relay_native]
name = "Existing Relay"
base_url = "https://existing-api.example.invalid/v1"
wire_api = "responses"
requires_openai_auth = true
TOML
  printf '%s\n' '{"auth_mode":"apiKey","OPENAI_API_KEY":"native-api-test-key"}' > "$native/auth.json"
  before_auth="$(cksum "$native/auth.json")"
  : > "$log"

  env HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
    CODEX_FAKE_LOG="$log" \
    bash "$repo_root/install-codex.sh" </dev/null >/dev/null

  [ "$(cat "$config/active-auth")" = api ]
  grep -q '^forced_login_method = "api"$' "$data/codex-profiles/api/config.toml"
  grep -q '^model_provider = "relay_native"$' "$data/codex-profiles/api/config.toml"
  grep -q '^api_key = "native-api-test-key"$' "$config/api-profile.toml"
  grep -q '^base_url = "https://existing-api.example.invalid/v1"$' "$config/api-profile.toml"
  [ "$(cksum "$native/auth.json")" = "$before_auth" ]
  grep -q '^forced_login_method = "api"$' "$native/config.toml"
  ! grep -q '|login --with-api-key' "$log"

  status="$(env HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CODEX_FAKE_LOG="$log" "$bin/codex-status")"
  grep -q 'API URL: https://existing-api.example.invalid/v1' <<< "$status"
}

run_native_default_api_case() {
  local root="$tmp_dir/default-api" home native config data bin log status
  root="$tmp_dir/default-api"
  home="$root/home"
  native="$home/.codex"
  config="$root/config"
  data="$root/data"
  bin="$home/.local/bin"
  log="$root/codex.log"
  mkdir -p "$native"
  make_fake_codex "$bin"
  printf '%s\n' 'model = "gpt-5.6-sol"' > "$native/config.toml"
  printf '%s\n' '{"auth_mode":"apiKey","OPENAI_API_KEY":"native-default-test-key"}' > "$native/auth.json"
  : > "$log"

  env HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
    CODEX_FAKE_LOG="$log" \
    bash "$repo_root/install-codex.sh" </dev/null >/dev/null

  grep -q '^api_key = "native-default-test-key"$' "$config/api-profile.toml"
  ! grep -q '^model_provider[[:space:]]*=' "$config/api-profile.toml"
  status="$(env HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CODEX_FAKE_LOG="$log" "$bin/codex-status")"
  grep -q 'API URL: OpenAI 默认地址' <<< "$status"
}

run_keyring_detection_case() {
  local root="$tmp_dir/keyring" home native config data bin log output status
  root="$tmp_dir/keyring"
  home="$root/home"
  native="$home/.codex"
  config="$root/config"
  data="$root/data"
  bin="$home/.local/bin"
  log="$root/codex.log"
  mkdir -p "$native"
  make_fake_codex "$bin"
  printf '%s\n' 'cli_auth_credentials_store = "keyring"' > "$native/config.toml"
  : > "$log"

  output="$(env HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
    CODEX_FAKE_LOG="$log" FAKE_KEYRING_HOME="$native" \
    bash "$repo_root/install-codex.sh" </dev/null 2>&1)"

  grep -q '检测到原生 Codex 登录: chatgpt' <<< "$output"
  grep -q '当前凭据位于系统 keyring' <<< "$output"
  [ "$(cat "$config/active-auth")" = chatgpt ]
  [ -s "$data/codex-profiles/chatgpt/auth.json" ]
  [ -s "$native/auth.json" ]
  [ ! -e "$config/api-profile.toml" ]
  status="$(env HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CODEX_FAKE_LOG="$log" "$bin/codex-status")"
  grep -q '当前配置: ChatGPT' <<< "$status"
}

run_unsupported_auth_case() {
  local root="$tmp_dir/unsupported" home native config data bin log output
  root="$tmp_dir/unsupported"
  home="$root/home"
  native="$home/.codex"
  config="$root/config"
  data="$root/data"
  bin="$home/.local/bin"
  log="$root/codex.log"
  mkdir -p "$native"
  make_fake_codex "$bin"
  : > "$log"

  output="$(env HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
    CODEX_FAKE_LOG="$log" FAKE_KEYRING_HOME="$native" \
    FAKE_KEYRING_METHOD=access-token \
    bash "$repo_root/install-codex.sh" </dev/null 2>&1)"

  grep -q '不能保存 access-token' <<< "$output"
  [ "$(cat "$config/active-auth")" = api ]
  [ ! -e "$config/api-profile.toml" ]
  [ ! -e "$data/codex-profiles/api/auth.json" ]
}

run_native_chatgpt_case
run_native_api_case
run_native_default_api_case
run_keyring_detection_case
run_unsupported_auth_case
