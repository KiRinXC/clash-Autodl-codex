# clash-codex-autodl

在 AutoDL、SeetaCloud 及其他 Linux 云主机上，以全局命令管理 Mihomo/Clash、Codex CLI，以及 API 和 ChatGPT 两种 Codex 认证。

项目将三个部分解耦：

- `clash-codex setup clash`：安装并配置 Mihomo/Clash。
- `clash-codex setup codex`：安装 Codex CLI。
- `clash-codex auth api` / `clash-codex auth chatgpt`：分别保存、验证和切换两种认证。

不再区分“国内/海外” Codex 配置，也不再使用 `codex-use-in`、`codex-use-out`。代理节点选择和 Codex 认证是两套独立的状态。

## 环境要求

- Linux 和 Bash。
- `curl`、`tar`、`gzip`、`awk`、`sed`、`ps`。
- 推荐安装 `python3`，用于配置解析和会话合并；没有 Python 时部分流程会使用系统工具回退。
- 如果官方安装器和 GitHub Release 都不可用，Codex CLI 还可以通过已存在的 `npm` 安装。

## 快速开始

### 1. 安装全局命令

```bash
git clone https://github.com/KiRinXC/clash-codex-autodl.git
cd clash-codex-autodl
bash install.sh
```

安装脚本会把命令安装到 `~/.local/bin`，并写入 `~/.bashrc`。重新登录或重新打开一个终端后即可在任意目录使用：

```bash
clash-codex --help
```

### 2. 一键初始化

```bash
clash-codex setup
```

一键流程依次完成 Clash 订阅配置、Mihomo 启动、Codex CLI 安装、API 认证和认证验证。脚本会交互式询问订阅地址和 API Key。

### 3. 按需分开配置

不同机器可以只执行需要的步骤：

```bash
# 只安装或重新配置 Mihomo/Clash
clash-codex setup clash

# 只安装 Codex CLI
clash-codex setup codex

# 配置或切换认证
clash-codex auth api
clash-codex auth chatgpt
```

旧版一键入口仍然保留：

```bash
bash start.sh
bash start.sh --reconfigure-clash
bash start.sh --reconfigure-codex
```

## 命令速查

| 命令 | 作用 |
| --- | --- |
| `clash-codex setup` | 一键配置 Clash、Codex 和 API 认证 |
| `clash-codex setup clash` | 安装/更新订阅并启动 Mihomo |
| `clash-codex setup codex` | 安装 Codex CLI 并安装 shell 包装函数 |
| `clash-codex auth api` | 配置 API 认证；已有有效配置时回车直接切换 |
| `clash-codex auth chatgpt` | 配置 ChatGPT 设备码认证；已有有效配置时回车直接切换 |
| `clash-codex auth status` | 查看两套认证是否有效 |
| `clash-codex auth {api,chatgpt} --use` | 验证并切换到已有认证档案 |
| `clash-codex auth {api,chatgpt} --edit` | 强制进入对应认证的修改流程 |
| `clash-codex status` | 查看代理、Codex、认证和会话同步状态 |
| `clash-codex verify` | 验证当前活动认证能否调用 Codex |
| `clash-codex sessions status` | 查看会话共享状态 |
| `clash-codex sessions sync` | 强制扫描并同步会话文件 |
| `clash-codex proxy on\|off` | 启用/关闭当前 shell 的代理环境变量 |
| `clash-codex proxy pick` | 交互式选择 Mihomo 节点 |
| `clash-codex proxy status` | 查看 Mihomo、代理环境和当前节点 |
| `clash-codex run ...` | 使用当前活动认证运行 Codex |
| `clash-codex uninstall clash\|codex\|all` | 卸载代理、Codex 或全部项目组件 |

## 认证档案

两种认证分别保存在独立的 `CODEX_HOME`，切换时只改变活动档案指针：

```text
~/.local/share/clash-codex-autodl/codex-homes/api/
~/.local/share/clash-codex-autodl/codex-homes/chatgpt/
```

用户原有的 `~/.codex` 不会被覆盖或删除。认证凭据不会写入 Git 仓库；请不要把 API Key、ChatGPT 凭据或订阅地址提交到公开仓库。

### API 认证

首次运行：

```bash
clash-codex auth api
```

脚本会询问可选的 API Endpoint 和 API Key。Endpoint 直接回车使用 Codex 默认地址；修改已有自定义 Endpoint 时输入 `-` 可恢复默认地址。

已有有效 API 档案时，直接回车会复用并启用现有配置，不会重新索取 API Key。需要修改时选择 `m`，或直接使用：

```bash
clash-codex auth api --edit
```

