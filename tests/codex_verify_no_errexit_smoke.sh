#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_state="$tmp_dir/state"
fake_bin="$tmp_dir/bin"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_state" "$fake_bin"

cat > "$tmp_state/config.sh" <<'EOF'
CODEX_DOMESTIC_BASE_URL='https://domestic.example.invalid/api'
CODEX_OVERSEAS_BASE_URL='https://overseas.example.invalid/api'
CODEX_ACTIVE_RELAY='domestic'
CODEX_PROXY_URL='http://127.0.0.1:17900'
CODEX_MIHOMO_CONTROLLER_URL='http://127.0.0.1:16900'
CODEX_PROXY_GROUP='CodexProxy'
CODEX_MODEL='gpt-5.4'
CODEX_REVIEW_MODEL='gpt-5.4'
EOF

cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
out_file=""
while [ "$#" -gt 0 ]; do
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
  printf '%s\n' 'NOT_READY' > "$out_file"
fi
exit 42
SH
chmod +x "$fake_bin/codex"

output="$(
  PATH="$fake_bin:$PATH" \
  CODEX_AUTODL_CONFIG_DIR="$tmp_state" \
  CODEX_SMOKE_TIMEOUT=1 \
  bash -lc "
    set +e
    source '$repo_root/lib/codex_common.sh'
    codex-verify
    verify_status=\$?
    printf 'verify_status=%s\n' \"\$verify_status\"
    case \"\$-\" in
      *e*) printf 'errexit=on\n' ;;
      *) printf 'errexit=off\n' ;;
    esac
    false
    printf 'after-false\n'
  " 2>&1
)"

grep -q 'verify_status=1' <<<"$output"
grep -q 'errexit=off' <<<"$output"
grep -q 'after-false' <<<"$output"
