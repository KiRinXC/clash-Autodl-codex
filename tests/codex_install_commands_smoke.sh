#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_config="$tmp_dir/config"
tmp_data="$tmp_dir/data"
tmp_bin="$tmp_home/.local/bin"
fake_bin="$tmp_dir/fake-bin"
fake_log="$tmp_dir/codex.log"

cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
mkdir -p "$tmp_home" "$fake_bin"

cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${CODEX_FAKE_LOG:?}"
case "${1:-}" in
  --version) printf 'codex-cli test\n' ;;
  login)
    case "${2:-}" in
      --with-api-key)
        IFS= read -r key
        printf '{"OPENAI_API_KEY":"%s"}\n' "$key" > "${CODEX_HOME:?}/auth.json"
        ;;
      --device-auth) printf '{"tokens":{"access_token":"test"}}\n' > "${CODEX_HOME:?}/auth.json" ;;
      *) exit 2 ;;
    esac
    ;;
  exec)
    output=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --output-last-message) output="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'CODEX_READY\n' > "$output"
    ;;
esac
SH
chmod +x "$fake_bin/codex"

env_args=(
  HOME="$tmp_home"
  PATH="$fake_bin:$PATH"
  CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_config"
  CLASH_CODEX_AUTODL_DATA_DIR="$tmp_data"
  CLASH_CODEX_AUTODL_USER_BIN_DIR="$tmp_bin"
  CLASH_CODEX_AUTODL_CODEX_BINARY="$fake_bin/codex"
  CODEX_FAKE_LOG="$fake_log"
)

printf '%s\n%s\n' 'https://api.example.invalid/v1' 'test-api-key' | \
  env "${env_args[@]}" bash "$repo_root/install-codex.sh" >/dev/null

for name in codex-verify codex-status codex-switch codex-sync codex-config; do
  [ -x "$tmp_bin/$name" ]
done
[ ! -e "$tmp_bin/clash-codex" ]
[ ! -e "$tmp_bin/codex-autodl" ]
[ -x "$tmp_data/runtime/command.sh" ]
[ -s "$tmp_config/api-profile.toml" ]
grep -q '^api_key = "test-api-key"$' "$tmp_config/api-profile.toml"
grep -q '^model_provider = "OpenAI"$' "$tmp_data/codex-homes/api/config.toml"
grep -q '^model = "gpt-5.6-sol"$' "$tmp_data/codex-homes/api/config.toml"
grep -q '^base_url = "https://api.example.invalid/v1"$' "$tmp_data/codex-homes/api/config.toml"
grep -q '^network_access = true$' "$tmp_data/codex-homes/api/config.toml"
! grep -q 'api_key' "$tmp_data/codex-homes/api/config.toml"
grep -q 'OPENAI_API_KEY' "$tmp_data/codex-homes/api/auth.json"
grep -q '^login --with-api-key$' "$fake_log"
! grep -q '^exec ' "$fake_log"

: > "$fake_log"
status="$(env "${env_args[@]}" "$tmp_bin/codex-status")"
grep -q '当前配置: API' <<< "$status"
grep -q 'API URL: https://api.example.invalid/v1' <<< "$status"
! grep -q 'test-api-key' <<< "$status"
[ ! -s "$fake_log" ]

shell_status="$(env "${env_args[@]}" "$tmp_data/runtime/command.sh" codex shell-status)"
grep -q '^\[codex\] API | https://api.example.invalid/v1$' <<< "$shell_status"
grep -q '^\[sync\] 已同步 | 0 个会话$' <<< "$shell_status"
[ ! -s "$fake_log" ]

terminal_status="$(env -i HOME="$tmp_home" PATH="/usr/bin:/bin" TERM=dumb \
  /bin/bash --noprofile --rcfile "$tmp_home/.bashrc" -i -c exit 2>&1)"
grep -q '\[codex\] API | https://api.example.invalid/v1' <<< "$terminal_status"
grep -q '\[sync\] 已同步 | 0 个会话' <<< "$terminal_status"
[ ! -s "$fake_log" ]

before_runtime="$(cksum "$tmp_data/codex-homes/api/config.toml")"
cat > "$tmp_dir/bad-editor" <<'SH'
#!/usr/bin/env bash
sed -i 's#https://api.example.invalid/v1#ftp://invalid.example.invalid/v1#' "$1"
SH
chmod +x "$tmp_dir/bad-editor"
if env "${env_args[@]}" CODEX_CONFIG_EDITOR="$tmp_dir/bad-editor" \
  "$tmp_bin/codex-config" >/dev/null 2>&1; then
  printf 'invalid API URL should not be applied\n' >&2
  exit 1
fi
[ "$(cksum "$tmp_data/codex-homes/api/config.toml")" = "$before_runtime" ]

cat > "$tmp_dir/editor" <<'SH'
#!/usr/bin/env bash
sed -i 's#ftp://invalid.example.invalid/v1#https://new-api.example.invalid/v1#' "$1"
SH
chmod +x "$tmp_dir/editor"
env "${env_args[@]}" CODEX_CONFIG_EDITOR="$tmp_dir/editor" "$tmp_bin/codex-config" >/dev/null
grep -q 'new-api.example.invalid' "$tmp_data/codex-homes/api/config.toml"
! grep -q '^exec ' "$fake_log"

env "${env_args[@]}" "$tmp_bin/codex-verify" >/dev/null
grep -q '^exec ' "$fake_log"
grep -q 'success$' "$tmp_config/last-verify"

# Component uninstall preserves user profiles; reinstall must recover without asking again.
env "${env_args[@]}" bash "$repo_root/uninstall.sh" codex >/dev/null
[ ! -e "$tmp_bin/codex-status" ]
[ -s "$tmp_config/api-profile.toml" ]
[ -s "$tmp_data/codex-homes/api/auth.json" ]
env "${env_args[@]}" bash "$repo_root/install-codex.sh" </dev/null >/dev/null
[ -x "$tmp_bin/codex-status" ]
grep -q 'new-api.example.invalid' "$tmp_data/codex-homes/api/config.toml"
