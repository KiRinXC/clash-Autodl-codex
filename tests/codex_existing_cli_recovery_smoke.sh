#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"

cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

make_fake_codex() {
  local home="$1" log="$2"
  mkdir -p "$home/.local/bin"
  cat > "$home/.local/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${CODEX_FAKE_LOG:?}"
case "${1:-}" in
  --version) printf 'codex-cli external-test\n' ;;
  login)
    [ "${2:-}" = --with-api-key ] || exit 2
    IFS= read -r key
    printf '{"OPENAI_API_KEY":"%s"}\n' "$key" > "${CODEX_HOME:?}/auth.json"
    ;;
esac
SH
  chmod +x "$home/.local/bin/codex"
  : > "$log"
}

run_recovery_case() {
  local root="$tmp_dir/recovery" home config data bin log before output
  home="$root/home"
  config="$root/config"
  data="$root/data"
  bin="$home/.local/bin"
  log="$root/codex.log"
  mkdir -p "$config"
  make_fake_codex "$home" "$log"
  before="$(cksum "$bin/codex")"
  cat > "$config/api-profile.toml" <<'TOML'
api_key = ""
model_provider = "openai"
openai_base_url = "https://old-api.example.invalid/v1"
TOML

  # Simulate one ineffective paste/empty Enter, then a right-click paste carrying
  # terminal bracketed-paste markers and CR. Prompt warnings must never enter the key.
  output="$(printf '%s\n\n%b\n' 'https://new-api.example.invalid/v1' $'\033[200~new-test-key\r\033[201~' | env \
    HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
    CODEX_FAKE_LOG="$log" \
    bash "$repo_root/install-codex.sh" 2>&1)"

  grep -q "已找到现有 Codex CLI: $bin/codex" <<< "$output"
  grep -q '将复用该 Codex CLI' <<< "$output"
  grep -q '检测到空白或无效的 API 文本配置' <<< "$output"
  grep -q "API 文本配置将保存到: $config/api-profile.toml" <<< "$output"
  grep -q 'Codex CLI 可执行文件不是配置文件' <<< "$output"
  grep -q '请输入 API Key 不能为空' <<< "$output"
  grep -q 'API Key 使用隐藏输入' <<< "$output"
  [ "$(cksum "$bin/codex")" = "$before" ]
  [ ! -e "$data/install-manifest" ]
  [ -x "$bin/codex-status" ]
  grep -q '^api_key = "new-test-key"$' "$config/api-profile.toml"
  grep -q '^model_provider = "OpenAI"$' "$config/api-profile.toml"
  grep -q '^model = "gpt-5.6-sol"$' "$config/api-profile.toml"
  grep -q '^base_url = "https://new-api.example.invalid/v1"$' "$config/api-profile.toml"
  find "$config" -maxdepth 1 -type f -name 'api-profile.toml.invalid.*' -print -quit | grep -q .
  grep -q '^login --with-api-key$' "$log"

  env HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
    bash "$repo_root/uninstall.sh" codex >/dev/null
  [ -x "$bin/codex" ]
  [ ! -e "$bin/codex-status" ]
  [ -s "$config/api-profile.toml" ]
}

run_preserved_profile_migration_case() {
  local root="$tmp_dir/migration" home config data bin log output
  home="$root/home"
  config="$root/config"
  data="$root/data"
  bin="$home/.local/bin"
  log="$root/codex.log"
  mkdir -p "$config" "$data/codex-homes/api"
  make_fake_codex "$home" "$log"
  printf 'api_key = ""\nmodel_provider = "openai"\n' > "$config/api-profile.toml"
  cat > "$data/codex-homes/api/config.toml" <<'TOML'
model_provider = "openai"
openai_base_url = "https://preserved-api.example.invalid/v1"
sqlite_home = "/old/managed/path"
TOML
  printf '{"OPENAI_API_KEY":"preserved-test-key"}\n' > "$data/codex-homes/api/auth.json"

  output="$(env HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
    CODEX_FAKE_LOG="$log" \
    bash "$repo_root/install-codex.sh" </dev/null 2>&1)"

  grep -q '已备份无效的旧 API 文本配置' <<< "$output"
  grep -q '已迁移旧 API 配置到单文件数据源' <<< "$output"
  grep -q '已迁移旧 api 认证快照' <<< "$output"
  grep -q '已将项目保存的 api 认证恢复到原生 CODEX_HOME' <<< "$output"
  grep -q '^api_key = "preserved-test-key"$' "$config/api-profile.toml"
  grep -q '^openai_base_url = "https://preserved-api.example.invalid/v1"$' "$config/api-profile.toml"
  ! grep -q '^sqlite_home' "$config/api-profile.toml"
  grep -q '^login --with-api-key$' "$log"
  [ -s "$data/codex-profiles/api/auth.json" ]
  [ -s "$home/.codex/auth.json" ]
}

run_interrupted_case() {
  local root="$tmp_dir/interrupted" home config data bin log output
  home="$root/home"
  config="$root/config"
  data="$root/data"
  bin="$home/.local/bin"
  log="$root/codex.log"
  mkdir -p "$config"
  make_fake_codex "$home" "$log"
  printf 'api_key = ""\nmodel_provider = "openai"\n' > "$config/api-profile.toml"

  if output="$(env HOME="$home" PATH="$bin:$PATH" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
    CODEX_FAKE_LOG="$log" \
    bash "$repo_root/install-codex.sh" </dev/null 2>&1)"; then
    printf 'expected install-codex.sh to fail when input reaches EOF\n' >&2
    return 1
  fi

  grep -q '输入已结束，配置未完成（请输入 API 地址）' <<< "$output"
  [ -x "$bin/codex" ]
  [ -x "$bin/codex-config" ]
  [ -x "$bin/codex-status" ]
  [ -e "$data/runtime/.codex-installed" ]
}

run_recovery_case
run_preserved_profile_migration_case
run_interrupted_case
