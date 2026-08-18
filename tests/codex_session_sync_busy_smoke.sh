#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_data="$tmp_dir/data"
fake_bin="$tmp_dir/fake-bin"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_home/.codex/sessions" "$fake_bin"
printf '%s\n' '{"type":"session_meta","payload":{"id":"busy","model_provider":"openai"}}' \
  > "$tmp_home/.codex/sessions/rollout-busy.jsonl"

cat > "$fake_bin/ps" <<'SH'
#!/usr/bin/env bash
printf '123 codex\n'
SH
chmod +x "$fake_bin/ps"

if HOME="$tmp_home" PATH="$fake_bin:$PATH" \
  CLASH_CODEX_AUTODL_DATA_DIR="$tmp_data" \
  bash "$repo_root/clash-codex" sessions sync >/dev/null 2>&1; then
  printf 'session migration should fail while Codex is running\n' >&2
  exit 1
fi

[ ! -e "$tmp_data/codex-shared/.layout-version" ]
[ -f "$tmp_home/.codex/sessions/rollout-busy.jsonl" ]
