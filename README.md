<h1 align="center">Codex ChatGPT Bridge</h1>

<p align="center">
  <strong>A safe bridge that lets Codex and ChatGPT hand off coding work — ChatGPT does the heavy thinking, Codex keeps local execution and verification under control.</strong>
</p>

<p align="center">
  <strong>Save Codex tokens</strong> ·
  <strong>ChatGPT plans, Codex executes</strong> ·
  <strong>Local execution stays scoped and re-keyable</strong>
</p>

<p align="center">
  <a href="https://github.com/Zhenyu98/codex-chatgpt-bridge/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/Zhenyu98/codex-chatgpt-bridge?style=for-the-badge&logo=github"></a>
  <a href="LICENSE"><img alt="License MIT" src="https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge"></a>
  <img alt="Windows PowerShell" src="https://img.shields.io/badge/Windows-PowerShell-blue?style=for-the-badge&logo=windows&logoColor=white">
  <img alt="Codex Skill" src="https://img.shields.io/badge/Codex-Skill-5B7266?style=for-the-badge">
</p>

<p align="center">
  <a href="#why">Why</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#agent-setup">Agent Setup</a> ·
  <a href="#routing-modes">Routing</a> ·
  <a href="#security-model">Security</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="README_zh.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/assets/architecture.svg" alt="Codex ChatGPT Bridge architecture" width="92%" />
</p>

## Why

Long Codex sessions burn quota on planning, re-reading, and repeated design. This bridge moves that heavy thinking to ChatGPT and keeps Codex focused on execution and verification, so a long build stays within budget and under local control.

| Before | After |
|---|---|
| Copy large context into the Codex chat to get a review | ChatGPT reads the scoped project directly over the bridge |
| Codex spends quota planning, re-reading, and iterating | ChatGPT plans and reviews; Codex executes one task at a time |
| A remote tool with unclear reach into your machine | A narrow, OAuth-gated root that is off by default and re-keyable |

## Quick Start

```powershell
git clone https://github.com/Zhenyu98/codex-chatgpt-bridge.git
cd codex-chatgpt-bridge
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Expected success signal:

```text
Installed codex-chatgpt-bridge skill to C:\Users\<you>\.codex\skills\codex-chatgpt-bridge
Restart Codex or reload skills to use it.
```

Then check the local environment (no tunnel started):

```powershell
$skill = "$env:USERPROFILE\.codex\skills\codex-chatgpt-bridge"
powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Doctor
```

## Agent Setup

Copy this to Codex, Claude Code, Cursor, or another coding agent:

```text
Read https://github.com/Zhenyu98/codex-chatgpt-bridge/blob/main/agent-setup.md and follow it to install and configure codex-chatgpt-bridge for me.
```

See [agent-setup.md](agent-setup.md) for the full copy-paste prompt, prerequisites, and safe defaults.

## Routing Modes

- `NORMAL`: ChatGPT acts like a strong review/reasoning subagent. Codex inspects enough context to steer the task, then executes and verifies.
- `TOKEN_SAVING`: Codex acts mostly as the orchestrator. Safe non-mutating reading, broad review, and synthesis go to ChatGPT whenever they save Codex tokens.
- `CHATGPT_ARCHITECT`: the planning-inverted mode for long, continuous builds. ChatGPT is the architect/manager (spec, design, task decomposition, per-task prompts, review); Codex executes one small task at a time and verifies. With your explicit `L3` grant, ChatGPT can also write over the bridge while Codex integrates.

The router picks by marginal cost: a unit of work goes to ChatGPT when it saves far more Codex tokens than one slow bridge round-trip. When a plan needs parallel subagents, ChatGPT can serve as the subagent pool so the fan-out stays off Codex quota, while Codex remains the single orchestrator that integrates and verifies.

## Bridge Switch

```powershell
$skill = "$env:USERPROFILE\.codex\skills\codex-chatgpt-bridge"

powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Status
powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Doctor
powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Start -ProjectRoot <path> -Tunnel cloudflare -InstallCloudflared
powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Stop
powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Rotate
```

`Start` opens the local MCP service and its selected tunnel. `Doctor` checks the environment plus tunnel and public reachability. `Stop` closes the service and tunnel while keeping the ChatGPT app configuration, so the next start reuses the same app when a stable URL is used. `Rotate` is the panic button: it stops the bridge, revokes all issued OAuth tokens, and mints a new Owner password — run it after any suspected unauthorized access, then start and re-authorize.

For a stable ChatGPT app URL across restarts, put a stable Worker / custom proxy or external tunnel in front of the changing Quick Tunnel. Full walkthrough for creating the ChatGPT app (developer mode, app URL, OAuth, smoke test) is in [README_zh.md](README_zh.md).

## Security Model

Be honest about the trust boundary: once you OAuth-authorize the ChatGPT app, the bridge grants file read/write and shell execution on your machine. The `L0`–`L5` levels are policy Codex instructs ChatGPT to follow; they are guidance, and `run_shell` is not confined to the root, so an authorized app effectively holds local-user code execution. The boundaries actually enforced are OAuth approval (a strong random Owner password), the narrow `allowedRoots` for file tools, and stopping the bridge.

Practical rules:

- Keep the bridge stopped when you are not using it — the always-on public endpoint is the main attack surface.
- Keep the root narrow and free of secrets; for stronger isolation, run under a least-privilege OS account or a disposable VM.
- If you suspect someone else connected, run `-Action Rotate` to revoke all tokens and re-key.

## FAQ

**Can ChatGPT run anything on my machine?**

Once you OAuth-authorize the app, the bridge allows file read/write and shell within your setup. `run_shell` is not sandboxed, so treat an authorized app as local-user execution: keep the root narrow, stop the bridge when idle, and use `Rotate` to revoke access.

**Does `Stop` revoke ChatGPT's access?**

`Stop` closes the tunnel and service, so the workspace becomes unreachable, and it keeps the app authorization so the next `Start` reuses the same app. To actually revoke issued tokens, run `Rotate`.

**Will ChatGPT edit my source directly?**

In the default advice profile, Codex applies and verifies every change. With your explicit `L3` grant, ChatGPT writes over the bridge and Codex reviews the diff, runs an independent check, and owns git plus the final claim.

**The Quick Tunnel URL keeps changing.**

Quick Tunnel URLs rotate on restart, which suits testing. For a fixed ChatGPT app URL, front it with a stable Worker / custom proxy or external tunnel.

## Contributing

Issues and pull requests are welcome. Please keep reports specific, include reproduction steps when possible, and avoid sharing secrets in logs or screenshots.

## Acknowledgements

- Built on the open-source [DevSpace](https://github.com/Waishnav/devspace) project by Waishnav.
- Special thanks to [LINUX.DO](https://linux.do/) for providing a promotion platform.

## License

Released under the MIT License. See [LICENSE](LICENSE).

## Star History

[![Star History Chart](https://www.repostars.dev/api/og?repos=Zhenyu98%2Fcodex-chatgpt-bridge&theme=dark&ogv=4&v=20260705)](https://www.star-history.com/?repos=Zhenyu98%2Fcodex-chatgpt-bridge&type=date&legend=top-left)
