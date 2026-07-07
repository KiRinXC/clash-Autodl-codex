# clash-codex-autodl

`clash-codex-autodl` 用来在 AutoDL、SeetaCloud 或类似 Linux 云主机上快速配置 Mihomo/Clash 和 Codex CLI。

新租的机器通常没有 Clash，也没有 Codex。这个项目的目标是让你通过一个交互式脚本完成初始化，然后在之后的终端里直接使用代理和 Codex 中转站切换命令。

本项目参考并致谢 [glerium/clash-for-AutoDL](https://github.com/glerium/clash-for-AutoDL)。
在其思路上，我把流程整理成了更偏终端交互的 AutoDL 初始化、代理切换和 Codex 配置体验。

## 快速开始

在目标服务器上执行：

```bash
git clone https://github.com/KiRinXC/clash-codex-autodl.git
cd clash-codex-autodl
bash start.sh
```

安装完成后，脚本会用 `[WARN]` 提醒你重新打开一个终端。新终端会自动识别 `proxy-*` 和 `codex-*` 命令，并恢复代理状态。

脚本会依次提示你输入：

```text
请输入 Clash/Mihomo 订阅地址
请输入国内直连中转站地址
请输入国外代理中转站地址
请输入 OpenAI API Key
```

这些内容会持久化到本机：

```text
~/.config/clash-codex-autodl/config.sh
~/.codex/auth.json
~/.codex/config.toml
~/.codex/clash-codex-autodl.sh
```

## 初始化流程

`bash start.sh` 会完成：

- 下载 Clash/Mihomo 订阅。
- 安装并启动 Mihomo。
- 创建 `CodexProxy` 节点选择组。
- 安装终端启动钩子。
- 显示代理开启、关闭、节点切换和状态命令。
- 检查 `codex` 命令是否可用，不可用时通过当前代理下载 Codex CLI。
- 写入 Codex API key 和 `~/.codex/config.toml`。
- 运行 Codex 冒烟测试，确认能回复 `CODEX_RELAY_READY`。

## 代理命令

代理命令控制当前 shell 的代理环境变量、Mihomo 进程和 Mihomo 节点，不会切换 Codex 中转站。

```bash
proxy-on
proxy-off
proxy-pick
proxy-status
```

- `proxy-on`：确认 Mihomo 已监听代理端口；必要时尝试用现有配置启动 Mihomo，然后为当前 shell 设置 `http_proxy`、`https_proxy` 等代理环境变量。Mihomo 未能启动时不会留下失效的代理变量。
- `proxy-off`：移除当前 shell 的代理环境变量。
- `proxy-pick`：交互式切换 `CodexProxy` 选择组里的节点。
- `proxy-status`：显示代理是否开启、Mihomo 是否运行、代理地址和当前节点。

## Codex 中转站命令

Codex 中转站命令只处理 Codex 使用哪个中转站，以及本机保存的中转站网址；不会开启或关闭代理。

```bash
codex-use-in
codex-use-out
codex-ex-in [url]
codex-ex-out [url]
codex-status
codex-verify
```

- `codex-use-in`：让 Codex 使用国内/直连中转站。
- `codex-use-out`：让 Codex 使用国外/代理中转站。
- `codex-ex-in [url]`：修改国内/直连中转站网址；不传 `url` 时会在终端提示输入。
- `codex-ex-out [url]`：修改国外/代理中转站网址；不传 `url` 时会在终端提示输入。
- `codex-status`：显示当前 Codex 使用的中转站。
- `codex-verify`：运行 Codex 冒烟测试。

`codex-ex-in` 和 `codex-ex-out` 会把新网址持久化到本机配置。如果你修改的是当前正在使用的那一路，也会立即刷新 `~/.codex/config.toml`。修改国外/代理中转站时，会同步更新 Mihomo 里的海外中转规则。

如果你想通过代理访问国外中转站，通常需要手动组合：

```bash
proxy-on
codex-use-out
codex-verify
```

如果你想回到直连：

```bash
proxy-off
codex-use-in
codex-verify
```

## 新终端自动检查

初始化完成后，新开的终端会通过 `~/.bashrc` 自动加载启动钩子：

```bash
[ -f "$HOME/.codex/clash-codex-autodl.sh" ] && . "$HOME/.codex/clash-codex-autodl.sh"
```

启动钩子会显示：

```text
[OK] 代理已开启: http://127.0.0.1:7890
[OK] 当前节点: <node name>
[OK] Codex 中转站: domestic <url>
```

代理状态会被持久化；新终端默认尝试恢复开启，只有执行 `proxy-off` 后才会关闭。如果 Mihomo 没能启动，新终端会清理失效代理环境并提示原因。
新终端不会自动运行耗时的 Codex 冒烟测试；需要确认 Codex 是否可用时，手动执行 `codex-verify`。

## 重新配置

重新配置全部内容：

```bash
bash start.sh --reconfigure
```

只重新配置 Clash/Mihomo 订阅：

```bash
bash start.sh --reconfigure-clash
```

只重新配置 Codex 中转站和 API key：

```bash
bash start.sh --reconfigure-codex
```

## 验证

检查当前 Codex 配置：

```bash
bash verify_codex.sh current
```

切到国内/直连中转站后验证：

```bash
bash verify_codex.sh domestic
```

切到国外/代理中转站后验证：

```bash
bash verify_codex.sh overseas
```

## 卸载

只卸载代理组件：

```bash
bash uninstall_codex_bootstrap.sh --proxy
```

卸载 Codex 配置和本项目安装的 Codex CLI：

```bash
bash uninstall_codex_bootstrap.sh --codex
```

代理、Codex 和本项目本机配置全部卸载：

```bash
bash uninstall_codex_bootstrap.sh --all
```
