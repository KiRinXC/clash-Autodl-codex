#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_home="$(mktemp -d)"
tmp_state="$(mktemp -d)"
tmp_repo="$(mktemp -d)"
fake_bin="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp_home" "$tmp_state" "$tmp_repo" "$fake_bin"
}
trap cleanup EXIT

cat > "$fake_bin/ss" <<'SH'
#!/usr/bin/env bash
printf 'LISTEN 0 128 127.0.0.1:17900 0.0.0.0:*\n'
SH
chmod +x "$fake_bin/ss"

output="$(
  HOME="$tmp_home" \
  CODEX_AUTODL_CONFIG_DIR="$tmp_state" \
  CLASH_CODEX_AUTODL_REPO_ROOT="$tmp_repo" \
  PATH="$fake_bin:$PATH" \
  bash -c "
    set -euo pipefail
    source '$repo_root/lib/codex_common.sh'
    CODEX_PROXY_URL='http://127.0.0.1:17900'
    save_project_config

    set +e
    proxy-on
    status=\$?
    set -e

    printf 'status=%s\n' \"\$status\"
    printf 'http_proxy=%s\n' \"\${http_proxy:-}\"
  " 2>&1
)"

grep -q 'status=1' <<<"$output"
grep -q 'http_proxy=$' <<<"$output"
grep -q 'Mihomo' <<<"$output"
