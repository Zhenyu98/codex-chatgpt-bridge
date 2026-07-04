---
name: codex-chatgpt-bridge
description: Use when the user wants Codex to coordinate Chrome ChatGPT, ChatGPT Apps or connectors, local MCP, Cloudflare or other tunnels, local project access, service start/stop/status switches, or task routing between ChatGPT Pro/high-intelligence reasoning and Codex local execution.
---

# Codex ChatGPT Bridge

## Overview

Coordinate three surfaces without confusing their authority:

- **Codex** is the local executor: inspect files, edit safely, run tests, manage processes, and verify artifacts.
- **Chrome ChatGPT** is the high-level reasoning partner: use it for broad synthesis, Pro/high-intelligence thinking, or user-visible ChatGPT workflows.
- **local MCP** is the bridge: expose one approved local project root to ChatGPT through a temporary or managed HTTPS tunnel.

Default posture: keep the bridge off unless the user asks to use it, expose only the intended project root, and treat ChatGPT-side actions as another agent whose output needs verification.

## Service Switch

Use `scripts/local_bridge.ps1` for repeatable operations.

```powershell
# Start for the current directory with Cloudflare Quick Tunnel
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\local_bridge.ps1 -Action Start -ProjectRoot <path> -Tunnel cloudflare -InstallCloudflared

# Start with an already-managed HTTPS tunnel or stable public URL
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\local_bridge.ps1 -Action Start -ProjectRoot <path> -Tunnel external -PublicBaseUrl https://your-host.example.com

# Start through a stable Cloudflare Workers proxy backed by a changing Quick Tunnel
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\local_bridge.ps1 -Action Start -ProjectRoot <path> -Tunnel cloudflare-worker -PublicBaseUrl https://local-bridge.<workers-subdomain>.workers.dev

# Inspect running processes and the current MCP URL
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\local_bridge.ps1 -Action Status

# Run doctor: devspace doctor (PATH fixed for npm and Git Bash) plus cloudflared
# presence, local-port listening, and public OAuth/MCP reachability when state exists
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\local_bridge.ps1 -Action Doctor

# Stop local bridge and the tunnel started by this switch
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\local_bridge.ps1 -Action Stop

# Panic button / re-key: stop, revoke all issued OAuth tokens, mint a new Owner password
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\local_bridge.ps1 -Action Rotate
```

## Switch Semantics

Use `Start` and `Stop` as an operational safety switch.

`Start` opens the local MCP service and the selected access path:
- no tunnel: local service only
- quick tunnel: local service plus temporary public tunnel
- worker/custom proxy: local service plus stable public URL backed by a current tunnel target

`Stop` should close the channel thoroughly enough for normal safety:
- stop the local bridge process
- stop the tunnel process that exposes it
- remove the transient `state.json`
- report any remaining bridge or tunnel processes

`Stop` intentionally does not delete:
- ChatGPT app configuration
- OAuth/client registration state
- local bridge config
- owner/auth files
- Worker proxy config

That preservation is what allows the next `Start` to reuse the same ChatGPT app without recreating settings or reauthorizing.

Important boundary: `Stop` is not the same as revoking OAuth. It closes reachability to the local workspace, but ChatGPT may still remember the app connection. Use ChatGPT app disconnect/revoke only when the goal is to invalidate authorization, accepting that the next use may require reauthorization.

For a no-reconfiguration workflow:
1. Use a stable ChatGPT app URL, preferably a Worker/custom proxy or another stable external URL.
2. Start/stop only the local bridge and current tunnel target.
3. Refresh the proxy target after each `Start` if the upstream tunnel changed.
4. Keep the same ChatGPT app URL and OAuth state.

Rules:

