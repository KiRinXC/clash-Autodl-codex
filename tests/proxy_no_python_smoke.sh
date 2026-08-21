#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
runtime="$tmp_dir/runtime"
fake_bin="$tmp_dir/fake-bin"
curl_log="$tmp_dir/curl.log"

cleanup() { rm -rf "$tmp_dir"; }
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
case " $* " in
  *' -X PUT '*) exit 0 ;;
  *) printf '%s\n' '{"now":"Node A","all":["DIRECT","Node A"]}' ;;
esac
SH
cat > "$runtime/clash/bin/yq" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'.now // "DIRECT"'*) printf 'Node A\n' ;;
  *'.all[]'*) printf 'DIRECT\nNode A\n' ;;
  *strenv*) printf '%s\n' '{"name":"DIRECT"}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fake_bin/python3" "$fake_bin/python" "$fake_bin/curl" "$runtime/clash/bin/yq"

output="$(PATH="$fake_bin:$PATH" CURL_LOG="$curl_log" CLASH_CODEX_AUTODL_REPO_ROOT="$runtime" \
  bash -c ". '$runtime/lib/codex_common.sh'; CODEX_MIHOMO_CONTROLLER_URL=http://127.0.0.1:6006; CODEX_PROXY_GROUP=CodexProxy; current_proxy_node")"
[ "$output" = 'Node A' ]

switch_output="$(printf '1\n' | PATH="$fake_bin:$PATH" CURL_LOG="$curl_log" \
  CLASH_CODEX_AUTODL_REPO_ROOT="$runtime" CODEX_AUTODL_CONFIG_DIR="$tmp_dir/config" \
  bash -c ". '$runtime/lib/codex_common.sh'; CODEX_MIHOMO_CONTROLLER_URL=http://127.0.0.1:6006; CODEX_PROXY_GROUP=CodexProxy; proxy-switch")"
grep -q '已选择: DIRECT' <<< "$switch_output"
grep -q -- '-X PUT' "$curl_log"
