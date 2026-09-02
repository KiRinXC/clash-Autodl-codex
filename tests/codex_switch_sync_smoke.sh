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
    mkdir -p "${CODEX_HOME:?}"
    case "${2:-}" in
      --with-api-key)
        IFS= read -r key
        printf '{"auth_mode":"apiKey","OPENAI_API_KEY":"%s"}\n' "$key" > "$CODEX_HOME/auth.json"
        ;;
      --device-auth)
        printf '{"auth_mode":"chatgpt","tokens":{"access_token":"chat-token"}}\n' > "$CODEX_HOME/auth.json"
        ;;
      *) exit 2 ;;
    esac
    ;;
esac
SH
chmod +x "$fake_bin/codex"
: > "$fake_log"

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

native="$tmp_home/.codex"
profiles="$tmp_data/codex-profiles"
[ -z "$(find "$native" -mindepth 1 -maxdepth 1 ! -name auth.json ! -name config.toml -print -quit)" ]
mkdir -p "$native/sessions/2026/01/01"
mkdir -p "$native/archived_sessions/2025/12/31"
printf '%s\n' '{"type":"session_meta","payload":{"id":"thread","model_provider":"original"}}' \
  > "$native/sessions/2026/01/01/rollout-test.jsonl"
printf '%s\n' '{"type":"response_item","payload":{"preserve":"exactly"}}' \
  >> "$native/sessions/2026/01/01/rollout-test.jsonl"
session_tail_before="$(tail -n +2 "$native/sessions/2026/01/01/rollout-test.jsonl" | cksum)"
printf '%s\n' '{"type":"session_meta","payload":{"id":"archived","model_provider":"original"}}' \
  > "$native/archived_sessions/2025/12/31/rollout-archived.jsonl"
mkdir -p "$native/sqlite"
python3 - "$native/sqlite/state_5.sqlite" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
connection.execute('CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT)')
connection.executemany(
    'INSERT INTO threads VALUES (?, ?)',
    [('thread', 'original'), ('archived', 'original')],
)
connection.commit()
connection.close()
PY
sed -i '1i approval_policy = "on-request"' "$native/config.toml"
sed -i "1i sqlite_home = \"$native/sqlite\"" "$native/config.toml"
printf '\n[mcp_servers.keep-me]\ncommand = "keep-command"\n' >> "$native/config.toml"

env "${env_args[@]}" "$tmp_bin/codex-switch" >/dev/null
grep -q '^login --device-auth$' "$fake_log"
[ "$(cat "$tmp_config/active-auth")" = chatgpt ]
[ -s "$profiles/chatgpt/auth.json" ]
cmp -s "$profiles/chatgpt/auth.json" "$native/auth.json"
grep -q '"auth_mode":"chatgpt"' "$native/auth.json"
! grep -q 'OPENAI_API_KEY' "$native/auth.json"
grep -q '^forced_login_method = "chatgpt"$' "$native/config.toml"
grep -q '^model_provider = "openai"$' "$native/config.toml"
grep -q '^approval_policy = "on-request"$' "$native/config.toml"
grep -q "^sqlite_home = \"$native/sqlite\"$" "$native/config.toml"
grep -q '^\[mcp_servers.keep-me\]$' "$native/config.toml"
grep -q '^command = "keep-command"$' "$native/config.toml"
grep -q '"model_provider":"openai"' "$native/sessions/2026/01/01/rollout-test.jsonl"
grep -q '"model_provider":"openai"' "$native/archived_sessions/2025/12/31/rollout-archived.jsonl"
python3 - "$native/sqlite/state_5.sqlite" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
assert {row[0].lower() for row in connection.execute('SELECT DISTINCT model_provider FROM threads')} == {'openai'}
connection.close()
PY
[ "$(tail -n +2 "$native/sessions/2026/01/01/rollout-test.jsonl" | cksum)" = "$session_tail_before" ]
[ -z "$(find "$tmp_data" -maxdepth 1 -type d -name '.session-provider-sync.*' -print -quit)" ]
[ ! -e "$tmp_data/codex-shared" ]
[ ! -L "$native/sessions" ]
python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$native/config.toml"

