# clash-codex-autodl

面向 AutoDL、SeetaCloud 和普通 Linux 云主机的 Mihomo/Clash 与 Codex CLI 安装脚本。Clash 和 Codex 完全独立安装，日常使用只暴露 `proxy-*`、`codex-*` 和 `codex` 命令。

## 环境要求

- Linux、Bash、`curl`、`tar`、`gzip`、`awk`、`sed`、`ps`
- 推荐安装 Python 3，用于 JSON、TOML 和会话数据处理
- 支持 `systemd --user` 时使用用户级开机服务；AutoDL 等不支持的环境会在首个交互终端中启动 Mihomo

## Clash 安装

```bash
git clone https://github.com/KiRinXC/clash-codex-autodl.git
cd clash-codex-autodl
bash install-clash.sh
```

安装时输入订阅 URL。脚本会下载订阅、Mihomo、GeoIP 数据和必要工具，并默认永久开启代理。

重新打开终端后，当前终端会自动获得代理环境变量，并显示代理、Codex 认证和会话同步摘要。API 认证只显示 URL，不显示 Key；ChatGPT 认证只显示 `ChatGPT`。非交互 shell、scp 和后台任务不会输出摘要。

```text
[proxy] 已开启 | 节点: Node A
[codex] API | https://example.com/v1
[sync] 已同步 | 原生会话 12 个
```

### 代理命令

| 命令 | 行为 |
| --- | --- |
| `proxy-on` | 永久开启代理，启动并启用 Mihomo |
| `proxy-off` | 永久关闭代理，停止 Mihomo，并关闭后续终端的自动代理 |
| `proxy-switch` | 交互选择代理节点 |
| `proxy-status` | 查看持久开关、当前终端环境、Mihomo 和节点状态 |

`proxy-on` 和 `proxy-off` 在已经加载 shell hook 的终端中也会立即修改当前终端环境。作为外部脚本直接执行时，子进程无法修改父 shell；这种情况下重新打开终端即可应用环境变化。

重新运行 `bash install-clash.sh` 可以修改订阅 URL 或重新安装 Clash，不影响 Codex 数据。合法 URL 会在下载开始前保存，因此即使下载失败，下次运行仍会显示上次输入的地址。新订阅会先在临时文件中完成转换和检查，Mihomo 成功启动后才替换现有配置；下载、转换或启动失败时会恢复原运行配置和代理进程。

### 与 clash-for-AutoDL 的流程对照

