#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_config="$tmp_dir/config"
tmp_data="$tmp_dir/data"
fake_codex="$tmp_dir/codex"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_home/.codex" "$tmp_config" "$tmp_data"
cat > "$tmp_home/.codex/auth.json" <<'JSON'
{"OPENAI_API_KEY":"legacy-test-key"}
JSON
cat > "$tmp_home/.codex/config.toml" <<'TOML'
model_provider = "OpenAI"

[model_providers.OpenAI]
base_url = "https://legacy-api.example.invalid/v1"
TOML
cp "$tmp_home/.codex/auth.json" "$tmp_dir/original-auth.json"
cp "$tmp_home/.codex/config.toml" "$tmp_dir/original-config.toml"

cat > "$fake_codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
  [ -s "${CODEX_HOME:?}/auth.json" ]
  exit
fi
exit 2
SH
chmod +x "$fake_codex"

printf '\n' | HOME="$tmp_home" \
  MSYS='winsymlinks:sys' \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$tmp_data" \
  CLASH_CODEX_AUTODL_CODEX_BINARY="$fake_codex" \
  bash "$repo_root/clash-codex" auth api >/dev/null

cmp "$tmp_dir/original-auth.json" "$tmp_home/.codex/auth.json"
cmp "$tmp_dir/original-config.toml" "$tmp_home/.codex/config.toml"
cmp "$tmp_home/.codex/auth.json" "$tmp_data/codex-homes/api/auth.json"
grep -q 'legacy-api.example.invalid' "$tmp_data/codex-homes/api/config.toml"
[ "$(cat "$tmp_config/active-auth")" = api ]