修改 Endpoint 不一定需要更换 API Key；脚本会单独询问是否更换 Key。新配置会先在临时目录中验证，验证失败时保留原档案。

### ChatGPT 认证

无图形终端可以使用 Codex 的设备码登录：

```bash
clash-codex auth chatgpt
```

终端会启动 `codex login --device-auth`，然后显示验证网址和设备码。用另一台具有浏览器的设备打开网址并完成登录，再回到当前 SSH 会话等待验证完成。

该流程仍依赖当前机器能够访问 OpenAI 登录服务。若出口网络遇到 Cloudflare 验证或被拦截，认证会失败；这不是 API 认证的问题，可以更换 Mihomo 节点或网络出口后重试。

已有有效 ChatGPT 档案时，直接回车只切换档案；需要重新登录时使用：

```bash
clash-codex auth chatgpt --edit
```

## 会话同步

认证凭据彼此隔离，但 API 和 ChatGPT 共享会话状态：

```text
~/.local/share/clash-codex-autodl/codex-shared/
├── sessions/
├── archived_sessions/
├── attachments/
├── thread-writer-locks/
├── session_index.jsonl
└── sqlite/
```

执行 `clash-codex auth ...` 或 `clash-codex run ...` 时会自动初始化共享布局。也可以手动检查或同步：

```bash
clash-codex sessions status
clash-codex sessions sync
```

首次同步会从以下位置导入会话，不删除源文件：

```text
~/.codex/
~/.local/share/clash-codex-autodl/codex-homes/api/
~/.local/share/clash-codex-autodl/codex-homes/chatgpt/
```

迁移规则如下：

- 同内容文件直接复用；可判断为追加内容的 JSONL 文件保留较长且带有原内容前缀的版本。
- 无法自动合并的分叉文件保留在 `codex-shared/import-conflicts/`，不会静默覆盖。
- 原认证档案中被共享链接替换的目录和文件保留在 `codex-shared/migration-backups/`。
- 首次迁移前必须关闭其他 Codex CLI 或 Codex App 进程。

同步参考了 [codex-provider-sync](https://github.com/Dailin521/codex-provider-sync) 对 rollout 和 SQLite 会话可见性的处理。包含 `encrypted_content` 的会话可以同步和显示，但跨账号或跨后端继续对话时，可能因无法解密原推理内容而失败。

## Codex 与代理

安装 shell 包装函数后，`codex` 会自动使用当前活动认证：

```bash
codex
codex exec "检查当前项目"
```

如果当前 shell 尚未重新加载 `~/.bashrc`，可以直接使用：

```bash
codex-autodl
clash-codex run exec "检查当前项目"
```

代理快捷命令在任意目录可用：

```bash
proxy-on
proxy-off
proxy-pick
proxy-status
```

普通子进程不能修改父 shell 的环境变量，因此不重新打开终端时请使用：

```bash
eval "$(clash-codex proxy on)"
eval "$(clash-codex proxy off)"
```

代理节点选择只影响 Mihomo 的出口，不会更改 API/ChatGPT 认证档案。

## 数据目录

```text
~/.local/bin/clash-codex                         # 全局主命令
~/.local/bin/codex-autodl                        # Codex 入口
~/.local/share/clash-codex-autodl/runtime/       # 项目运行文件
~/.local/share/clash-codex-autodl/codex-homes/   # 两套认证档案
~/.local/share/clash-codex-autodl/codex-shared/  # 共享会话
~/.config/clash-codex-autodl/                    # 活动认证和订阅配置
```

## 重新配置与卸载

重新配置不需要进入项目目录：

```bash
clash-codex setup clash
clash-codex setup codex
clash-codex auth api --edit
clash-codex auth chatgpt --edit
```

卸载命令：

```bash
clash-codex uninstall clash  # 停止并删除 Mihomo、订阅和代理 shell 命令
clash-codex uninstall codex  # 删除项目管理的 Codex 和认证档案
clash-codex uninstall all    # 删除全部项目组件
```

卸载不会删除或修改用户原有的 `~/.codex`，也默认保留 `codex-shared/`，以避免误删会话。只有安装清单确认由本项目安装、且位于用户目录下的 Codex CLI 才会被删除。

## 开发验证

项目包含 Bash 语法检查、ShellCheck、代理行为、全局安装、认证档案、会话同步和卸载流程的 smoke tests。当前完整测试结果：

```text
本地 smoke tests: 30/30 通过
AutoDL 远程 smoke tests: 30/30 通过
ShellCheck: 通过
```

本项目的初始化思路参考并致谢 [glerium/clash-for-AutoDL](https://github.com/glerium/clash-for-AutoDL)。
