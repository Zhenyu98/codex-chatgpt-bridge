# Codex ChatGPT Bridge

A safe bridge for Codex and ChatGPT to hand off coding work, save tokens on large reviews, and keep local execution under control.

[简体中文](README_zh.md)

## What It Does

`codex-chatgpt-bridge` is a user-level Codex skill package. It helps Codex decide when to work locally and when to ask ChatGPT for reasoning, review, visual analysis, or scoped local project inspection.

Core idea:

- Codex owns edits, tests, builds, git, and final verification.
- ChatGPT acts as a strong reasoning and review partner.
- The local bridge is off by default and can be started only when needed.
- Sensitive files, writes, destructive actions, privileged commands, and external irreversible actions stay behind explicit approval gates.

## Quick Install

```powershell
git clone https://github.com/Zhenyu98/codex-chatgpt-bridge.git
cd codex-chatgpt-bridge
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer copies the bundled skill to:

```text
%USERPROFILE%\.codex\skills\codex-chatgpt-bridge
```

Restart Codex or reload skills after installation.

## Bridge Switch

```powershell
$skill = "$env:USERPROFILE\.codex\skills\codex-chatgpt-bridge"

powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Status
powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Doctor
powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Start -ProjectRoot <path> -Tunnel cloudflare -InstallCloudflared
powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Stop
powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Rotate
```

`Start` opens the local MCP service and its selected tunnel. `Doctor` checks the environment plus tunnel and public reachability. `Stop` closes the service and tunnel while preserving the ChatGPT app configuration and authorization state, so the next start can reuse the same app when a stable URL is used. `Rotate` is the panic button: it stops the bridge, revokes all issued OAuth tokens, and mints a new Owner password — use it after any suspected unauthorized access, then start and re-authorize.

## Routing Modes

- `NORMAL`: ChatGPT acts like a strong review/reasoning subagent. Codex still inspects enough context to steer the task, then executes and verifies.
- `TOKEN_SAVING`: Codex acts mostly as the orchestrator. Safe non-mutating reading, broad review, and synthesis go to ChatGPT whenever possible.
- `CHATGPT_ARCHITECT`: the planning-inverted mode for long, continuous builds. ChatGPT is the architect/manager (spec, design, task decomposition, per-task prompts, review); Codex executes one small task at a time and verifies. Optionally, with your explicit `L3` grant, ChatGPT writes directly over the bridge and Codex integrates.

The router picks by marginal cost: hand a unit of work to ChatGPT only when it saves far more Codex tokens than one slow bridge round-trip. When a plan needs parallel subagents, ChatGPT can serve as the subagent pool so the fan-out does not spend Codex quota — while Codex stays the single orchestrator that integrates and verifies.

## ChatGPT App Setup

See [README_zh.md](README_zh.md) for a detailed walkthrough, including how to create the ChatGPT app, choose the MCP URL, authorize the connection, and run a read-only smoke test.

## Safety Defaults

- Do not expose home directories, whole drives, `.env`, auth files, SSH keys, API keys, browser cookies, or unrelated private folders.
- Keep the bridge root narrow: one project, one repo, one task.
- Use read-only or diagnostic access by default.
- Let Codex apply source edits and run verification locally.

## Security Model

Be honest with yourself about the trust boundary: once you OAuth-authorize the ChatGPT app, the bridge grants file read/write and shell execution on your machine. The `L0`–`L5` levels are policy that Codex instructs ChatGPT to follow, **not a sandbox** — `run_shell` is not confined to the root, so an authorized app effectively has local-user code execution. The boundaries that are actually enforced are: OAuth approval (a strong random Owner password), the narrow `allowedRoots` for file tools, and stopping the bridge.

Practical rules:

- Keep the bridge **stopped when you are not using it** — the always-on public endpoint is the main attack surface.
- Keep the root narrow and free of secrets; for stronger isolation, run under a least-privilege OS account or a disposable VM.
- If you ever suspect someone else connected, run `-Action Rotate` to revoke all tokens and re-key.

## For Agent Users

If you want an agent (Codex, Claude Code, etc.) to install and configure this for you, use [agent-setup.md](agent-setup.md) — it starts with a copy-paste prompt and safe defaults.

## Acknowledgements

- This project builds on the open-source [DevSpace](https://github.com/Waishnav/devspace) project by Waishnav.
- Special thanks to [LINUX.DO](https://linux.do/) for providing a promotion platform.

## License

[MIT](LICENSE)
