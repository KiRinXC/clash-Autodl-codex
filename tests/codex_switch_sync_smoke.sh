#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_config="$tmp_dir/config"
tmp_data="$tmp_dir/data"
tmp_bin="$tmp_home/.local/bin"
fake_bin="$tmp_dir/fake-bin"

cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
mkdir -p "$tmp_home" "$fake_bin"

cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version) printf 'codex-cli test\n' ;;
  login)
    mkdir -p "${CODEX_HOME:?}"
    case "${2:-}" in
      --with-api-key) IFS= read -r key; printf '{"OPENAI_API_KEY":"%s"}\n' "$key" > "$CODEX_HOME/auth.json" ;;
      --device-auth) printf '{"tokens":{"access_token":"test"}}\n' > "$CODEX_HOME/auth.json" ;;
      *) exit 2 ;;
    esac
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
)

printf '%s\n%s\n' 'https://api.example.invalid/v1' 'test-api-key' | \
  env "${env_args[@]}" bash "$repo_root/install-codex.sh" >/dev/null

shared="$tmp_data/codex-shared"
mkdir -p "$shared/sessions/2026/01/01"
printf '%s\n' '{"type":"session_meta","payload":{"id":"thread","model_provider":"legacy"}}' \
  > "$shared/sessions/2026/01/01/rollout-test.jsonl"

env "${env_args[@]}" "$tmp_bin/codex-switch" >/dev/null
[ "$(cat "$tmp_config/active-auth")" = chatgpt ]
[ -s "$tmp_data/codex-homes/chatgpt/auth.json" ]
grep -q '"model_provider":"openai"' "$shared/sessions/2026/01/01/rollout-test.jsonl"

sed -i 's/model_provider = "openai"/model_provider = "custom-chat"/' \
  "$tmp_data/codex-homes/chatgpt/config.toml"
env "${env_args[@]}" "$tmp_bin/codex-switch" >/dev/null
[ "$(cat "$tmp_config/active-auth")" = api ]
env "${env_args[@]}" "$tmp_bin/codex-switch" >/dev/null
[ "$(cat "$tmp_config/active-auth")" = chatgpt ]
grep -q '"model_provider":"custom-chat"' "$shared/sessions/2026/01/01/rollout-test.jsonl"
env "${env_args[@]}" "$tmp_bin/codex-sync" >/dev/null

mkdir -p "$tmp_dir/busy-bin"
cat > "$tmp_dir/busy-bin/ps" <<'SH'
#!/usr/bin/env bash
printf '123 codex\n'
SH
chmod +x "$tmp_dir/busy-bin/ps"
if env "${env_args[@]}" PATH="$tmp_dir/busy-bin:$fake_bin:$PATH" "$tmp_bin/codex-switch" >/dev/null 2>&1; then
  printf 'switch should fail while Codex is running\n' >&2
  exit 1
fi
[ "$(cat "$tmp_config/active-auth")" = chatgpt ]
