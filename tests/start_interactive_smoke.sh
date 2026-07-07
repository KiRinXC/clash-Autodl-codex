#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_home="$(mktemp -d)"
tmp_state="$(mktemp -d)"
tmp_dir="$(mktemp -d)"
work_dir="$tmp_dir/work"
fake_bin="$(mktemp -d)"

cleanup() {
  if [ -f "$work_dir/mihomo.pid" ]; then
    pid="$(cat "$work_dir/mihomo.pid" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$tmp_home" "$tmp_state" "$fake_bin" "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$work_dir/lib" "$work_dir/bin" "$fake_bin"
cp "$repo_root/start.sh" "$work_dir/start.sh"
cp "$repo_root/setup_mihomo.sh" "$work_dir/setup_mihomo.sh"
cp "$repo_root/converter.sh" "$work_dir/converter.sh"
cp "$repo_root/lib/codex_common.sh" "$work_dir/lib/codex_common.sh"

cat > "$work_dir/bin/yq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "eval" ] && [ "${2:-}" = "-i" ]; then
  expression="${3:-}"
  case "$expression" in
    *'if '*)
      printf 'fake yq: unsupported conditional expression\n' >&2
      exit 7
      ;;
  esac

  config_file="${@: -1}"
  {
    printf 'mixed-port: %s\n' "${CODEX_PROXY_PORT:-}"
    printf 'external-controller: %s\n' "${CODEX_MIHOMO_CONTROLLER_BIND:-}"
    printf 'overseas-host: %s\n' "${CODEX_OVERSEAS_HOST:-}"
  } > "$config_file"
  exit 0
fi

if [ "${1:-}" = "eval" ]; then
  query="${2:-}"
  case "$query" in
    '.proxies | length')
      exit 0
      ;;
    *CodexProxy*length*)
      printf '1\n'
      exit 0
      ;;
  esac
fi

exit 0
SH
chmod +x "$work_dir/bin/yq"

cat > "$work_dir/bin/mihomo-linux-amd64" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do
  sleep 1
done
SH
chmod +x "$work_dir/bin/mihomo-linux-amd64"

cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ -n "$output_file" ]; then
  if [ "${output_file##*/}" = "geoip.metadb" ]; then
    dd if=/dev/zero of="$output_file" bs=1048576 count=6 >/dev/null 2>&1
    exit 0
  fi

  cat > "$output_file" <<'YAML'
proxies:
  - name: Node A
    type: http
    server: example.invalid
    port: 443
rules: []
YAML
fi
SH
chmod +x "$fake_bin/curl"

cat > "$fake_bin/ss" <<'SH'
#!/usr/bin/env bash
printf 'LISTEN 0 128 127.0.0.1:7890 0.0.0.0:*\n'
SH
chmod +x "$fake_bin/ss"

cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
out_file=""
while [ "${1:-}" != "" ]; do
  case "$1" in
    --output-last-message)
      out_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [ -n "$out_file" ]; then
  printf '%s\n' "CODEX_RELAY_READY" > "$out_file"
fi
exit 0
SH
chmod +x "$fake_bin/codex"

output="$(
  HOME="$tmp_home" \
  PATH="$fake_bin:$PATH" \
  CODEX_AUTODL_CONFIG_DIR="$tmp_state" \
  bash "$work_dir/start.sh" <<'EOF'
https://subscription.example.invalid/clash.yaml
https://domestic.example.invalid/api
https://overseas.example.invalid/api
test-api-key
EOF
  2>&1
)"

grep -q 'proxy-status' <<<"$output"
grep -q 'codex-use-in' <<<"$output"
grep -q '\[WARN\].*当前终端不会自动刷新；请重新打开一个终端' <<<"$output"
grep -q '请输入 Clash/Mihomo 订阅地址' "$work_dir/start.sh"
grep -q '请输入国内直连中转站地址' "$work_dir/start.sh"
grep -q '请输入国外代理中转站地址' "$work_dir/start.sh"
grep -q '请输入 OpenAI API Key' "$work_dir/start.sh"
grep -q "CLASH_URL='https://subscription.example.invalid/clash.yaml'" "$tmp_state/config.sh"
grep -q "CODEX_ACTIVE_RELAY='domestic'" "$tmp_state/config.sh"
grep -q "AUTO_PROXY_ON_SHELL_START='true'" "$tmp_state/config.sh"
grep -q '"OPENAI_API_KEY": "test-api-key"' "$tmp_home/.codex/auth.json"
grep -q 'base_url = "https://domestic.example.invalid/api"' "$tmp_home/.codex/config.toml"
grep -q '\.local/bin:\$PATH' "$tmp_home/.codex/clash-codex-autodl.sh"
grep -q 'clash-codex-autodl.sh' "$tmp_home/.bashrc"