- Before `Start`, confirm the project root and whether a public tunnel is acceptable.
- Prefer Cloudflare Quick Tunnel for temporary tests; tell the user it is not stable or production-grade.
- If the account has no Cloudflare DNS zone, prefer a stable Workers proxy on `workers.dev` plus a Quick Tunnel upstream. The ChatGPT app URL stays stable while Codex refreshes the Worker KV target after each start.
- Prefer `-Tunnel external -PublicBaseUrl ...` when the user already has a stable tunnel; Quick Tunnel URLs change after restart and require updating the ChatGPT app URL.
- For `-Tunnel cloudflare-worker`, ensure `%LOCALAPPDATA%\devspace-bridge\worker-proxy.json` contains `workerBaseUrl`, `kvNamespaceId`, and `kvKey`.
- KV refresh is automatic when `%LOCALAPPDATA%\devspace-bridge\cf-api.json` exists with `{ "accountId": "...", "apiToken": "...", "kvNamespaceId": "..." }`. The token needs only account-scoped `Workers KV Storage: Edit`. With it, `Start` writes the new upstream to the `current` key over the REST API (`updateMode: rest-api`, `needsKvUpdate: false`) and needs no manual step or external plugin. The token is read locally and never printed; keep `cf-api.json` out of any repo. Without the file, `Start` degrades to the old manual flow (`needsKvUpdate: true`, `kvUpdateError` recorded in state).
- Never print `ownerToken` or Owner password. If ChatGPT authorization requires it, read it locally and fill it into the browser only after explicit user confirmation.
- After `Stop`, verify no `@waishnav/devspace` or matching `cloudflared` process remains.

## Setup Flow

1. Run `Status`; if already running, reuse or stop/restart only when the root or tunnel URL is wrong.
2. Run `Doctor`; fix missing Node/npm/Git Bash/cloudflared issues before touching ChatGPT UI.
3. Run `Start` with the selected project root. Capture the returned `mcpUrl`.
4. For Cloudflare Workers proxy mode, the KV `current` value is refreshed automatically when `cf-api.json` is present (see Rules). Confirm `state.workerProxy.needsKvUpdate` is `false`. If it is still `true` (no `cf-api.json`, or `kvUpdateError` set), refresh the KV `current` value manually with:
   - `upstream`: `state.workerProxy.upstream`
   - `publicBaseUrl`: `state.workerProxy.workerBaseUrl`
   - `updatedAt`: current ISO timestamp
   - `allowedHosts`: Worker host plus Quick Tunnel host
5. Verify public reachability (or run `-Action Doctor`, which checks these once state exists):
   - `/.well-known/oauth-protected-resource/mcp` should return `200`.
   - `/mcp` should return `401` before authorization.
6. Use the Chrome skill to open ChatGPT settings:
   - `Settings -> Apps -> Advanced settings`: ensure Developer mode is on.
   - `Apps -> Manage -> Create app`: create or update the app.
   - Name: concise project-agnostic name unless the user asks otherwise.
   - URL: the `mcpUrl`.
   - Auth: OAuth for local bridge.
7. When ChatGPT asks to log in to local bridge, stop and request explicit permission before entering the Owner password.
8. After authorization, run a read-only smoke test from ChatGPT first, then decide whether to allow edits.

## Routing Rules

Use this table before sending work through the bridge.

| Task shape | Primary surface | Why |
|---|---|---|
| Local edits, tests, git, process control, secrets, irreversible actions | Codex | Stronger local tool control and verification |
| Broad strategy, product/research synthesis, second-opinion reasoning, "think harder" questions | ChatGPT Pro/high-intelligence | Better use of ChatGPT-side reasoning budget |
| Read-only project orientation by ChatGPT | ChatGPT via local bridge | Useful when ChatGPT needs source context directly |
| Cross-agent critique or plan review | ChatGPT drafts, Codex verifies | Avoid blind trust in either side |
| Long execution with many shell/file operations | Codex, optionally with ChatGPT checkpoints | Saves ChatGPT tokens and keeps artifacts local |
| User-visible ChatGPT UI configuration | Codex via Chrome plugin | Needs logged-in browser state |

Do not route sensitive files, credentials, private keys, or broad home-directory access through the local bridge. Narrow `allowedRoots` before starting.

## Complex Interaction Pattern

Use a split-brain loop:

1. **Frame**: Codex summarizes the task, local constraints, and allowed root.
2. **Delegate reasoning**: Send ChatGPT a compact question or artifact-backed summary when Pro/high-intelligence reasoning is useful.
3. **Receive**: Extract ChatGPT's answer through Chrome. Treat it as advice, not ground truth.
4. **Execute**: Codex performs local edits/tests/commands.
5. **Verify**: Codex checks files, logs, tests, and browser-visible outcomes.
6. **Reconcile**: If ChatGPT's recommendation conflicts with local evidence, local evidence wins; ask ChatGPT only for revised reasoning or alternatives.

