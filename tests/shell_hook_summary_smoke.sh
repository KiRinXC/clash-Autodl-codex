#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_state="$tmp_home/.config/clash-codex-autodl"
calls="$tmp_dir/calls"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_home/.local/bin" "$tmp_state"
cat > "$tmp_state/config.sh" <<'EOF'
AUTO_PROXY_ON_SHELL_START='false'
EOF

cat > "$tmp_home/.local/bin/clash-codex" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$calls'
if [ "\${1:-}" = proxy ] && [ "\${2:-}" = on ]; then
  printf '%s\n' 'export http_proxy=http://127.0.0.1:17900'
fi
SH
chmod +x "$tmp_home/.local/bin/clash-codex"

HOME="$tmp_home" CODEX_AUTODL_CONFIG_DIR="$tmp_state" bash -lc "
  set -euo pipefail
  source '$repo_root/lib/codex_common.sh'
  install_shell_hook >/dev/null
"

HOME="$tmp_home" bash -lc '
  set -euo pipefail
  source "$HOME/.config/clash-codex-autodl/proxy-shell-init.sh"
  source "$HOME/.config/clash-codex-autodl/codex-shell-init.sh"
  codex --version
  codex-status
  proxy-status
' >/dev/null

grep -qx 'run --version' "$calls"
grep -qx 'status' "$calls"
grep -qx 'proxy status' "$calls"
! grep -qx 'verify' "$calls"
