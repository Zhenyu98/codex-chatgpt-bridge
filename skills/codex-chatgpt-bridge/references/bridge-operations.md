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

Use `scripts/bridge_controller.ps1` for normal lifecycle operations. Keep `scripts/local_bridge.ps1` as the low-level runtime primitive and panic-rotate entrypoint.

```powershell
# Persist the non-secret restart profile
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\bridge_controller.ps1 -Action Configure -ProjectRoot <path> -Tunnel cloudflare-worker -PublicBaseUrl https://bridge.example.workers.dev -InstallCloudflared

# Worker mode only: store the minimum-scope KV token with Windows DPAPI before On
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\set_cf_api_config.ps1 -Action Set -AccountId <account-id> -KvNamespaceId <namespace-id>

# Intentionally open or close the bridge
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\bridge_controller.ps1 -Action On
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\bridge_controller.ps1 -Action Off

# One verified transaction; Reboot is an alias of Restart
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\bridge_controller.ps1 -Action Restart
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\bridge_controller.ps1 -Action Reboot

# Inspect controller/runtime state and health
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\bridge_controller.ps1 -Action Status
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\bridge_controller.ps1 -Action Doctor

# Optional on-demand scheduled task; no automatic trigger
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\restart_task.ps1 -Action Install
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\restart_task.ps1 -Action Run

# Panic button / re-key: stop, revoke all issued OAuth tokens, mint a new Owner password
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\local_bridge.ps1 -Action Rotate
```

For multiple explicit file-tool roots, keep `-ProjectRoot` as the default working directory and add `-AllowedRoots "<root1>;<root2>"`. The controller persists this list in profile schema v2 and reuses it on later configuration and lifecycle operations.

The credential helper derives `worker-proxy.json` from the saved `cloudflare-worker` profile, so the required order on a fresh setup is `Configure` -> `set_cf_api_config Set` -> `On`. The scheduled task `Run` command is asynchronous; verify `%LOCALAPPDATA%\devspace-bridge\controller-result.json` and controller `Doctor` before reporting success.

## Switch Semantics

Use `On`, `Off`, and `Restart`/`Reboot` as the operational safety switch.

The controller keeps three concerns separate:

- `controller-profile.json`: persistent non-secret project/tunnel configuration
- `desired-state.json`: the operator's intentional `running` or `stopped` state
- `state.json`: transient process IDs, current Quick Tunnel, Worker status, and logs

`Restart` and `Reboot` execute one mutex-protected operation: load the saved profile, refuse an intentionally stopped bridge, stop the old runtime, start a new runtime, require Worker KV refresh in `cloudflare-worker` mode, verify the local/Quick Tunnel/stable Worker endpoint pairs, and report success only after every check reaches `200/401`.

`On` starts from the saved profile and sets desired state to `running`. `Off` records desired state `stopped` before closing the runtime. A low-level `Stop` invoked accidentally leaves desired state `running`, so the external on-demand Reboot task can recover it. The scheduled task has no automatic trigger; it does not reopen the bridge by itself.

Low-level runtime behavior remains:

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
2. Configure the controller once, then use `On`, `Off`, and `Reboot`.
3. Let the controller refresh and verify the proxy target whenever the upstream tunnel changes.
4. Keep the same ChatGPT app URL and OAuth state.

Rules:

- Before controller `Configure`/`On`, confirm the project root and whether a public tunnel is acceptable.
- Prefer Cloudflare Quick Tunnel for temporary tests; tell the user it is not stable or production-grade.
- If the account has no Cloudflare DNS zone, prefer a stable Workers proxy on `workers.dev` plus a Quick Tunnel upstream. The ChatGPT app URL stays stable while Codex refreshes the Worker KV target after each start.
- Prefer `-Tunnel external -PublicBaseUrl ...` when the user already has a stable tunnel; Quick Tunnel URLs change after restart and require updating the ChatGPT app URL.
- For `-Tunnel cloudflare-worker`, ensure `%LOCALAPPDATA%\devspace-bridge\worker-proxy.json` contains `workerBaseUrl`, `kvNamespaceId`, and `kvKey`.
- For controller-driven restart, store the token with `set_cf_api_config.ps1`. It writes `%LOCALAPPDATA%\devspace-bridge\cf-api.protected.json` using Windows DPAPI `CurrentUser`; the token needs only account-scoped `Workers KV Storage: Edit`, is decrypted only in memory, and is never printed. The helper verifies a DPAPI round trip, removes a migrated plaintext `cf-api.json`, and controller `On` / `Reboot` refuses plaintext legacy credentials. Keep every credential and state file out of every repo.
- `-InstallCloudflared` verifies a valid Windows Authenticode signature from Cloudflare, Inc. before installing or running the downloaded executable.
- Stable Worker and external public base URLs must be absolute HTTPS URLs without embedded credentials, query strings, or fragments.
- Low-level `Stop` discovers only DevSpace listening on the configured port plus the matching cloudflared tunnel. It reports and preserves unrelated port owners.
- Controller `Doctor.securityWarnings` flags drive-root, full-user-profile, and user-profile-ancestor allowed roots without silently changing the user's configured scope.
- Shell-command logging defaults to disabled. Set the user-level `DEVSPACE_LOG_SHELL_COMMANDS=true` only when a local command audit trail is explicitly required.
- Controller `On` and `Restart` use strict Worker KV mode. A missing or failed KV credential is an error, and a failed health gate is cleaned up instead of being reported as success. Direct low-level `Start` can still record `needsKvUpdate: true` for a manual browser-repair flow unless `-RequireWorkerKv` is supplied.
- Never print `ownerToken` or Owner password. If ChatGPT authorization requires it, read it locally and fill it into the browser only after explicit user confirmation.
- After controller `Off` (or a low-level recovery `Stop`), verify no managed `@waishnav/devspace` or matching `cloudflared` process remains.

