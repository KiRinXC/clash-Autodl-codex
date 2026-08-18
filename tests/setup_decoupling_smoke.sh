#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_config="$tmp_dir/config"
tmp_data="$tmp_dir/data"
runtime="$tmp_dir/runtime"
fake_bin="$tmp_dir/fake-bin"
clash_called="$tmp_dir/clash-called"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_home" "$tmp_config" "$tmp_data" "$runtime/lib" "$fake_bin"
cp "$repo_root/clash-codex" "$runtime/clash-codex"
cp "$repo_root/lib/codex_common.sh" "$runtime/lib/codex_common.sh"
cp "$repo_root/lib/codex_profiles.sh" "$runtime/lib/codex_profiles.sh"
cp "$repo_root/lib/codex_sessions.sh" "$runtime/lib/codex_sessions.sh"

cat > "$runtime/setup_mihomo.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
[ -f "\${1:?}" ]
touch '$clash_called'
SH
chmod +x "$runtime/setup_mihomo.sh"

cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'codex-cli test\n'
fi
SH
chmod +x "$fake_bin/codex"

run_cli() {
  HOME="$tmp_home" \
  PATH="$fake_bin:$PATH" \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$tmp_data" \
  bash "$runtime/clash-codex" "$@"
}

run_cli setup codex >/dev/null
[ ! -e "$clash_called" ]
[ -f "$tmp_config/codex-shell-init.sh" ]
[ ! -e "$tmp_config/proxy-shell-init.sh" ]
[ ! -d "$tmp_data/codex-homes" ]

printf 'https://subscription.example.invalid/clash.yaml\n' | run_cli setup clash >/dev/null
[ -e "$clash_called" ]
[ -f "$tmp_config/proxy-shell-init.sh" ]
[ ! -d "$tmp_data/codex-homes" ]