env "${env_args[@]}" "$tmp_bin/codex-switch" >/dev/null
[ "$(cat "$tmp_config/active-auth")" = api ]
cmp -s "$profiles/api/auth.json" "$native/auth.json"
grep -q 'OPENAI_API_KEY' "$native/auth.json"
! grep -q '"tokens"' "$native/auth.json"
grep -q '^forced_login_method = "api"$' "$native/config.toml"
grep -q '^model_provider = "OpenAI"$' "$native/config.toml"
grep -q '^approval_policy = "on-request"$' "$native/config.toml"
grep -q "^sqlite_home = \"$native/sqlite\"$" "$native/config.toml"
grep -q '^\[mcp_servers.keep-me\]$' "$native/config.toml"
grep -q '^command = "keep-command"$' "$native/config.toml"
grep -q '"model_provider":"OpenAI"' "$native/sessions/2026/01/01/rollout-test.jsonl"
grep -q '"model_provider":"OpenAI"' "$native/archived_sessions/2025/12/31/rollout-archived.jsonl"
python3 - "$native/sqlite/state_5.sqlite" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
assert {row[0].lower() for row in connection.execute('SELECT DISTINCT model_provider FROM threads')} == {'openai'}
connection.close()
PY
[ "$(tail -n +2 "$native/sessions/2026/01/01/rollout-test.jsonl" | cksum)" = "$session_tail_before" ]
python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$native/config.toml"

env "${env_args[@]}" "$tmp_bin/codex-switch" >/dev/null
[ "$(cat "$tmp_config/active-auth")" = chatgpt ]
cmp -s "$profiles/chatgpt/auth.json" "$native/auth.json"
grep -q '"model_provider":"openai"' "$native/sessions/2026/01/01/rollout-test.jsonl"

printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":"refreshed-token"}}' > "$native/auth.json"
sed -i '1 s/"model_provider":"openai"/"model_provider":"stale-provider"/' \
  "$native/sessions/2026/01/01/rollout-test.jsonl"
mkdir -p "$tmp_dir/no-python-bin"
for name in python3 python; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 127' > "$tmp_dir/no-python-bin/$name"
  chmod +x "$tmp_dir/no-python-bin/$name"
done
if env "${env_args[@]}" PATH="$tmp_dir/no-python-bin:$fake_bin:$PATH" "$tmp_bin/codex-sync" >/dev/null 2>&1; then
  printf 'sync should fail when state_5.sqlite exists without Python\n' >&2
  exit 1
fi
cmp -s "$profiles/chatgpt/auth.json" "$native/auth.json"
grep -q '"model_provider":"stale-provider"' "$native/sessions/2026/01/01/rollout-test.jsonl"
[ "$(tail -n +2 "$native/sessions/2026/01/01/rollout-test.jsonl" | cksum)" = "$session_tail_before" ]
python3 - "$native/sqlite/state_5.sqlite" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
assert {row[0].lower() for row in connection.execute('SELECT DISTINCT model_provider FROM threads')} == {'openai'}
connection.close()
PY

printf '%s\n' 'not-json' > "$native/sessions/2026/01/01/rollout-invalid.jsonl"
valid_session_before="$(cksum "$native/sessions/2026/01/01/rollout-test.jsonl")"
native_auth_before="$(cksum "$native/auth.json")"
api_profile_before="$(cksum "$profiles/api/auth.json" "$profiles/api/config.toml")"
if env "${env_args[@]}" "$tmp_bin/codex-switch" >/dev/null 2>&1; then
  printf 'switch should fail when a rollout cannot be safely rewritten\n' >&2
  exit 1
fi
[ "$(cat "$tmp_config/active-auth")" = chatgpt ]
[ "$(cksum "$native/sessions/2026/01/01/rollout-test.jsonl")" = "$valid_session_before" ]
[ "$(cksum "$native/auth.json")" = "$native_auth_before" ]
 [ "$(cksum "$profiles/api/auth.json" "$profiles/api/config.toml")" = "$api_profile_before" ]
python3 - "$native/sqlite/state_5.sqlite" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
assert {row[0].lower() for row in connection.execute('SELECT DISTINCT model_provider FROM threads')} == {'openai'}
connection.close()
PY
rm -f "$native/sessions/2026/01/01/rollout-invalid.jsonl"

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