Token-saving pattern:

- Send ChatGPT summaries, file paths, or selected excerpts instead of whole repos.
- Let ChatGPT use local bridge only when direct source access materially improves reasoning.
- Keep repetitive local work in Codex and report compact checkpoints back to ChatGPT.

## Threat Model and Access Hardening

The concern that matters most here is not what your own ChatGPT can do, but who else can connect. The bridge equals local-user code execution, so unauthorized access is the real risk. What follows is grounded in the devspace source.

What protects you (the one gate):
- `/mcp` requires an OAuth 2.1 bearer token. Getting a token requires passing the `/authorize` form, which checks the **Owner password** against `ownerToken` with a timing-safe compare.
- `local_bridge.ps1` generates `ownerToken` as 32 random bytes (256-bit). That is not brute-forceable, so a stranger hitting your URL just sees a password form they cannot pass. You are not wide open.

The real risks:
- **Always-on exposure.** While the bridge runs, `/authorize` and the OAuth endpoints face the whole internet (the Worker is an open reverse proxy with no auth of its own; auth is entirely devspace's job). The single most effective control is to keep the bridge **stopped except when actively using it**.
- **No rate-limit or lockout** on the password form. Safe only because `ownerToken` is high-entropy. Never replace it with a memorable `DEVSPACE_OAUTH_OWNER_TOKEN`. Optionally add a Cloudflare WAF rate-limit rule on `/authorize` and `/token`.
- **Durable tokens; `Stop` does not revoke.** Issued bearer/refresh tokens live in memory and in `~/.devspace/oauth-state.json`. A previously authorized client, a leaked refresh token, or a stolen `~/.devspace/auth.json` keeps access across restarts. Use `-Action Rotate` to re-key (stop -> delete `oauth-state.json` -> mint a new `ownerToken`), then re-authorize your own ChatGPT. Optionally shorten `DEVSPACE_OAUTH_ACCESS_TOKEN_TTL_SECONDS` / `DEVSPACE_OAUTH_REFRESH_TOKEN_TTL_SECONDS`.
- **Blast radius is the whole machine.** `run_shell` is not root-scoped and devspace has no read-only or no-shell mode (`DEVSPACE_TOOL_MODE=minimal` only swaps grep/ls for shell; it does not remove shell). So if someone does get in, they have local-user execution. Narrow `allowedRoots`, keep secrets out of reach, and for real isolation run the bridge under a least-privilege OS account or a disposable VM/container.

Detection:
- Tool calls are logged by default, and `Start` sets `DEVSPACE_LOG_SHELL_COMMANDS=true` so `run_shell` command text is written to `devspace.out.log`. After any worry, read that log for activity you did not initiate.

Hardening checklist, by leverage:
1. Stop when not in use (`-Action Stop`); shrinks the public window from days to minutes.
2. Keep `ownerToken` random (default); run `-Action Rotate` after any suspected exposure and periodically.
3. Narrow the root; run under a least-privilege account or VM so a breach is not catastrophic.
4. Optional: Cloudflare WAF rate-limit on `/authorize`, shorter token TTLs, or a Cloudflare Access policy in front (note the ChatGPT OAuth flow complicates a full Access gate).
5. Watch `devspace.out.log`.

## Common Mistakes

| Mistake | Correction |
|---|---|
| Leaving Quick Tunnel running after the task | Run `Stop` and verify status |
| Leaving the bridge up between sessions | `Stop` when idle; the public window is your main attack surface |
| Suspected someone else connected | Run `Rotate` to revoke all tokens and re-key, then re-authorize |
| Exposing the wrong root | Stop, rewrite local bridge config, restart, then reauthorize if needed |
| Letting ChatGPT directly edit without review | Require Codex verification before final claims |
| Treating ChatGPT Pro output as proven | Ask for evidence, then validate locally |
| Reusing an old Quick Tunnel URL | Run `Status`; restart if the process or URL is stale |
| Printing Owner password into chat | Fill it only through browser automation after user confirmation |

## Completion Checklist

- Local bridge/tunnel state is known: running intentionally or stopped intentionally.
- The MCP URL and allowed root match the user's current task.
- ChatGPT authorization was explicitly approved if performed.
- Any ChatGPT-generated recommendation was locally verified before acting on it.
- Final answer states whether the bridge remains running and how to stop it.


