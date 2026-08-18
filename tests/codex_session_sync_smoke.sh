#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_config="$tmp_dir/config"
tmp_data="$tmp_dir/data"
fake_bin="$tmp_dir/fake-bin"
api_home="$tmp_data/codex-homes/api"
chatgpt_home="$tmp_data/codex-homes/chatgpt"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_home/.codex/sessions/2026/01/01" \
  "$api_home/sessions/2026/01/01" "$api_home/archived_sessions" \
  "$chatgpt_home/sessions/2026/02/02" "$fake_bin" "$tmp_config"

cat > "$tmp_home/.codex/sessions/2026/01/01/rollout-conflict.jsonl" <<'JSONL'
{"type":"session_meta","payload":{"id":"native-thread","model_provider":"OpenAI"}}
{"type":"event_msg","payload":{"type":"user_message","message":"native"}}
JSONL
cat > "$api_home/sessions/2026/01/01/rollout-conflict.jsonl" <<'JSONL'
{"type":"session_meta","payload":{"id":"api-thread","model_provider":"OpenAI"}}
{"type":"event_msg","payload":{"type":"user_message","message":"api divergent"}}
JSONL
cat > "$api_home/archived_sessions/rollout-api.jsonl" <<'JSONL'
{"type":"session_meta","payload":{"id":"api-archive","model_provider":"OpenAI"}}
JSONL
cat > "$chatgpt_home/sessions/2026/02/02/rollout-chatgpt.jsonl" <<'JSONL'
{"type":"session_meta","payload":{"id":"chatgpt-thread","model_provider":"openai"}}
JSONL

printf '%s\n' '{"id":"native-thread","thread_name":"shared name","updated_at":"2026-01-01T00:00:00Z"}' \
  > "$tmp_home/.codex/session_index.jsonl"
cp "$tmp_home/.codex/session_index.jsonl" "$api_home/session_index.jsonl"
printf '%s\n' '{"id":"chatgpt-thread","thread_name":"chat name","updated_at":"2026-02-02T00:00:00Z"}' \
  > "$chatgpt_home/session_index.jsonl"

cat > "$api_home/config.toml" <<'TOML'
cli_auth_credentials_store = "file"
forced_login_method = "api"
model_provider = "OpenAI"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "https://old.example.invalid/v1"
TOML
cat > "$chatgpt_home/config.toml" <<'TOML'
cli_auth_credentials_store = "file"
forced_login_method = "chatgpt"
TOML
printf 'api-auth\n' > "$api_home/auth.json"
printf 'chatgpt-auth\n' > "$chatgpt_home/auth.json"
printf 'https://api.example.invalid/v1\n' > "$tmp_config/api-base-url"

cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
  [ -s "${CODEX_HOME:?}/auth.json" ]
  exit
fi
[ -z "${CODEX_RUN_LOG:-}" ] || printf '%s\n' "${CODEX_HOME:?}" > "$CODEX_RUN_LOG"
exit 0
SH
chmod +x "$fake_bin/codex"

# Force the portable fallback paths under Git Bash; production uses Python JSON parsing when available.
cat > "$fake_bin/python3" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cp "$fake_bin/python3" "$fake_bin/python"
chmod +x "$fake_bin/python3" "$fake_bin/python"

run_cli() {
  HOME="$tmp_home" \
  MSYS='winsymlinks:sys' \
  PATH="$fake_bin:$PATH" \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$tmp_data" \
  CLASH_CODEX_AUTODL_CODEX_BINARY="$fake_bin/codex" \
  CODEX_RUN_LOG="$tmp_dir/run-home" \
  bash "$repo_root/clash-codex" "$@"
}

run_cli sessions sync >/dev/null

shared="$tmp_data/codex-shared"
[ -f "$shared/.layout-version" ]
[ -f "$shared/sessions/2026/01/01/rollout-conflict.jsonl" ]
[ -f "$shared/sessions/2026/02/02/rollout-chatgpt.jsonl" ]
[ -f "$shared/archived_sessions/rollout-api.jsonl" ]
grep -q '"model_provider":"openai"' "$shared/sessions/2026/01/01/rollout-conflict.jsonl"
grep -q 'native-thread' "$shared/sessions/2026/01/01/rollout-conflict.jsonl"
find "$shared/import-conflicts" -type f -name 'rollout-conflict.jsonl' | grep -q .

[ -L "$api_home/sessions" ]
[ -L "$chatgpt_home/sessions" ]
[ "$(readlink "$api_home/sessions")" = "$shared/sessions" ]
[ "$(readlink "$chatgpt_home/sessions")" = "$shared/sessions" ]
[ "$(readlink "$api_home/session_index.jsonl")" = "$shared/session_index.jsonl" ]
[ "$(readlink "$chatgpt_home/session_index.jsonl")" = "$shared/session_index.jsonl" ]

grep -q '^model_provider = "openai"$' "$api_home/config.toml"
grep -q '^openai_base_url = "https://api.example.invalid/v1"$' "$api_home/config.toml"
grep -q '^sqlite_home = ' "$api_home/config.toml"
grep -q '^model_provider = "openai"$' "$chatgpt_home/config.toml"
grep -q '^sqlite_home = ' "$chatgpt_home/config.toml"
grep -q '^api-auth$' "$api_home/auth.json"
grep -q '^chatgpt-auth$' "$chatgpt_home/auth.json"
[ ! -e "$shared/auth.json" ]

# Native user data is copied, never rewritten in place.
grep -q '"model_provider":"OpenAI"' "$tmp_home/.codex/sessions/2026/01/01/rollout-conflict.jsonl"
[ "$(grep -c 'native-thread' "$shared/session_index.jsonl")" -eq 1 ]
grep -q 'chatgpt-thread' "$shared/session_index.jsonl"

run_cli auth api --use >/dev/null
[ "$(cat "$tmp_config/active-auth")" = api ]
run_cli run --version
[ "$(cat "$tmp_dir/run-home")" = "$api_home" ]
run_cli auth chatgpt --use >/dev/null
[ "$(cat "$tmp_config/active-auth")" = chatgpt ]
run_cli run --version
[ "$(cat "$tmp_dir/run-home")" = "$chatgpt_home" ]
[ "$(readlink "$api_home/sessions")" = "$(readlink "$chatgpt_home/sessions")" ]