## Setup Flow

1. Run controller `Status`; if a runtime is already healthy, reuse it.
2. Run the low-level `Doctor` once to validate Node/npm/Git Bash/devspace/cloudflared prerequisites without opening a public tunnel.
3. Run controller `Configure` with the exact project root, tunnel type, port, and stable public URL. Existing healthy runtime state may be imported when `-ProjectRoot` is omitted.
4. In `cloudflare-worker` mode, create the minimum-scope token and store it with `set_cf_api_config.ps1 -Action Set`.
5. Run controller `On`; capture the returned runtime `mcpUrl` and health evidence.
6. Confirm `state.workerProxy.needsKvUpdate` is `false`. A manual low-level start may still require refreshing the KV `current` value with:
   - `upstream`: `state.workerProxy.upstream`
   - `publicBaseUrl`: `state.workerProxy.workerBaseUrl`
   - `updatedAt`: current ISO timestamp
   - `allowedHosts`: Worker host plus Quick Tunnel host
7. Verify public reachability with controller `Doctor`:
   - `/.well-known/oauth-protected-resource/mcp` should return `200`.
   - `/mcp` should return `401` before authorization.
8. Optionally register the on-demand Reboot task after explicit user approval. Do not add an automatic trigger by default.
9. Use the Chrome skill to open ChatGPT settings:
   - `Settings -> Apps -> Advanced settings`: ensure Developer mode is on.
   - `Apps -> Manage -> Create app`: create or update the app.
   - Name: concise project-agnostic name unless the user asks otherwise.
   - URL: the `mcpUrl`.
   - Auth: OAuth for local bridge.
10. When ChatGPT asks to log in to local bridge, stop and request explicit permission before entering the Owner password.
11. After authorization, run a read-only smoke test from ChatGPT first, then decide whether to allow edits.

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
- **Always-on exposure.** While the bridge runs, `/authorize` and the OAuth endpoints face the whole internet (the Worker is an open reverse proxy with no auth of its own; auth is entirely devspace's job). The single most effective control is to keep the bridge **off except when actively using it**.
- **No rate-limit or lockout** on the password form. Safe only because `ownerToken` is high-entropy. Never replace it with a memorable `DEVSPACE_OAUTH_OWNER_TOKEN`. Optionally add a Cloudflare WAF rate-limit rule on `/authorize` and `/token`.
- **Durable tokens; controller `Off` does not revoke.** Issued bearer/refresh tokens live in memory and in `~/.devspace/oauth-state.json`. A previously authorized client, a leaked refresh token, or a stolen `~/.devspace/auth.json` keeps access across restarts. Use low-level `-Action Rotate` to re-key (stop -> delete `oauth-state.json` -> mint a new `ownerToken`), then re-authorize your own ChatGPT. Optionally shorten `DEVSPACE_OAUTH_ACCESS_TOKEN_TTL_SECONDS` / `DEVSPACE_OAUTH_REFRESH_TOKEN_TTL_SECONDS`.
- **Blast radius is the whole machine.** `run_shell` is not root-scoped and devspace has no read-only or no-shell mode (`DEVSPACE_TOOL_MODE=minimal` only swaps grep/ls for shell; it does not remove shell). So if someone does get in, they have local-user execution. Narrow `allowedRoots`, keep secrets out of reach, and for real isolation run the bridge under a least-privilege OS account or a disposable VM/container.

Detection:
- Tool calls are logged by default, and `Start` sets `DEVSPACE_LOG_SHELL_COMMANDS=true` so `run_shell` command text is written to `devspace.out.log`. After any worry, read that log for activity you did not initiate.

Hardening checklist, by leverage:
1. Use controller `Off` when not in use; this records intentional shutdown and shrinks the public window from days to minutes.
2. Keep `ownerToken` random (default); run `-Action Rotate` after any suspected exposure and periodically.
3. Narrow the root; run under a least-privilege account or VM so a breach is not catastrophic.
4. Optional: Cloudflare WAF rate-limit on `/authorize`, shorter token TTLs, or a Cloudflare Access policy in front (note the ChatGPT OAuth flow complicates a full Access gate).
5. Watch `devspace.out.log`.

## Common Mistakes

| Mistake | Correction |
|---|---|
| Leaving Quick Tunnel running after the task | Run controller `Off` and verify status |
| Leaving the bridge up between sessions | Use controller `Off` when idle; the public window is your main attack surface |
| Suspected someone else connected | Run `Rotate` to revoke all tokens and re-key, then re-authorize |
| Exposing the wrong root | Use `Off`, review and update the controller profile, then use `On`; reauthorize only if needed |
| Letting ChatGPT directly edit without review | Require Codex verification before final claims |
| Treating ChatGPT Pro output as proven | Ask for evidence, then validate locally |
| Reusing an old Quick Tunnel URL | Run `Status`; restart if the process or URL is stale |
| Printing Owner password into chat | Fill it only through browser automation after user confirmation |

## Completion Checklist

- Local bridge/tunnel state is known: controller desired state is intentionally `running` or `stopped`.
- The MCP URL and allowed root match the user's current task.
- ChatGPT authorization was explicitly approved if performed.
- Any ChatGPT-generated recommendation was locally verified before acting on it.
- Final answer states whether the bridge remains running and how to stop it.
