---
name: codex-chatgpt-bridge
description: Use when Codex needs to coordinate ChatGPT, Chrome, Cloudflare tunnels, or task routing between local code execution and ChatGPT reasoning/review. Handles bridge start/stop/status, ChatGPT app setup, local bridge permission levels, token-saving handoffs, large-context review, visual/PDF review, complex bug routing, and human approval gates.
---

# Codex ChatGPT Bridge

Use this skill as the single entrypoint for coordinating Codex, ChatGPT, a scoped local MCP bridge, Chrome, and optional Cloudflare tunnels.

Core principle:

- Codex is the execution owner.
- ChatGPT is the reasoning and review partner.
- The local bridge is a scoped local access bridge.
- Chrome is the message transport.

Default posture:

- Codex owns source edits, tests, builds, git operations, local verification, and final reporting.
- ChatGPT owns high-depth reasoning, broad review, visual/PDF/screenshot analysis, and independent go/no-go critique.
- The local bridge defaults to one narrow workspace, read-only access, and no secrets.
- ChatGPT recommendations are advice until Codex verifies them locally.

## Choose The Mode

Use bridge operations when the user asks to start, stop, inspect, repair, or configure ChatGPT access to a local project through the bridge.

Read `references/bridge-operations.md` for:

- `local_bridge.ps1` start, stop, status, and doctor flows
- Cloudflare Quick Tunnel and Worker-proxy setup
- ChatGPT app/OAuth setup through Chrome
- on/off semantics that preserve ChatGPT configuration without leaving the workspace reachable
- service lifecycle and common failure handling

Use task routing when the user asks whether Codex, ChatGPT, subagents, or the local bridge should handle a task.

Read `references/router-policy.md` for:

- `NORMAL` and `TOKEN_SAVING` operating modes
- route classes
- permission levels
- ChatGPT Task Packet format
- ChatGPT Action Manifest format
- Codex ingestion rules
- token-saving policy
- security rules
- hardware/KiCad and debugging workflows

Use examples only when drafting a concrete handoff.

Read `references/examples.md` for:

- KiCad hardware review packets
- paper/code review packets
- complex bug packets
- image/PDF visual review packets
- ChatGPT Architect workflow (spec -> tasks -> per-task Codex execution prompt)

Read `references/hook-design.md` only when designing automation around this policy.

Read `references/agents-snippet.md` only when adding project-level AGENTS.md guidance.

## Service Switch

Use the bundled script for repeatable bridge operations.

```powershell
$skill = "$env:USERPROFILE\.codex\skills\codex-chatgpt-bridge"

powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Status
powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Doctor
powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Start -ProjectRoot <path> -Tunnel cloudflare -InstallCloudflared
powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Stop
powershell -ExecutionPolicy Bypass -File "$skill\scripts\local_bridge.ps1" -Action Rotate
```

Switch semantics:

- `Start` opens the local MCP service and its selected tunnel.
- `Stop` closes the local service and tunnel, verifies remaining processes, and removes the transient state file.
- `Rotate` is the panic button: it stops the bridge, deletes persisted OAuth tokens (`~/.devspace/oauth-state.json`), and mints a new Owner password, so anyone who is or was connected is locked out. Use it after any suspected unauthorized access; then `Start` and re-authorize ChatGPT. See the threat-model section in `references/bridge-operations.md`.
- `Stop` intentionally preserves ChatGPT app configuration, local bridge config, and authorization material so the next `Start` can reuse the same ChatGPT app without recreating or reauthorizing.
- This is a safety switch, not an OAuth revoke. ChatGPT keeps the app connection record, but with the local service and tunnel stopped it cannot reach the workspace.
- For no ChatGPT reconfiguration across restarts, prefer a stable Worker/custom proxy or stable external tunnel. Raw temporary tunnel URLs can change after restart.

Before starting a public tunnel, confirm:

- exact project root
- whether a public tunnel is acceptable
- whether the root is narrow enough for the task
- whether ChatGPT should get `L1_READ_ONLY` or `L2_DIAGNOSTIC_COMMANDS`

Never print owner tokens, OAuth secrets, browser cookies, or private keys into chat.

## Operating Modes

Choose a routing mode before sending a task to ChatGPT.

`NORMAL` mode:

- Treat ChatGPT as a strong reasoning and review subagent.
- Codex performs enough local inspection to frame the task, then asks ChatGPT for independent reasoning, review, or alternatives when useful.
- Codex remains the owner of edits, tests, builds, git, and final verification.
- Use this when quality, collaboration, and confidence matter more than minimizing Codex token use.

`TOKEN_SAVING` mode:

- Treat Codex as the orchestrator and ChatGPT as the primary reader/reasoner for safe, non-mutating context work.
- Prefer ChatGPT plus the local bridge for broad file reading, long logs, large project orientation, architecture review, paper/hardware critique, and visual/PDF review.
- Codex should send compact task packets, avoid summarizing large context itself, then implement and verify only the accepted actions.
- Still keep secrets, writes, destructive actions, privileged commands, tests/build execution, git, and final claims under Codex or human approval.
- Route by marginal cost: hand a unit of work to ChatGPT only when the Codex tokens it would otherwise cost greatly exceed one slow bridge round-trip; keep many small mechanical ops in Codex, and batch ChatGPT into one dense turn instead of a tool-by-tool loop. See "Cost-Aware Routing" in `references/router-policy.md`.
- Use this when the user asks to save tokens or when context size is the main cost.

`CHATGPT_ARCHITECT` mode:

