#!/usr/bin/env bash

# Authentication stays profile-specific; resumable conversation state is shared.

CODEX_SESSION_SYNC_LAYOUT_VERSION="1"
CODEX_SESSION_IMPORT_COUNT=0
CODEX_SESSION_CONFLICT_COUNT=0

codex_shared_state_dir() {
  printf '%s/codex-shared\n' "$(project_data_dir)"
}

codex_shared_sqlite_dir() {
  printf '%s/sqlite\n' "$(codex_shared_state_dir)"
}

codex_session_sync_marker() {
  printf '%s/.layout-version\n' "$(codex_shared_state_dir)"
}

codex_session_sync_is_initialized() {
  local marker value=""
  marker="$(codex_session_sync_marker)"
  if [ -f "$marker" ]; then
    IFS= read -r value < "$marker" || true
  fi
  [ "$value" = "$CODEX_SESSION_SYNC_LAYOUT_VERSION" ]
}

codex_process_is_running() {
  ps -eo pid=,comm= 2>/dev/null | awk -v self="$$" '
    $1 != self && $2 ~ /^(codex|codex-cli)$/ { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

codex_copy_file_atomic() {
  local source="$1"
  local target="$2"
  local tmp

  mkdir -p "$(dirname "$target")"
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  if cp -p "$source" "$tmp" && mv "$tmp" "$target"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

codex_files_have_prefix_relationship() {
  local shorter="$1"
  local longer="$2"
  local shorter_size

  shorter_size="$(wc -c < "$shorter" | tr -d '[:space:]')"
  case "$shorter_size" in
    '' | *[!0-9]*) return 1 ;;
  esac
  cmp -s -n "$shorter_size" "$shorter" "$longer"
}

codex_import_tree() {
  local source_dir="$1"
  local target_dir="$2"
  local source_label="$3"
  local conflict_root="$4"
  local source_file relative target_file source_size target_size conflict_file

  [ -d "$source_dir" ] || return 0
  if [ -L "$source_dir" ] && [ "$(readlink "$source_dir" 2>/dev/null || true)" = "$target_dir" ]; then
    return 0
  fi

  while IFS= read -r -d '' source_file; do
    relative="${source_file#"$source_dir"/}"
    target_file="$target_dir/$relative"
    if [ ! -e "$target_file" ]; then
      codex_copy_file_atomic "$source_file" "$target_file"
      CODEX_SESSION_IMPORT_COUNT=$((CODEX_SESSION_IMPORT_COUNT + 1))
      continue
    fi
    if cmp -s "$source_file" "$target_file"; then
      continue
    fi

    source_size="$(wc -c < "$source_file" | tr -d '[:space:]')"
    target_size="$(wc -c < "$target_file" | tr -d '[:space:]')"
    if [ "$source_size" -gt "$target_size" ] && \
      codex_files_have_prefix_relationship "$target_file" "$source_file"; then
      codex_copy_file_atomic "$source_file" "$target_file"
      CODEX_SESSION_IMPORT_COUNT=$((CODEX_SESSION_IMPORT_COUNT + 1))
      continue
    fi
    if [ "$target_size" -gt "$source_size" ] && \
      codex_files_have_prefix_relationship "$source_file" "$target_file"; then
      continue
    fi

    conflict_file="$conflict_root/$source_label/$relative"
    codex_copy_file_atomic "$source_file" "$conflict_file"
    CODEX_SESSION_CONFLICT_COUNT=$((CODEX_SESSION_CONFLICT_COUNT + 1))
  done < <(find "$source_dir" -type f -print0 2>/dev/null)
}

codex_merge_jsonl_file() {
  local source="$1"
  local target="$2"
  local python_bin tmp

  [ -f "$source" ] || return 0
  mkdir -p "$(dirname "$target")"
  tmp="$(mktemp "${target}.tmp.XXXXXX")"

  if python_bin="$(python_command 2>/dev/null)"; then
    "$python_bin" - "$target" "$source" "$tmp" <<'PY'
import os
import sys

target, source, output = sys.argv[1:]
seen = set()
with open(output, "w", encoding="utf-8", newline="") as merged:
    for path in (target, source):
        if not os.path.isfile(path):
            continue
        with open(path, "r", encoding="utf-8", errors="surrogateescape", newline="") as current:
            for line in current:
                if line in seen:
                    continue
                seen.add(line)
                merged.write(line)
PY
  else
    awk '!seen[$0]++' "$target" "$source" 2>/dev/null > "$tmp" || \
      awk '!seen[$0]++' "$source" > "$tmp"
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$target"
}

codex_normalize_shared_rollout_providers() {
  local target_provider="${1:-openai}"
  local shared python_bin count escaped_provider
  shared="$(codex_shared_state_dir)"

  if python_bin="$(python_command 2>/dev/null)"; then
    count="$(CODEX_TARGET_PROVIDER="$target_provider" "$python_bin" - "$shared/sessions" "$shared/archived_sessions" <<'PY'
import json
import os
import shutil
import sys
import tempfile

changed = 0
target_provider = os.environ["CODEX_TARGET_PROVIDER"]
for root in sys.argv[1:]:
    if not os.path.isdir(root):
        continue
    for directory, _, files in os.walk(root):
        for name in files:
            if not (name.startswith("rollout-") and name.endswith(".jsonl")):
                continue
            path = os.path.join(directory, name)
            with open(path, "rb") as source:
                first = source.readline()
                try:
                    record = json.loads(first.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                payload = record.get("payload")
                if record.get("type") != "session_meta" or not isinstance(payload, dict):
                    continue
                if payload.get("model_provider") == target_provider:
                    continue
                payload["model_provider"] = target_provider
                stat = os.stat(path)
                fd, temp_path = tempfile.mkstemp(prefix=f".{name}.", dir=directory)
                try:
                    with os.fdopen(fd, "wb") as target:
                        target.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
                        target.write(b"\n")
                        shutil.copyfileobj(source, target)
                        target.flush()
                        os.fsync(target.fileno())
                    os.chmod(temp_path, stat.st_mode)
                    os.replace(temp_path, path)
                    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
                    changed += 1
                finally:
                    if os.path.exists(temp_path):
                        os.unlink(temp_path)
print(changed)
PY
)"
  else
    count=0
    while IFS= read -r -d '' rollout; do
      escaped_provider="$(printf '%s' "$target_provider" | sed 's/[&|]/\\&/g')"
      if sed -i "1 s|\"model_provider\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"model_provider\":\"$escaped_provider\"|" "$rollout"; then
        count=$((count + 1))
      fi
    done < <(find "$shared/sessions" "$shared/archived_sessions" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null)
  fi

  if [ "${count:-0}" -gt 0 ]; then
    log_ok "已将 $count 个会话的 Provider 元数据对齐为 $target_provider"
  fi
}

codex_link_shared_path() {
  local profile_home="$1"
  local name="$2"
  local target="$3"
  local backup_root="$4"
  local profile_label="$5"
  local path backup

  path="$profile_home/$name"
  if [ -L "$path" ] && [ "$(readlink "$path" 2>/dev/null || true)" = "$target" ]; then
    return 0
  fi

  if [ -e "$path" ] || [ -L "$path" ]; then
    backup="$backup_root/$profile_label/$name"
    mkdir -p "$(dirname "$backup")"
    if [ -e "$backup" ] || [ -L "$backup" ]; then
      backup="${backup}.$(date +%s).$$"
    fi
    mv "$path" "$backup"
  fi
  ln -s "$target" "$path"
}

codex_link_profile_shared_sessions() {
  local profile_home="$1"
  local profile_label="${2:-$(basename "$profile_home")}"
  local backup_root="${3:-$(codex_shared_state_dir)/migration-backups/manual}"
  local shared

  shared="$(codex_shared_state_dir)"
  mkdir -p "$profile_home" "$shared/sessions" "$shared/archived_sessions" \
    "$shared/attachments" "$shared/thread-writer-locks" "$shared/sqlite"
  touch "$shared/session_index.jsonl"

  codex_link_shared_path "$profile_home" sessions "$shared/sessions" "$backup_root" "$profile_label"
  codex_link_shared_path "$profile_home" archived_sessions "$shared/archived_sessions" "$backup_root" "$profile_label"
  codex_link_shared_path "$profile_home" attachments "$shared/attachments" "$backup_root" "$profile_label"
  codex_link_shared_path "$profile_home" thread-writer-locks "$shared/thread-writer-locks" "$backup_root" "$profile_label"
  codex_link_shared_path "$profile_home" session_index.jsonl "$shared/session_index.jsonl" "$backup_root" "$profile_label"
}

codex_repair_profile_session_links() {
  local backup_root="$1"
  local profile home

  for profile in api chatgpt; do
    home="$(codex_profile_home "$profile")"
    [ -d "$home" ] || continue
    codex_link_profile_shared_sessions "$home" "$profile" "$backup_root"
    if declare -F rewrite_codex_profile_config_for_shared_sessions >/dev/null 2>&1; then
      rewrite_codex_profile_config_for_shared_sessions "$profile" "$home"
    fi
  done
}

codex_profile_session_links_need_repair() {
  local home="$1"
  local shared
  shared="$(codex_shared_state_dir)"

  [ -L "$home/sessions" ] && \
    [ "$(readlink "$home/sessions" 2>/dev/null || true)" = "$shared/sessions" ] && \
    [ -L "$home/session_index.jsonl" ] && \
    [ "$(readlink "$home/session_index.jsonl" 2>/dev/null || true)" = "$shared/session_index.jsonl" ]
}

codex_import_session_source() {
  local source_label="$1"
  local source_home="$2"
  local conflict_root="$3"
  local shared name

  [ -d "$source_home" ] || return 0
  shared="$(codex_shared_state_dir)"
  for name in sessions archived_sessions attachments; do
    codex_import_tree "$source_home/$name" "$shared/$name" "$source_label" "$conflict_root"
  done
  if ! { [ -L "$source_home/session_index.jsonl" ] && \
    [ "$(readlink "$source_home/session_index.jsonl" 2>/dev/null || true)" = "$shared/session_index.jsonl" ]; }; then
    codex_merge_jsonl_file "$source_home/session_index.jsonl" "$shared/session_index.jsonl"
  fi
}

codex_log_session_import_result() {
  local conflict_root="$1"
  if [ "$CODEX_SESSION_IMPORT_COUNT" -gt 0 ]; then
    log_info "已导入会话相关文件: $CODEX_SESSION_IMPORT_COUNT"
  fi
  if [ "$CODEX_SESSION_CONFLICT_COUNT" -gt 0 ]; then
    log_warn "发现 $CODEX_SESSION_CONFLICT_COUNT 个分叉文件，已保留到: $conflict_root"
  fi
}

codex_initialize_session_sync() {
  local force="${1:-false}"
  local target_provider="${2:-openai}"
  local shared marker timestamp backup_root conflict_root source_label source_home profile home

  shared="$(codex_shared_state_dir)"
  marker="$(codex_session_sync_marker)"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  backup_root="$shared/migration-backups/$timestamp"
  conflict_root="$shared/import-conflicts/$timestamp"

  if codex_session_sync_is_initialized; then
    CODEX_SESSION_IMPORT_COUNT=0
    CODEX_SESSION_CONFLICT_COUNT=0
    if [ "$force" = "true" ]; then
      codex_import_session_source native "$HOME/.codex" "$conflict_root"
    fi
    for profile in api chatgpt; do
      home="$(codex_profile_home "$profile")"
      [ -d "$home" ] || continue
      if ! codex_profile_session_links_need_repair "$home"; then
        codex_import_session_source "$profile" "$home" "$conflict_root"
      fi
    done
    codex_repair_profile_session_links "$backup_root"
    if [ "$force" = "true" ]; then
      codex_normalize_shared_rollout_providers "$target_provider"
    fi
    codex_log_session_import_result "$conflict_root"
    return 0
  fi

  if codex_process_is_running; then
    log_error "首次会话同步前请先关闭其他 Codex CLI / Codex App 进程"
    return 1
  fi

  mkdir -p "$shared/sessions" "$shared/archived_sessions" "$shared/attachments" \
    "$shared/thread-writer-locks" "$shared/sqlite"
  CODEX_SESSION_IMPORT_COUNT=0
  CODEX_SESSION_CONFLICT_COUNT=0

  for source_label in native api chatgpt; do
    case "$source_label" in
      native) source_home="$HOME/.codex" ;;
      *) source_home="$(codex_profile_home "$source_label")" ;;
    esac
    codex_import_session_source "$source_label" "$source_home" "$conflict_root"
  done

  codex_normalize_shared_rollout_providers "$target_provider"
  codex_repair_profile_session_links "$backup_root"

  printf '%s\n' "$CODEX_SESSION_SYNC_LAYOUT_VERSION" > "$marker"
  chmod 600 "$marker" 2>/dev/null || true
  log_ok "会话共享存储已就绪: $shared"
  codex_log_session_import_result "$conflict_root"
}

codex_session_rollout_count() {
  local shared
  shared="$(codex_shared_state_dir)"
  find "$shared/sessions" "$shared/archived_sessions" -type f -name 'rollout-*.jsonl' \
    2>/dev/null | wc -l | tr -d '[:space:]'
}

codex_sessions_status() {
  local shared profile home state
  shared="$(codex_shared_state_dir)"
  if codex_session_sync_is_initialized; then
    log_ok "会话同步: 已启用"
  else
    log_warn "会话同步: 待初始化"
  fi
  log_info "共享会话目录: $shared"
  log_info "Rollout 数量: $(codex_session_rollout_count)"
  for profile in api chatgpt; do
    home="$(codex_profile_home "$profile")"
    state="未配置"
    if [ -L "$home/sessions" ] && [ "$(readlink "$home/sessions" 2>/dev/null || true)" = "$shared/sessions" ]; then
      state="已共享"
    elif [ -d "$home" ]; then
      state="待同步"
    fi
    log_info "$profile 会话: $state"
  done
}