本项目逐项对照了 [`VocabVictor/clash-for-AutoDL`](https://github.com/VocabVictor/clash-for-AutoDL) 的 AutoDL 安装流程，但保留当前已经验证过的安全边界：

| 环节 | clash-for-AutoDL | 本项目 |
| --- | --- | --- |
| 订阅输入 | 先编辑仓库中的 `.env` | 安装时输入，保存到项目用户配置目录 |
| 下载与转换 | curl/wget、多 GitHub 镜像、自定义链接转换器 | curl、多镜像、yq 注入；非 YAML 订阅调用独立转换器 |
| 运行方式 | 仓库目录内 `nohup`，把函数追加到 `.bashrc` | 数据目录内运行；优先 `systemd --user`，AutoDL 无 user systemd 时由交互 shell 恢复 |
| 启动判断 | 进程启动后测试公网请求 | 分开判断进程、本地端口、Controller；公网出口只作为独立诊断，不阻塞基础 readiness |
| 代理开关 | 当前 shell 的 `proxy_on/proxy_off` | `proxy-on/proxy-off` 同时维护永久状态、进程和当前 shell 环境 |
| 节点控制 | 主要通过 Dashboard | `proxy-switch/status` 使用 loopback Controller，节点选择由 Mihomo 持久化 |
| 重装失败 | 直接操作仓库内配置 | staged 下载/转换/节点检查、原子替换和启动失败回滚 |

参考仓库需要用户自行安装 `lsof`；本项目会依次使用 `ss`、`lsof` 或本地 TCP 连接检查，不把 `lsof` 设为硬依赖。GitHub 文件下载会对每个镜像使用独立临时文件，切换镜像时不会续传上一个镜像的半截文件；直连默认最多等待 180 秒，可用 `GITHUB_DIRECT_MAX_TIME` 覆盖。若默认端口确实已被占用，本项目不会杀死未知进程，而是自动选择备用端口。生成配置时会删除订阅原有的 `port`、`socks-port`、`redir-port` 和 `tproxy-port`，只设置项目使用的 `mixed-port`，避免 Mihomo 自身的多个 listener 争用同一端口。

## Codex 安装

```bash
bash install-codex.sh
```

如果 `PATH` 中已经存在可用的 Codex CLI，脚本会直接复用它，不会覆盖该程序，也不会在卸载项目组件时删除它；只有找不到 Codex 时才会尝试安装。无论 Codex CLI 是预先安装还是由本项目安装，都需要执行一次上面的脚本，以部署本项目自己的 `codex-*` 管理命令和 shell hook。这些命令不是 Codex CLI 自带的。

脚本先用 `codex --version` 确认可执行文件可用，再按以下顺序选择初始配置：

1. 继续使用项目数据目录中已经保存的活动配置；
2. 如果项目已经保存了可用的 API 单文件配置，用它恢复项目 API 档案；
3. 否则识别原生 `CODEX_HOME` 中的 API 或 ChatGPT 登录；
4. 如果原凭据是文件型 `auth.json`，将当前认证保存为项目目录中的快照，并继续直接使用原生 `CODEX_HOME`；
5. 只有没有任何可复用配置时，才询问 API 地址和 API Key。

因此，电脑或服务器上已经完成文件型登录的 Codex 不需要重新安装，也不需要再次输入同一种认证。脚本只建立当前认证对应的一套项目快照；另一套认证等首次执行 `codex-switch` 时再配置。识别和保存不发起模型请求。

如果 Codex 把凭据保存在系统 keyring，脚本仍能识别认证方式，但无法把它保存为切换时可完整覆盖的 `auth.json`。安装会要求使用同一种原生登录重新生成文件型凭据：ChatGPT 使用 `codex login --device-auth`，API 重新输入 Key。项目不会尝试读取或复制 keyring 项。

当前 Codex 还可能报告 access token、personal access token、workload identity 或 Amazon Bedrock 认证。本项目的切换模型明确只有 API Key 与 ChatGPT 两套，因此只识别并提示这些额外方式，不把它们错误归类或复制；原认证仍保持不变。

API 默认使用自定义 Provider ID `OpenAI`，ChatGPT 默认使用内置 Provider ID `openai`；导入已有配置时保留原来的 `model_provider`，所以它也可能是其他名称。Provider ID 与认证方式是两个不同概念。

API Key 使用隐藏输入，右键粘贴后终端不会显示星号或任何字符，按 Enter 即可。脚本会清理常见的终端括号粘贴标记和 `CR` 字符；如果第一次粘贴没有生效，可以直接重试，提示信息不会写入 Key。

安装只保存配置，不会进行模型调用验证。API Key 通过 Codex CLI 的 `login --with-api-key` 写入运行凭据；只有手动运行 `codex-verify` 才会发起真实验证请求。

### Codex 命令

| 命令 | 行为 |
| --- | --- |
| `codex-verify` | 用当前配置执行一次临时真实调用，并保存验证结果和时间 |
| `codex-status` | 离线显示当前配置；API 显示 URL，ChatGPT 显示 `ChatGPT` |
| `codex-switch` | 自动切换到另一套认证；完整替换 `auth.json`、定向更新 `config.toml` |
| `codex-sync` | 保存当前认证快照，并把原生会话的 provider 对齐到当前配置 |
| `codex-config` | API 打开单文件配置；ChatGPT 执行原生设备码登录 |
| `codex ...` | 使用当前配置运行 Codex CLI |

首次切换到尚未配置的 ChatGPT 时，`codex-switch` 会在原生 `CODEX_HOME` 上运行 `codex login --device-auth`；首次切换到尚未配置的 API 时，才会询问 API 地址和 Key。之后两套认证之间直接切换。切换前必须关闭其他 Codex CLI/Codex App 进程。

### API 单文件配置

API 用户数据保存在：

```text
~/.config/clash-codex-autodl/api-profile.toml
```

这是需要查看和编辑的文本文件。`~/.local/bin/codex`、`which codex` 输出的其他 `codex` 路径通常是 ELF 可执行程序，直接 `cat` 显示乱码是正常现象，它不是配置文件。安装和运行 `codex-config` 时都会明确显示实际的文本配置路径。

示例结构：

```toml
api_key = "your-key"
cli_auth_credentials_store = "file"
forced_login_method = "api"
model_provider = "OpenAI"
model = "gpt-5.6-sol"
review_model = "gpt-5.4"
model_reasoning_effort = "xhigh"
model_context_window = 1000000
model_auto_compact_token_limit = 900000

[model_providers.OpenAI]
name = "OpenAI"
base_url = "https://example.com/v1"
wire_api = "responses"
requires_openai_auth = true

[sandbox_workspace_write]
network_access = true
```

上述默认项通过当前 Codex CLI 的严格配置检查。当前规则中，`wire_api` 只支持 `responses`；内置 provider id `openai`、`ollama` 和 `lmstudio` 是保留名称，不能用 `[model_providers.openai]` 等表覆盖。自定义 Provider 应使用其他、大小写完全一致的 ID。顶层 `disable_response_storage` 和字符串形式的 `network_access = "enabled"` 不在当前配置 schema 中，因此默认配置不再写入；联网权限使用 `sandbox_workspace_write.network_access = true`。`windows_wsl_setup_acknowledged` 仍是合法的 Windows 专用字段，但 Linux 默认配置不需要它。

该文件本身是合法 TOML。`codex-config` 按 `CODEX_CONFIG_EDITOR`、`VISUAL`、`EDITOR`、`nano`、`vim`、`vi` 的顺序选择编辑器。保存后，脚本让 Codex CLI 在原生 `CODEX_HOME` 中执行 `login --with-api-key`，完整生成 `auth.json`；`config.toml` 只定向更新认证、模型和当前 Provider 字段/表，其他用户配置保持不变。

如果旧的 `api-profile.toml` 为空、缺少 `api_key` 或 TOML 已损坏，重新运行安装脚本会先将它备份为 `api-profile.toml.invalid.<时间>.<进程号>`，再重新询问 API 地址和 Key。`model_provider` 可以省略，此时 Codex 使用内置 `openai`；官方 OpenAI API 也可以不写 `openai_base_url`。新配置成功前，已经可用的运行配置不会被覆盖。

`model_provider` 是配置 ID，不是认证方式。若使用自定义 `[model_providers.<id>]`，必须保证它与顶层 `model_provider = "<id>"` 完全一致。

### 原生 CODEX_HOME 与同步

Codex 始终使用原生 `~/.codex`（或用户显式设置的 `CODEX_HOME`）。项目不会创建第二套 `CODEX_HOME`，不会创建 `codex-shared`，不会搬运/合并会话，也不会把 `sessions`、附件或 SQLite 路径替换成软链接。

项目只在自己的数据目录保存两套认证快照：

```text
~/.local/share/clash-codex-autodl/codex-profiles/api/
~/.local/share/clash-codex-autodl/codex-profiles/chatgpt/
```

每套快照包含完整 `auth.json` 和完整的可切换 `config.toml` 配置（API Key 仍单独保存在 `api-profile.toml`，`sqlite_home` 这类本机共享路径不参与切换）。切换时，目标 `auth.json` 完整覆盖原生文件；目标 `config.toml` 作为配置层合并到当前原生配置，认证路由字段按目标配置清理/替换，目标声明的表和字段更新，当前配置中目标未声明的 MCP、审批、通知等内容保留。

为了让同一会话能在 API 与 ChatGPT 之间继续，切换和 `codex-sync` 会扫描原生 `sessions/` 与 `archived_sessions/` 下的 `rollout-*.jsonl`，把首条 `session_meta.payload.model_provider` 改成目标配置的 Provider；如果发现权威 `state_5.sqlite`，还会在事务中同步 `threads.model_provider`。其余会话记录、顺序、附件和目录结构保持不变；写入失败时回滚本轮已经修改的 rollout 和 SQLite。`codex-sync` 同时保存 Codex 使用过程中可能刷新的 token 和当前受管理配置。

## 用户数据与卸载

```bash
bash uninstall.sh clash
bash uninstall.sh codex
bash uninstall.sh data
```

- `clash`：停止并卸载 Mihomo、代理命令和服务，保留订阅 URL。
- `codex`：卸载本项目安全管理且文件指纹未发生变化的 Codex CLI 和包装命令，保留项目认证快照以及原生 Codex 数据；预先存在或后来被替换的 Codex CLI 不会删除。
- `data`：列出并永久删除订阅、Mihomo 运行配置和日志、项目保存的双认证快照及旧版本遗留数据，需要输入 `DELETE` 二次确认。原生 `~/.codex` 不会被删除。如果组件仍在安装状态，管理命令和 shell hook 会保留，代理会关闭；重新运行相应安装脚本即可配置。

自动化环境可以明确使用 `bash uninstall.sh data --yes`。卸载和删除项目数据始终不会删除原生 `~/.codex`；认证安装/切换只会按上述规则替换其中的 `auth.json` 并定向修改 `config.toml`，不会操作其他原生文件或目录。

重新安装时会复用已保留数据。旧版本的 API 档案会尽可能迁移到 `api-profile.toml`；迁移成功前不会删除旧数据。

## 数据布局

```text
~/.local/bin/                                      # 公开 proxy-* / codex-* 命令
~/.local/share/clash-codex-autodl/runtime/         # 可重装的运行文件和 Clash 组件
~/.local/share/clash-codex-autodl/codex-profiles/  # API、ChatGPT 认证快照
~/.config/clash-codex-autodl/                      # 订阅、API 单文件和当前配置指针
~/.codex/                                          # Codex 原生目录；项目只操作 auth.json/config.toml
```

含 Key、token 或订阅 URL 的文件权限设置为 `600`。不要把这些目录提交到 Git 或发送到公开日志。

## 开发验证

```bash
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
shellcheck command.sh install-clash.sh install-codex.sh uninstall.sh setup_mihomo.sh converter.sh lib/*.sh
for test_file in tests/*.sh; do bash "$test_file"; done

# 额外下载当前官方 Codex CLI，使用本地无效地址和测试 Key 验证真实安装/认证/严格配置解析/卸载
RUN_REAL_CODEX_E2E=true bash tests/real_codex_cli_e2e.sh
```
