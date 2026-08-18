#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_config="$tmp_dir/config"
tmp_data="$tmp_dir/data"
fake_bin="$tmp_dir/bin"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_home" "$tmp_config" "$tmp_data" "$fake_bin"

cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

home="${CODEX_HOME:?}"
mkdir -p "$home"

case "${1:-}" in
  --version)
    printf 'codex-cli test\n'
    ;;
  login)
    case "${2:-}" in
      --with-api-key)
        IFS= read -r key
        printf 'api:%s\n' "$key" > "$home/auth.json"
        ;;
      --device-auth)
        printf 'chatgpt\n' > "$home/auth.json"
        ;;
      status)
        [ -s "$home/auth.json" ]
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  exec)
    output_file=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --output-last-message)
          output_file="$2"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    [ -z "$output_file" ] || printf 'CODEX_READY\n' > "$output_file"
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "$fake_bin/codex"

run_cli() {
  HOME="$tmp_home" \
  MSYS='winsymlinks:sys' \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$tmp_data" \
  CLASH_CODEX_AUTODL_CODEX_BINARY="$fake_bin/codex" \
  bash "$repo_root/clash-codex" "$@"
}

printf '%s\n%s\n' 'https://api.example.invalid/v1' 'test-api-key' | run_cli auth api >/dev/null
[ "$(cat "$tmp_config/active-auth")" = 'api' ]
grep -q 'api:test-api-key' "$tmp_data/codex-homes/api/auth.json"
[ ! -e "$tmp_home/.codex/auth.json" ]
grep -q '^model_provider = "openai"$' "$tmp_data/codex-homes/api/config.toml"
grep -q '^sqlite_home = ' "$tmp_data/codex-homes/api/config.toml"
[ -L "$tmp_data/codex-homes/api/sessions" ]

printf '\n' | run_cli auth api >/dev/null

printf '%s\n%s\n' 'https://new-api.example.invalid/v1' 'n' | run_cli auth api --edit >/dev/null
[ "$(cat "$tmp_config/api-base-url")" = 'https://new-api.example.invalid/v1' ]
grep -q 'api:test-api-key' "$tmp_data/codex-homes/api/auth.json"

printf '%s\n%s\n' '-' 'n' | run_cli auth api --edit >/dev/null
[ -z "$(cat "$tmp_config/api-base-url")" ]
! grep -q '^base_url' "$tmp_data/codex-homes/api/config.toml"

run_cli auth chatgpt >/dev/null
[ "$(cat "$tmp_config/active-auth")" = 'chatgpt' ]
grep -q '^chatgpt$' "$tmp_data/codex-homes/chatgpt/auth.json"
grep -q '^model_provider = "openai"$' "$tmp_data/codex-homes/chatgpt/config.toml"
[ "$(readlink "$tmp_data/codex-homes/api/sessions")" = "$(readlink "$tmp_data/codex-homes/chatgpt/sessions")" ]

printf '\n' | run_cli auth chatgpt >/dev/null
[ -d "$tmp_data/codex-homes/api" ]
[ -d "$tmp_data/codex-homes/chatgpt" ]
