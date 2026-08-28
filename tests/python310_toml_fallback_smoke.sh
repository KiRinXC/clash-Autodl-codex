#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
fake_bin="$tmp_dir/bin"
config="$tmp_dir/config"
real_python="$(command -v python3 || command -v python)"

cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
mkdir -p "$fake_bin" "$config"

# Simulate Python 3.10: Python itself works, but scripts importing tomllib
# return without a parsed value. The shell parser must still recover api_key.
cat > "$fake_bin/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source_code="$(cat)"
case "$source_code" in
  *'import tomllib'*) exit 0 ;;
esac
printf '%s\n' "$source_code" | "${REAL_PYTHON:?}" "$@"
SH
chmod +x "$fake_bin/python3"

cat > "$config/api-profile.toml" <<'EOF'
api_key = "python310-test-key"
model_provider = "OpenAI"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "https://python310-api.example.invalid/v1"
wire_api = "responses"
requires_openai_auth = true
EOF

HOME="$tmp_dir/home" PATH="$fake_bin:/usr/bin:/bin" REAL_PYTHON="$real_python" \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
  bash -c "
    set -euo pipefail
    . '$repo_root/lib/codex_common.sh'
    . '$repo_root/lib/codex_profiles.sh'
    [ \"\$(codex_api_source_key '$config/api-profile.toml')\" = python310-test-key ]
    codex_api_source_is_usable '$config/api-profile.toml'
  "
