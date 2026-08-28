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
[sync] 已同步 | 12 个会话
```

### 代理命令

| 命令 | 行为 |
| --- | --- |
| `proxy-on` | 永久开启代理，启动并启用 Mihomo |
| `proxy-off` | 永久关闭代理，停止 Mihomo，并关闭后续终端的自动代理 |
| `proxy-switch` | 交互选择代理节点 |
| `proxy-status` | 查看持久开关、当前终端环境、Mihomo 和节点状态 |

`proxy-on` 和 `proxy-off` 在已经加载 shell hook 的终端中也会立即修改当前终端环境。作为外部脚本直接执行时，子进程无法修改父 shell；这种情况下重新打开终端即可应用环境变化。

重新运行 `bash install-clash.sh` 可以修改订阅 URL 或重新安装 Clash，不影响 Codex 数据。

## Codex 安装

```bash
bash install-codex.sh
```

如果 `PATH` 中已经存在可用的 Codex CLI，脚本会直接复用它，不会覆盖该程序，也不会在卸载项目组件时删除它；只有找不到 Codex 时才会尝试安装。无论 Codex CLI 是预先安装还是由本项目安装，都需要执行一次上面的脚本，以部署本项目自己的 `codex-*` 管理命令、shell hook 和双认证配置。这些命令不是 Codex CLI 自带的。

管理命令会先安装，再等待输入 API 地址和 API Key。因此配置输入意外中断后，重新打开终端仍可使用 `codex-status` 查看状态，并可重新运行 `bash install-codex.sh` 继续配置。默认配置使用 `model_provider = "openai"`。

安装只保存配置，不会进行模型调用验证。API Key 通过 Codex CLI 的 `login --with-api-key` 写入运行凭据；只有手动运行 `codex-verify` 才会发起真实验证请求。

### Codex 命令

| 命令 | 行为 |
| --- | --- |
| `codex-verify` | 用当前配置执行一次临时真实调用，并保存验证结果和时间 |
| `codex-status` | 离线显示当前配置；API 显示 URL，ChatGPT 显示 `ChatGPT` |
| `codex-switch` | 自动切换到另一套配置并同步会话，不接受目标参数 |
| `codex-sync` | 手动同步当前配置的会话，不切换配置 |
| `codex-config` | API 打开单文件配置；ChatGPT 重新执行设备登录 |
| `codex ...` | 使用当前配置运行 Codex CLI |

首次从 API 切换到 ChatGPT 时，`codex-switch` 会运行设备登录。之后两套配置之间直接切换。

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
model_provider = "openai"
openai_base_url = "https://example.com/v1"
```

该文件本身是合法 TOML。`codex-config` 按 `CODEX_CONFIG_EDITOR`、`VISUAL`、`EDITOR`、`nano`、`vim`、`vi` 的顺序选择编辑器。保存后，脚本会将除 `api_key` 以外的内容生成运行用 `config.toml`，并让当前 Codex CLI 生成 `auth.json`。

如果旧的 `api-profile.toml` 为空、缺少 `api_key`、缺少 `model_provider` 或 TOML 已损坏，重新运行安装脚本会先将它备份为 `api-profile.toml.invalid.<时间>.<进程号>`，再重新询问 API 地址和 Key。新配置成功前，已经可用的运行配置不会被覆盖。

`model_provider` 是配置 ID，不是认证方式。若使用自定义 `[model_providers.<id>]`，必须保证它与顶层 `model_provider = "<id>"` 完全一致。

### 会话同步

API 和 ChatGPT 凭据分别位于独立 `CODEX_HOME`，会话、附件和 SQLite 状态放在共享目录：

```text
~/.local/share/clash-codex-autodl/codex-homes/api/
~/.local/share/clash-codex-autodl/codex-homes/chatgpt/
~/.local/share/clash-codex-autodl/codex-shared/
```

切换和手动同步前必须关闭其他 Codex CLI 或 Codex App 进程。同步使用互斥锁，成功后才更新当前配置指针；会话中的 `model_provider` 会按目标配置调整。无法自动合并的文件保存在 `codex-shared/import-conflicts/`，源文件不会被删除。

## 用户数据与卸载

```bash
bash uninstall.sh clash
bash uninstall.sh codex
bash uninstall.sh data
```

- `clash`：停止并卸载 Mihomo、代理命令和服务，保留订阅 URL。
- `codex`：卸载本项目安全管理的 Codex CLI 和包装命令，保留 API、ChatGPT 和会话数据。
- `data`：列出并永久删除订阅、双认证配置、会话、附件和迁移备份，需要输入 `DELETE` 二次确认。

自动化环境可以明确使用 `bash uninstall.sh data --yes`。用户原有的 `~/.codex` 始终不会被删除或覆盖。

重新安装时会复用已保留数据。旧版本的 API 档案会尽可能迁移到 `api-profile.toml`；迁移成功前不会删除旧数据。

## 数据布局

```text
~/.local/bin/                                      # 公开 proxy-* / codex-* 命令
~/.local/share/clash-codex-autodl/runtime/         # 可重装的运行文件和 Clash 组件
~/.local/share/clash-codex-autodl/codex-homes/     # API、ChatGPT 认证配置
~/.local/share/clash-codex-autodl/codex-shared/    # 共享会话数据
~/.config/clash-codex-autodl/                      # 订阅、API 单文件和当前配置指针
```

含 Key、token 或订阅 URL 的文件权限设置为 `600`。不要把这些目录提交到 Git 或发送到公开日志。

## 开发验证

```bash
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
shellcheck command.sh install-clash.sh install-codex.sh uninstall.sh setup_mihomo.sh converter.sh lib/*.sh
for test_file in tests/*.sh; do bash "$test_file"; done
```
