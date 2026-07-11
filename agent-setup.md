# Agent Setup / 代理一键设置

Fast path for an agent (Codex, Claude Code, etc.) to install and configure
`codex-chatgpt-bridge`. Full guide: [README.md](README.md) / 中文见 [README_zh.md](README_zh.md).

## Copy-Paste Prompt / 复制即用提示

```text
Please read https://github.com/Zhenyu98/codex-chatgpt-bridge (README.md and README_zh.md)
and follow it to install and configure the codex-chatgpt-bridge skill on this machine.
Goal: install the skill to %USERPROFILE%\.codex\skills\codex-chatgpt-bridge and confirm the
low-level Doctor check passes, without configuring or starting any public tunnel yet. Preserve
an existing installation with the installer's default timestamped backup behavior.
Before changing files outside the skill folder, using any credential, starting a public
tunnel, registering a scheduled task, pushing to git, or running destructive commands, show me
the plan and ask for approval.
Run only non-destructive checks by default, then report the exact files changed, commands run,
and the verification result.
```

## Prerequisites / 前置条件

- Windows + PowerShell, with Codex installed / 已安装 Codex
- Node.js + npm (for the `@waishnav/devspace` bridge CLI) / 桥的底层 CLI 需要
- A ChatGPT account with Developer mode — only if you will actually connect ChatGPT / 仅在真正连 ChatGPT 时需要
- Optional: `cloudflared` (the script can auto-download it) / 可选，脚本可自动下载
- Optional: a stable Cloudflare Worker plus a minimum-scope KV token, only for automatic
  stable-upstream refresh / 可选，仅稳定 Worker 自动刷新 upstream 时需要最小权限 KV token

User-provided secrets: none are required to install. If you later connect ChatGPT, you fill the
Owner password from your local `auth.json` yourself — never share it. /
安装不需要任何密钥；连 ChatGPT 时的 Owner password 由你本地填入，切勿外泄。

## Setup Steps / 安装步骤

1. Install / 安装:
   ```powershell
   git clone https://github.com/Zhenyu98/codex-chatgpt-bridge.git
   cd codex-chatgpt-bridge
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```
   Existing installations are backed up by default. Use `-ForceOverwrite` only with explicit
   approval. / 默认会备份旧安装；只有明确批准丢弃旧版时才用 `-ForceOverwrite`。
2. Verify environment, no tunnel / 检查环境，不开隧道:
   ```powershell
   $skill = "$env:USERPROFILE\.codex\skills\codex-chatgpt-bridge"
   powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Doctor
   ```
3. Only after the user approves the exact project root and public access mode, save a non-secret
   controller profile / 仅在用户批准准确项目目录与公网模式后保存非密钥 profile:
   ```powershell
   $controller = "$skill\scripts\bridge_controller.ps1"
   powershell -ExecutionPolicy Bypass -File $controller -Action Configure -ProjectRoot "D:\your\project" -Tunnel cloudflare -InstallCloudflared
   ```
   For `cloudflare-worker`, use the stable `-PublicBaseUrl` and run
   `set_cf_api_config.ps1 -Action Set` **before** `On`. The token is prompted securely and stored
   with Windows DPAPI; the helper also derives local-only, non-credential `worker-proxy.json`
   metadata from the saved profile. Keep that file out of git, and never put the token on the
   command line or print it. /
   Worker 模式要提供稳定 URL，并在 `On` 前用安全提示保存 DPAPI 凭据；脚本会从 profile 同步仅限本机、
   不含认证凭据但不得提交的 `worker-proxy.json`，不要把 token 放进命令行或输出。
4. Operate only through the controller / 日常操作只走 controller:
   ```powershell
   powershell -ExecutionPolicy Bypass -File $controller -Action On
   powershell -ExecutionPolicy Bypass -File $controller -Action Reboot
   powershell -ExecutionPolicy Bypass -File $controller -Action Off
   powershell -ExecutionPolicy Bypass -File $controller -Action Status
   powershell -ExecutionPolicy Bypass -File $controller -Action Doctor
   ```
   `Reboot` is one verified Restart transaction, not separate Stop and Start calls. `Off` records
   intentional shutdown, so a Reboot task cannot reopen it. / `Reboot` 是单个完整重启事务；
   `Off` 会记录有意关闭，防止任务误拉起。
5. Register the optional on-demand scheduled task only with explicit approval. It has no
   automatic trigger. `Run` is asynchronous, so verify `controller-result.json` and controller
   `Doctor` afterward. The default Interactive task requires the same user to be logged on and
   is reliability isolation, not a security boundary. / 计划任务需单独批准；无自动触发；运行后要查结果文件和 Doctor；
   默认 Interactive 任务要求用户已登录，只解决可靠性，不提供权限隔离。
6. Follow the README app-setup and begin with the read-only smoke test. /
   最后按 README 创建 app，并先做只读 smoke test。

## Success Signal / 成功标志

- `install.ps1` prints `Installed codex-chatgpt-bridge skill to ...`.
- Low-level `-Action Doctor` reports the devspace CLI present and no missing dependencies.
- After configuration and `On`, controller `Doctor` verifies the expected local/public `200/401`
  health contract; Worker mode also requires successful KV refresh.
- After reloading skills, Codex can see `codex-chatgpt-bridge`.

## Safety Rules / 安全规则

- Do not read or print secrets (`auth.json`, `ownerToken`, tokens, cookies). / 不读取或打印密钥。
- Do not start a public tunnel, push, delete, or deploy without explicit approval. /
  未经明确批准，不开公网隧道、不推送、不删除、不部署。
- Keep the exposed root narrow. Once authorized, the bridge is local-user code execution
  (`run_shell` is not sandboxed), so use controller `Off` when idle and use low-level
  `-Action Rotate` to revoke access. Controller output and logs contain paths, PIDs, and tunnel
  URLs, so redact them before sharing. /
  暴露的 root 要窄；授权后桥等于本地代码执行（`run_shell` 无沙箱），用完走 controller `Off`，
  怀疑泄露时用底层 `Rotate` 改锁；分享状态和日志前先脱敏路径、PID 与 tunnel URL。
