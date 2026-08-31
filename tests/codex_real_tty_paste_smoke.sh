#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
home="$tmp_dir/home"
config="$tmp_dir/config"
data="$tmp_dir/data"
bin="$home/.local/bin"
log="$tmp_dir/codex.log"

cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
command -v script >/dev/null 2>&1 || {
  printf '缺少 util-linux script，无法执行真实 TTY 输入测试\n' >&2
  exit 1
}
mkdir -p "$bin" "$config"

cat > "$bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${CODEX_FAKE_LOG:?}"
case "${1:-}" in
  --version) printf 'codex-cli tty-test\n' ;;
  login)
    [ "${2:-}" = --with-api-key ] || exit 2
    IFS= read -r key
    printf '{"OPENAI_API_KEY":"%s"}\n' "$key" > "${CODEX_HOME:?}/auth.json"
    ;;
esac
SH
chmod +x "$bin/codex"

tty_output="$(
  printf '%s\n\n%b\n' 'https://tty-api.example.invalid/v1' $'\033[200~tty-pasted-key\033[201~' | \
    env HOME="$home" PATH="$bin:$PATH" \
      CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
      CLASH_CODEX_AUTODL_DATA_DIR="$data" \
      CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
      CODEX_FAKE_LOG="$log" \
      script -q -e -c "bash '$repo_root/install-codex.sh'" /dev/null 2>&1
)"

grep -q 'API Key 不能为空' <<< "$tty_output"
grep -q '^api_key = "tty-pasted-key"$' "$config/api-profile.toml"
grep -q '^base_url = "https://tty-api.example.invalid/v1"$' "$config/api-profile.toml"
grep -q '"OPENAI_API_KEY":"tty-pasted-key"' "$data/codex-profiles/api/auth.json"
cmp -s "$data/codex-profiles/api/auth.json" "$home/.codex/auth.json"
grep -q '^login --with-api-key$' "$log"
[ "$(stat -c '%a' "$config/api-profile.toml")" = 600 ]
[ "$(stat -c '%a' "$data/codex-profiles/api/auth.json")" = 600 ]
