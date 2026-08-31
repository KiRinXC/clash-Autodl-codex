#!/usr/bin/env bash
set -euo pipefail

# This test downloads the current official CLI, so it is opt-in for local/CI runs.
[ "${RUN_REAL_CODEX_E2E:-false}" = true ] || exit 0

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
home="$tmp_dir/home"
config="$tmp_dir/config"
data="$tmp_dir/data"
bin="$home/.local/bin"

cleanup() {
  case "$tmp_dir" in
    /tmp/tmp.*) rm -rf "$tmp_dir" ;;
    *) printf '拒绝清理非临时目录: %s\n' "$tmp_dir" >&2 ;;
  esac
}
trap cleanup EXIT
mkdir -p "$home"

printf '%s\n%s\n' 'http://127.0.0.1:1/v1' 'sk-local-install-test-not-a-secret' | \
  env HOME="$home" PATH="/usr/bin:/bin" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
    GITHUB_DIRECT_MAX_TIME=90 \
    bash "$repo_root/install-codex.sh" >/dev/null

[ -x "$bin/codex" ]
"$bin/codex" --version | grep -Eq '^codex-cli '
grep -q '^model = "gpt-5.6-sol"$' "$data/codex-profiles/api/config.toml"
grep -q '^base_url = "http://127.0.0.1:1/v1"$' "$data/codex-profiles/api/config.toml"
grep -q 'sk-local-install-test-not-a-secret' "$data/codex-profiles/api/auth.json"
cmp -s "$data/codex-profiles/api/auth.json" "$home/.codex/auth.json"
set +e
strict_output="$(CODEX_HOME="$home/.codex" timeout 8 "$bin/codex" --strict-config \
  exec --skip-git-repo-check --ephemeral 'config parse test' 2>&1)"
strict_status="$?"
set -e
[ "$strict_status" -eq 0 ] || [ "$strict_status" -eq 1 ] || [ "$strict_status" -eq 124 ]
! grep -q 'unknown configuration field' <<< "$strict_output"
grep -q '^provider: OpenAI$' <<< "$strict_output"
status="$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$data" "$bin/codex-status")"
grep -q 'API URL: http://127.0.0.1:1/v1' <<< "$status"

# Reuse the same current official CLI to verify adoption of a pre-existing API
# login. auth.json stays byte-identical; config.toml receives only managed keys.
import_home="$tmp_dir/import-home"
import_native="$import_home/.codex"
import_bin="$import_home/.local/bin"
import_config="$tmp_dir/import-config"
import_data="$tmp_dir/import-data"
mkdir -p "$import_native" "$import_bin"
cp "$bin/codex" "$import_bin/codex"
chmod +x "$import_bin/codex"
cat > "$import_native/config.toml" <<'TOML'
cli_auth_credentials_store = "file"
model = "gpt-5.6-sol"
model_provider = "existing_relay"

[model_providers.existing_relay]
name = "Existing Relay"
base_url = "http://127.0.0.1:2/v1"
wire_api = "responses"
requires_openai_auth = true
TOML
printf '%s\n' 'sk-local-import-test-not-a-secret' | \
  CODEX_HOME="$import_native" "$import_bin/codex" login --with-api-key >/dev/null
native_config_before="$(cksum "$import_native/config.toml")"
native_auth_before="$(cksum "$import_native/auth.json")"

env HOME="$import_home" PATH="$import_bin:/usr/bin:/bin" \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$import_config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$import_data" \
  CLASH_CODEX_AUTODL_USER_BIN_DIR="$import_bin" \
  bash "$repo_root/install-codex.sh" </dev/null >/dev/null
[ "$(cat "$import_config/active-auth")" = api ]
grep -q '^model_provider = "existing_relay"$' "$import_data/codex-profiles/api/config.toml"
grep -q '^base_url = "http://127.0.0.1:2/v1"$' "$import_config/api-profile.toml"
CODEX_HOME="$import_native" "$import_bin/codex" login status 2>&1 |
  grep -q 'Logged in using an API key'
[ "$(cksum "$import_native/config.toml")" != "$native_config_before" ]
grep -q '^forced_login_method = "api"$' "$import_native/config.toml"
[ "$(cksum "$import_native/auth.json")" = "$native_auth_before" ]
[ ! -e "$import_data/codex-shared" ]
[ ! -e "$import_data/install-manifest" ]

HOME="$home" PATH="$bin:/usr/bin:/bin" \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$data" \
  CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
  bash "$repo_root/uninstall.sh" codex >/dev/null
[ ! -e "$bin/codex" ]
[ -s "$config/api-profile.toml" ]
[ -s "$data/codex-profiles/api/auth.json" ]
