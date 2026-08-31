#!/usr/bin/env bash

install_data_dir() {
  printf '%s\n' "${CLASH_CODEX_AUTODL_DATA_DIR:-$HOME/.local/share/clash-codex-autodl}"
}

install_runtime_dir() {
  printf '%s/runtime\n' "$(install_data_dir)"
}

install_user_bin_dir() {
  printf '%s\n' "${CLASH_CODEX_AUTODL_USER_BIN_DIR:-$HOME/.local/bin}"
}

deploy_runtime() {
  local source_dir="$1" runtime bin_dir
  runtime="$(install_runtime_dir)"
  bin_dir="$(install_user_bin_dir)"
  mkdir -p "$runtime/lib" "$bin_dir"
  cp "$source_dir/command.sh" "$runtime/command.sh"
  cp "$source_dir/setup_mihomo.sh" "$runtime/setup_mihomo.sh"
  cp "$source_dir/converter.sh" "$runtime/converter.sh"
  cp "$source_dir/uninstall.sh" "$runtime/uninstall.sh"
  cp "$source_dir/lib/codex_common.sh" "$runtime/lib/codex_common.sh"
  cp "$source_dir/lib/codex_profiles.sh" "$runtime/lib/codex_profiles.sh"
  cp "$source_dir/lib/codex_sessions.sh" "$runtime/lib/codex_sessions.sh"
  chmod +x "$runtime/command.sh" "$runtime/setup_mihomo.sh" "$runtime/converter.sh" "$runtime/uninstall.sh"
  rm -f "$bin_dir/clash-codex" "$bin_dir/codex-autodl"
}

migrate_legacy_clash_runtime() {
  local runtime clash name
  runtime="$(install_runtime_dir)"
  clash="$runtime/clash"
  mkdir -p "$clash"
  for name in bin conf logs; do
    if [ -e "$runtime/$name" ] && [ ! -e "$clash/$name" ]; then
      mv "$runtime/$name" "$clash/$name"
    fi
  done
  if [ -e "$runtime/mihomo.pid" ] && [ ! -e "$clash/mihomo.pid" ]; then
    mv "$runtime/mihomo.pid" "$clash/mihomo.pid"
  fi
}

legacy_clash_is_present() {
  local runtime
  runtime="$(install_runtime_dir)"
  [ -s "$runtime/clash/conf/config.yaml" ] && \
    find "$runtime/clash/bin" -maxdepth 1 -type f -name 'mihomo*' -perm -u+x -print -quit 2>/dev/null | grep -q .
}

saved_codex_is_present() {
  local data
  data="$(install_data_dir)"
  { [ -s "$data/codex-profiles/api/config.toml" ] && [ -s "$data/codex-profiles/api/auth.json" ]; } ||
    { [ -s "$data/codex-profiles/chatgpt/config.toml" ] && [ -s "$data/codex-profiles/chatgpt/auth.json" ]; } ||
    { [ -s "$data/codex-homes/api/config.toml" ] && [ -s "$data/codex-homes/api/auth.json" ]; } ||
    { [ -s "$data/codex-homes/chatgpt/config.toml" ] && [ -s "$data/codex-homes/chatgpt/auth.json" ]; }
}

write_public_wrapper() {
  local name="$1" route="$2" action="$3" bin_dir runtime wrapper
  bin_dir="$(install_user_bin_dir)"
  runtime="$(install_runtime_dir)"
  wrapper="$bin_dir/$name"
  mkdir -p "$bin_dir"
  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
exec "$runtime/command.sh" "$route" "$action" "\$@"
EOF
  chmod +x "$wrapper"
}

install_proxy_wrappers() {
  write_public_wrapper proxy-on proxy enable
  write_public_wrapper proxy-off proxy disable
  write_public_wrapper proxy-switch proxy switch
  write_public_wrapper proxy-status proxy status
  rm -f "$(install_user_bin_dir)/proxy-pick"
}

install_codex_wrappers() {
  write_public_wrapper codex-verify codex verify
  write_public_wrapper codex-status codex status
  write_public_wrapper codex-switch codex switch
  write_public_wrapper codex-sync codex sync
  write_public_wrapper codex-config codex config
}

install_path_block() {
  local bin_dir
  bin_dir="$(install_user_bin_dir)"
  touch "$HOME/.bashrc"
  sed -i '/# clash-codex-autodl-path begin/,/# clash-codex-autodl-path end/d' "$HOME/.bashrc"
  {
    printf '%s\n' '# clash-codex-autodl-path begin'
    # shellcheck disable=SC2016
    printf 'export PATH="%s:$PATH"\n' "$bin_dir"
    printf '%s\n' '# clash-codex-autodl-path end'
  } >> "$HOME/.bashrc"
}

mark_component_installed() {
  mkdir -p "$(install_runtime_dir)"
  : > "$(install_runtime_dir)/.$1-installed"
}
