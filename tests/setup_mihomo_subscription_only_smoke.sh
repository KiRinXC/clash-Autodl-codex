#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
work_dir="$tmp_dir/work"
fake_bin="$tmp_dir/fake-bin"

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
    printf 'proxy-group: %s\n' "${CODEX_PROXY_GROUP_NAME:-}"
  } > "$config_file"
  exit 0
fi

if [ "${1:-}" = "eval" ]; then
  query="${2:-}"
  case "$query" in
    '.proxies | length')
      exit 0
      ;;
    *CODEX_PROXY_GROUP_NAME*length*)
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
printf 'LISTEN 0 128 127.0.0.1:%s 0.0.0.0:*\n' "${EXPECTED_PROXY_PORT:?}"
SH
chmod +x "$fake_bin/ss"

cat > "$tmp_dir/config.sh" <<'EOF'
export CLASH_URL='https://subscription.example.invalid/clash.yaml'
export CODEX_PROXY_URL='http://127.0.0.1:17890'
export CODEX_MIHOMO_CONTROLLER_URL='http://127.0.0.1:16006'
EOF

mkdir -p "$work_dir/conf"
dd if=/dev/zero of="$work_dir/conf/geoip.metadb" bs=1048576 count=2 >/dev/null 2>&1

PATH="$fake_bin:$PATH" EXPECTED_PROXY_PORT=17890 bash "$work_dir/setup_mihomo.sh" "$tmp_dir/config.sh"

grep -qx 'mixed-port: 17890' "$work_dir/conf/config.yaml"
grep -qx 'external-controller: 127.0.0.1:16006' "$work_dir/conf/config.yaml"
grep -qx 'proxy-group: CodexProxy' "$work_dir/conf/config.yaml"
geoip_size="$(wc -c < "$work_dir/conf/geoip.metadb" | tr -d '[:space:]')"
[ "$geoip_size" -ge 5242880 ]
