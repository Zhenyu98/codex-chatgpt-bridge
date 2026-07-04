# Agent Setup / 代理一键设置

Fast path for an agent (Codex, Claude Code, etc.) to install and configure
`codex-chatgpt-bridge`. Full guide: [README.md](README.md) / 中文见 [README_zh.md](README_zh.md).

## Copy-Paste Prompt / 复制即用提示

```text
Please read https://github.com/Zhenyu98/codex-chatgpt-bridge (README.md and README_zh.md)
and follow it to install and configure the codex-chatgpt-bridge skill on this machine.
Goal: install the skill to %USERPROFILE%\.codex\skills\codex-chatgpt-bridge and confirm the
bridge Doctor check passes, without starting any public tunnel yet.
Before changing files outside the skill folder, using any credential, starting a public
tunnel, pushing to git, or running destructive commands, show me the plan and ask for approval.
Run only non-destructive checks by default, then report the exact files changed, commands run,
and the verification result.
```

## Prerequisites / 前置条件

- Windows + PowerShell, with Codex installed / 已安装 Codex
- Node.js + npm (for the `@waishnav/devspace` bridge CLI) / 桥的底层 CLI 需要
- A ChatGPT account with Developer mode — only if you will actually connect ChatGPT / 仅在真正连 ChatGPT 时需要
- Optional: `cloudflared` (the script can auto-download it) / 可选，脚本可自动下载

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
2. Verify environment, no tunnel / 检查环境，不开隧道:
   ```powershell
   $skill = "$env:USERPROFILE\.codex\skills\codex-chatgpt-bridge"
   powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Doctor
   ```
3. Only when you choose to connect ChatGPT, follow the app-setup and read-only smoke test in
   the README. / 需要连 ChatGPT 时，再按 README 做 app 设置和只读 smoke test。

## Success Signal / 成功标志

- `install.ps1` prints `Installed codex-chatgpt-bridge skill to ...`.
- `-Action Doctor` reports the devspace CLI present and no missing dependencies.
- After reloading skills, Codex can see `codex-chatgpt-bridge`.

## Safety Rules / 安全规则

- Do not read or print secrets (`auth.json`, `ownerToken`, tokens, cookies). / 不读取或打印密钥。
- Do not start a public tunnel, push, delete, or deploy without explicit approval. /
  未经明确批准，不开公网隧道、不推送、不删除、不部署。
- Keep the exposed root narrow. Once authorized, the bridge is local-user code execution
  (`run_shell` is not sandboxed), so stop it when idle and use `-Action Rotate` to revoke access. /
  暴露的 root 要窄；授权后桥等于本地代码执行（`run_shell` 无沙箱），用完即 `Stop`，`Rotate` 可改锁撤销所有授权。
