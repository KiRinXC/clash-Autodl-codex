#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
runtime="$tmp_dir/runtime"
fake_bin="$tmp_dir/fake-bin"
curl_log="$tmp_dir/curl.log"

cleanup() {
  [ -z "${mihomo_pid:-}" ] || kill "$mihomo_pid" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT
mkdir -p "$runtime/lib" "$runtime/clash/bin" "$fake_bin"
cp "$repo_root/lib/codex_common.sh" "$runtime/lib/codex_common.sh"

cat > "$fake_bin/python3" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cp "$fake_bin/python3" "$fake_bin/python"
cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG:?}"
output=""
method="GET"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) shift 2 ;;
    -X) method="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$method" = PUT ]; then
  : > "$output"
  printf '204'
else
  printf '%s\n' '{"name":"CodexProxy","now":"Node A","all":["Node A","DIRECT"]}' > "$output"
  printf '200'
fi
SH
cat > "$runtime/clash/bin/yq" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'.name // ""'*) printf 'CodexProxy\n' ;;
  *'.now // ""'*) printf 'Node A\n' ;;
  *'.all | length'*) printf '2\n' ;;
  *'.all[]'*) printf 'Node A\nDIRECT\n' ;;
  *strenv*) printf '{"name":"%s"}\n' "${CODEX_PROXY_TARGET:?}" ;;
  *) exit 1 ;;
esac
SH
cat > "$fake_bin/ss" <<'SH'
#!/usr/bin/env bash
printf 'LISTEN 0 128 127.0.0.1:7890 0.0.0.0:*\n'
SH
cat > "$fake_bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$fake_bin/python3" "$fake_bin/python" "$fake_bin/curl" "$fake_bin/ss" \
  "$fake_bin/systemctl" "$runtime/clash/bin/yq"
bash -c 'exec -a mihomo sleep 120' &
mihomo_pid="$!"
printf '%s\n' "$mihomo_pid" > "$runtime/clash/mihomo.pid"

output="$(PATH="$fake_bin:$PATH" CURL_LOG="$curl_log" CLASH_CODEX_AUTODL_REPO_ROOT="$runtime" \
  bash -c ". '$runtime/lib/codex_common.sh'; CODEX_MIHOMO_CONTROLLER_URL=http://127.0.0.1:6006; CODEX_PROXY_GROUP=CodexProxy; current_proxy_node")"
[ "$output" = 'Node A' ]

switch_output="$(printf '2\n' | PATH="$fake_bin:$PATH" CURL_LOG="$curl_log" \
  CLASH_CODEX_AUTODL_REPO_ROOT="$runtime" CODEX_AUTODL_CONFIG_DIR="$tmp_dir/config" \
  bash -c ". '$runtime/lib/codex_common.sh'; CODEX_MIHOMO_CONTROLLER_URL=http://127.0.0.1:6006; CODEX_PROXY_GROUP=CodexProxy; proxy-switch")"
grep -q '已选择: DIRECT' <<< "$switch_output"
grep -q -- '-X PUT' "$curl_log"
grep -q -- "--noproxy \*" "$curl_log"
