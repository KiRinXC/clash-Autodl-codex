#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
work_dir="$tmp_dir/work"
fake_bin="$tmp_dir/fake-bin"
listening_marker="$tmp_dir/mihomo-listening"

cleanup() {
  if [ -f "$work_dir/mihomo.pid" ]; then
    pid="$(cat "$work_dir/mihomo.pid" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$work_dir/lib" "$work_dir/bin" "$fake_bin"
cp "$repo_root/setup_mihomo.sh" "$work_dir/setup_mihomo.sh"
cp "$repo_root/converter.sh" "$work_dir/converter.sh"
cp "$repo_root/lib/codex_common.sh" "$work_dir/lib/codex_common.sh"

cat > "$work_dir/bin/yq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "eval" ] && [ "${2:-}" = "-i" ]; then
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

cat > "$work_dir/bin/mihomo-linux-amd64" <<SH
#!/usr/bin/env bash
touch '$listening_marker'
trap 'rm -f "$listening_marker"; exit 0' TERM INT
while :; do
  sleep 1
done
SH
chmod +x "$work_dir/bin/mihomo-linux-amd64"

cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

for name in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
  value="${!name:-}"
  if [ "$value" = "http://127.0.0.1:17890" ]; then
    printf 'unexpected dead proxy in %s\n' "$name" >&2
    exit 77
  fi
done

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

cat > "$fake_bin/ss" <<SH
#!/usr/bin/env bash
if [ -f '$listening_marker' ]; then
  printf 'LISTEN 0 128 127.0.0.1:17890 0.0.0.0:*\n'
  exit 0
fi
exit 1
SH
chmod +x "$fake_bin/ss"

cat > "$tmp_dir/config.sh" <<'EOF'
export CLASH_URL='https://subscription.example.invalid/clash.yaml'
export CODEX_DOMESTIC_BASE_URL='https://domestic.example.invalid/api'
export CODEX_OVERSEAS_BASE_URL='https://overseas.example.invalid/api'
export CODEX_PROXY_URL='http://127.0.0.1:17890'
export CODEX_MIHOMO_CONTROLLER_URL='http://127.0.0.1:16006'
EOF

PATH="$fake_bin:$PATH" \
http_proxy='http://127.0.0.1:17890' \
https_proxy='http://127.0.0.1:17890' \
HTTP_PROXY='http://127.0.0.1:17890' \
HTTPS_PROXY='http://127.0.0.1:17890' \
EXPECTED_PROXY_PORT=17890 \
bash "$work_dir/setup_mihomo.sh" "$tmp_dir/config.sh"

grep -qx 'mixed-port: 17890' "$work_dir/conf/config.yaml"
