#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_state="$tmp_dir/state"
runtime="$tmp_dir/runtime"
fake_bin="$tmp_dir/fake-bin"
listening_marker="$tmp_dir/mihomo-listening"

cleanup() {
  if [ -f "$runtime/mihomo.pid" ]; then
    pid="$(cat "$runtime/mihomo.pid" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      for _ in {1..20}; do
        kill -0 "$pid" >/dev/null 2>&1 || break
        sleep 0.05
      done
      kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_home" "$tmp_state" "$runtime/bin" "$runtime/conf" "$fake_bin"
cp "$repo_root/lib/codex_common.sh" "$runtime/lib-codex-common.sh"
mkdir -p "$runtime/lib"
mv "$runtime/lib-codex-common.sh" "$runtime/lib/codex_common.sh"
touch "$runtime/conf/config.yaml"

cat > "$fake_bin/ss" <<SH
#!/usr/bin/env bash
if [ -f '$listening_marker' ]; then
  printf 'LISTEN 0 128 127.0.0.1:17900 0.0.0.0:*\n'
  exit 0
fi
exit 1
SH
chmod +x "$fake_bin/ss"

cat > "$runtime/bin/mihomo-linux-amd64" <<SH
#!/usr/bin/env bash
touch '$listening_marker'
trap 'rm -f "$listening_marker"; exit 0' TERM INT
while :; do
  sleep 1
done
SH
chmod +x "$runtime/bin/mihomo-linux-amd64"

HOME="$tmp_home" \
CODEX_AUTODL_CONFIG_DIR="$tmp_state" \
CLASH_CODEX_AUTODL_REPO_ROOT="$runtime" \
PATH="$fake_bin:$PATH" \
bash -c '
  set -euo pipefail
  source "$1/lib/codex_common.sh"

  CODEX_PROXY_URL="http://127.0.0.1:17900"
  proxy-on >/dev/null
  [ "${http_proxy:-}" = "http://127.0.0.1:17900" ]
  grep -q "^AUTO_PROXY_ON_SHELL_START='\''true'\''" "$2/config.sh"

  proxy-off >/dev/null
  [ -z "${http_proxy:-}" ]
  grep -q "^AUTO_PROXY_ON_SHELL_START='\''false'\''" "$2/config.sh"
' _ "$runtime" "$tmp_state"
