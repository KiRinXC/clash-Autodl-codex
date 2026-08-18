#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${CLASH_CODEX_AUTODL_DATA_DIR:-$HOME/.local/share/clash-codex-autodl}"
RUNTIME_DIR="$DATA_DIR/runtime"
BIN_DIR="${CLASH_CODEX_AUTODL_USER_BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$RUNTIME_DIR/lib" "$RUNTIME_DIR/tests" "$BIN_DIR"

cp "$SCRIPT_DIR/clash-codex" "$RUNTIME_DIR/clash-codex"
cp "$SCRIPT_DIR/start.sh" "$RUNTIME_DIR/start.sh"
cp "$SCRIPT_DIR/setup_mihomo.sh" "$RUNTIME_DIR/setup_mihomo.sh"
cp "$SCRIPT_DIR/bootstrap_codex.sh" "$RUNTIME_DIR/bootstrap_codex.sh"
cp "$SCRIPT_DIR/verify_codex.sh" "$RUNTIME_DIR/verify_codex.sh"
cp "$SCRIPT_DIR/uninstall_codex_bootstrap.sh" "$RUNTIME_DIR/uninstall_codex_bootstrap.sh"
cp "$SCRIPT_DIR/converter.sh" "$RUNTIME_DIR/converter.sh"
cp "$SCRIPT_DIR/lib/codex_common.sh" "$RUNTIME_DIR/lib/codex_common.sh"
cp "$SCRIPT_DIR/lib/codex_profiles.sh" "$RUNTIME_DIR/lib/codex_profiles.sh"
cp "$SCRIPT_DIR/lib/codex_sessions.sh" "$RUNTIME_DIR/lib/codex_sessions.sh"

chmod +x "$RUNTIME_DIR/clash-codex" "$RUNTIME_DIR"/*.sh

cat > "$BIN_DIR/clash-codex" <<EOF
#!/usr/bin/env bash
export CLASH_CODEX_AUTODL_RUNTIME_DIR="$RUNTIME_DIR"
exec "$RUNTIME_DIR/clash-codex" "\$@"
EOF

cat > "$BIN_DIR/codex-autodl" <<EOF
#!/usr/bin/env bash
exec "$BIN_DIR/clash-codex" run "\$@"
EOF

chmod +x "$BIN_DIR/clash-codex" "$BIN_DIR/codex-autodl"

touch "$HOME/.bashrc"
sed -i '/# clash-codex-autodl-path begin/,/# clash-codex-autodl-path end/d' "$HOME/.bashrc"
{
  printf '%s\n' '# clash-codex-autodl-path begin'
  printf "export PATH=\"%s:\$PATH\"\n" "$BIN_DIR"
  printf '%s\n' '# clash-codex-autodl-path end'
} >> "$HOME/.bashrc"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    printf '\n[WARN] 当前终端尚未刷新 PATH；请重新打开终端。\n'
    ;;
esac

printf '[OK] 全局命令已安装: %s/clash-codex\n' "$BIN_DIR"
printf '[INFO] 下一步运行: clash-codex setup\n'