- The planning-inverted extreme of `TOKEN_SAVING`: ChatGPT is the architect/manager, Codex is the executor or integrator.
- ChatGPT owns the spec, UI/data design, task decomposition, per-task Codex prompt authoring, and review.
- Two execution profiles: in the default advice profile Codex writes every source change and verifies; in the independent-agent profile (`L3_WORKSPACE_WRITE`, opt-in by the user) ChatGPT writes source inside the one narrow root and self-verifies, then Codex reviews the diff, runs an independent check, and owns git plus the final claim.
- Either way keep the guardrails: a task is done only on an independent local check, not ChatGPT's say-so; ChatGPT never commits, pushes, installs, deletes beyond the task, touches secrets, or reaches outside the root; Codex feasibility-checks the plan first and does not over-decompose trivial work.
- Use this for long continuous builds, whole features/apps/games, or when avoiding Codex usage limits is the goal. See `references/router-policy.md` for the execution profiles, Architect Loop, and Codex Execution Prompt format.

## Route Quick Reference

Use `ROUTE_CODEX_EXECUTE` when the task requires file edits, tests, builds, git diff, scripts, deterministic checks, or final implementation.

Use `ROUTE_CODEX_SUBAGENTS` when the plan needs parallel agent roles — but Codex subagents are themselves Codex quota (N roles ≈ N× context). ChatGPT is Codex's subagent pool: by default fill those roles with ChatGPT (read-only roles at `L1`/`L2`, implementing roles at the `L3` independent-agent profile), one role per ChatGPT packet/thread, while Codex stays the single orchestrator that integrates and verifies. Keep a Codex subagent only as the exception, when a role needs fast local concurrency or a tight execute/iterate loop. In `TOKEN_SAVING`/`CHATGPT_ARCHITECT` this is the default. See "Cost-Aware Routing → ChatGPT is Codex's subagent pool" in `references/router-policy.md`.

Use `ROUTE_CHATGPT_REASONING` when the task needs high-depth conceptual, architectural, hardware, paper, novelty, experiment, or go/no-go reasoning.

Use `ROUTE_CHATGPT_PLAN` when ChatGPT should produce the spec, design, ordered task decomposition, or the per-task Codex execution prompt (the core of `CHATGPT_ARCHITECT` mode).

Use `ROUTE_CHATGPT_LOCAL_READ` when ChatGPT should inspect a large local project directly to save Codex tokens.

Use `ROUTE_CHATGPT_VISION` when PDFs, screenshots, plots, UI images, schematics, PCB renders, diagrams, or photos are central evidence.

Use `ROUTE_HUMAN_APPROVAL` before privileged, destructive, irreversible, external, credential-bearing, or hardware-impacting actions.

## Permission Levels

Choose the lowest sufficient permission level:

- `L0_NO_TOOL`: prompt-only ChatGPT reasoning.
- `L1_READ_ONLY`: the local bridge may open/list/read/search in one narrow workspace.
- `L2_DIAGNOSTIC_COMMANDS`: non-mutating commands such as `rg`, listing, `git status`, `git diff --stat`, static analysis, dry-runs, test discovery, and read-only ERC/DRC checks.
- `L3_WORKSPACE_WRITE`: scoped writes inside the approved workspace. Default is report outputs under a designated review directory; when the user runs ChatGPT as an independent agent it also covers source writes and self-verification (project tests/build/lint) inside the one narrow root - never installs, git commit/push/history, deletes beyond the task, secrets, or anything outside the root.
- `L4_PRIVILEGED_ROOT`: exact privileged/admin action only, human approval by default.
- `L5_IRREVERSIBLE_EXTERNAL`: destructive, costly, hardware-impacting, or externally irreversible actions, always human approval.

Forbidden by default through the local bridge:

- source edits, KiCad edits, lockfile edits, formatting writes
- deletes, installs, commits, pushes, git history changes
- broad home-directory or whole-drive access
- credential access or secret scanning
- firmware flashing, hardware mutation, ordering fabrication
- network exfiltration or unrelated private data access

Exception: the user may lift the source-edit item by granting the `L3_WORKSPACE_WRITE` independent-agent profile (`CHATGPT_ARCHITECT`). That covers only source writes and self-verification inside the narrow root; every other item above stays forbidden.

Enforcement reality: these levels are policy, not a sandbox. devspace exposes `read_file`, `write_file`, `edit_file`, `grep_files`, `find_files`, `list_directory`, and `run_shell` to any OAuth-authorized app; the file tools are root-scoped but `run_shell` is not, so an authorized ChatGPT app effectively has local-user code execution. The only enforced boundaries are OAuth approval, `allowedRoots` (file tools only), and Stop. Keep the root narrow and secret-free, review diffs before any commit/push, and Stop when done. See `references/router-policy.md` "Enforcement reality".

## Handoff Discipline

When sending a task to ChatGPT, create a compact Task Packet. Prefer paths, goals, constraints, and allowed evidence over pasted large file bodies.

Always include:

- route
- permission level
- workspace path or none
- what to inspect
- what not to inspect
- allowed actions
- forbidden actions
- tool budget and stop condition
- required Action Manifest output

After ChatGPT responds, Codex must:

1. Avoid rereading all context unless necessary.
2. Read only files required for implementation.
3. Classify each recommendation as accepted, rejected, needs verification, or requires user decision.
4. Convert accepted recommendations into a patch plan.
5. Execute source changes locally.
6. Run verification commands.
7. Report files changed, commands run, results, unresolved risks, and whether more ChatGPT review is needed.

Codex must never blindly apply ChatGPT suggestions.

## Completion Checklist

- Bridge state is known: intentionally running or intentionally stopped.
- Exposed workspace is narrow and task-appropriate.
- Permission level is explicit.
- No secrets or broad paths were exposed.
- ChatGPT output, if used, has been locally verified before final claims.
- Any L4/L5 action went through explicit human approval.


