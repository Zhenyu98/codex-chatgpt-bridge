---
name: codex-chatgpt-bridge
description: Use when Codex must decide whether to execute locally, use subagents, or hand off reasoning, review, visual analysis, or scoped local bridge inspection to ChatGPT through Chrome; especially for large-context reviews, hardware go/no-go, paper/code critique, complex bugs, and local bridge permission boundaries.
---

# Codex ChatGPT Bridge

## Overview

Use this skill as the routing policy for Codex, ChatGPT, local bridge, and Chrome.

Core principle: **Codex is the execution owner. ChatGPT is the reasoning and review partner. local bridge is a scoped local access bridge. Chrome is the message transport.**

Default posture:
- Codex owns writes, tests, builds, git, verification, and final reporting.
- ChatGPT owns high-token reasoning, broad review, visual/PDF/screenshot analysis, and independent go/no-go critique.
- local bridge defaults to read-only and narrow workspace access.
- ChatGPT recommendations are advice until Codex verifies them locally.

For service start/stop/status, OAuth setup, Cloudflare tunnels, and ChatGPT UI configuration, use the `codex-chatgpt-bridge` skill. This skill decides **when and how** to route work.

## Operating Modes

Select one mode before routing.
- If the user asks for the "ChatGPT plans / Codex executes" workflow, a long continuous build, or to avoid Codex usage limits, use `CHATGPT_ARCHITECT`.
- Else if the user explicitly asks to save tokens, use `TOKEN_SAVING`.
- Otherwise use `NORMAL`.

### NORMAL

Goal: make ChatGPT a strong collaborator while Codex remains actively involved.

Use when:
- the user wants careful collaboration rather than minimum Codex token use
- the task needs implementation, verification, and iterative judgment
- Codex needs enough local context to avoid bad handoffs
- ChatGPT is useful as a reviewer, planner, second opinion, or high-depth reasoning subagent

Behavior:
- Codex reads the minimum local context needed to frame the task well.
- ChatGPT receives compact packets, selected evidence, or scoped local bridge access when useful.
- Codex can ask ChatGPT for plans, alternative designs, risk review, go/no-go opinions, and critique.
- Codex owns writes, tests, builds, git operations, final verification, and the final answer.
- Use Codex subagents for independent breadth; use ChatGPT for deep synthesis.

### TOKEN_SAVING

Goal: spend as few Codex tokens as practical while preserving safety.

Use when:
- the user asks for "省 token", "token-saving", "少读上下文", or similar
- large context is the main cost
- the task is review-heavy, synthesis-heavy, visual/PDF-heavy, or architecture-heavy
- ChatGPT can inspect the local project directly through a narrow read-only or diagnostic bridge

Behavior:
- Codex acts as orchestrator: classify, start/stop bridge, send task packets, ingest manifests, execute accepted actions, verify.
- ChatGPT becomes the default reader/reasoner for safe non-mutating context work.
- Codex avoids reading and summarizing large files unless needed for implementation or verification.
- Prefer `ROUTE_CHATGPT_LOCAL_READ`, `ROUTE_CHATGPT_REASONING`, or `ROUTE_CHATGPT_VISION` for non-sensitive analysis.
- Keep local-only in Codex: writes, tests/builds, git, source patches, secret handling, destructive actions, privileged commands, hardware-impacting actions, and final claims.
- If ChatGPT output is vague, unsupported, or loops on tools, Codex asks for a bounded Action Manifest instead of expanding local reading.

### CHATGPT_ARCHITECT

Goal: sustain a long, continuous build on minimal Codex quota by moving every high-cost "thinking" step (spec, UI/data design, task decomposition, prompt authoring, review) to ChatGPT, and reducing Codex to executing one small task at a time. This is the planning-inverted extreme of `TOKEN_SAVING`: in `NORMAL`/`TOKEN_SAVING` Codex still owns planning; here ChatGPT owns planning and Codex owns only execution plus local verification.

Use when:
- the user wants a long Codex session without hitting usage/quota limits
- the user asks for the "ChatGPT as architect/manager, Codex as programmer" loop
- the work is a whole feature/app/game that benefits from spec -> design -> task breakdown before any code

Roles:
- ChatGPT = architect + manager: writes the spec, UI/data design, breaks work into small ordered tasks (Task1, Task2, ...), authors the exact execution prompt for each task, reviews each result, and proposes the next task or a fix. In the independent-agent profile it also implements tasks (see Execution profiles).
- Codex = executor or integrator, depending on profile: either implements one task per turn, or reviews ChatGPT's diffs and integrates. Either way Codex runs the deterministic checks and owns git plus the final claim.
- Human = product owner: sets direction, answers ChatGPT's open product questions, grants the L3 write scope when used, and holds the L4-L5 / irreversible approval gates.

#### Execution profiles

Pick one before the build. Both run the same Architect Loop; they differ only in who writes source.

- Advice profile (default): ChatGPT plans and reviews only; Codex writes every source change and verifies. ChatGPT's plan, task graph, and acceptance criteria are advice, not ground truth. Bridge stays `L1_READ_ONLY`/`L2_DIAGNOSTIC_COMMANDS`.
- Independent-agent profile (`L3_WORKSPACE_WRITE`, opt-in by the user): ChatGPT is treated as a peer coding agent. It may write source files inside the one narrow approved workspace and run the project's own non-privileged tests/build/lint to self-verify, then hand back a diff. Codex becomes the integrator: it reviews the diff, runs an independent verification pass, and owns git plus the final claim. Use when the user explicitly grants L3 or says to treat ChatGPT as an independent agent.

Even in the independent-agent profile, granting L3 does NOT grant these - they stay gated: writing outside the approved root, reading secrets/credentials, installing or upgrading dependencies, deleting files beyond the current task, any git commit/push/history change, network upload, and every L4/L5 action. ChatGPT writes and self-checks inside the task's files; it does not commit, push, release, or reach outside the root.

Non-negotiable guardrails (both profiles):
- Ground the plan before decomposing: ChatGPT reads the repo through the bridge, or Codex supplies a compact repo map. An ungrounded plan references paths/APIs that do not exist.
- Feasibility gate: before grinding through tasks, Codex does one fast pass over the plan against the real repo (paths exist, APIs real, dependencies ordered) and returns defects to ChatGPT instead of building a broken decomposition.
- Do not over-decompose: a few short files or one deterministic edit -> Codex just does it via `ROUTE_CODEX_EXECUTE`.
- One task at a time: if scope balloons, re-decompose into new tasks rather than absorbing them inline.
- A task is done only when its acceptance criteria pass an independent local check - Codex's verification in the advice profile, Codex's integrator pass in the independent-agent profile - never on ChatGPT's say-so alone. The loop pauses at L4-L5 and at any verification failure.
- Independent-agent writes are real and only loosely contained: the bridge exposes `write_file`/`edit_file` (root-scoped) and `run_shell` (NOT root-scoped - effectively local-user execution). The permission ladder is policy, not a sandbox (see Enforcement reality). So narrow `allowedRoots`, keep secrets out of the root, and rely on diff review plus controller `Off` discipline - not on the bridge - to contain ChatGPT.

## Routing Quick Reference

| Route | Use When | Owner | Default Permission |
|---|---|---|---|
| `ROUTE_CODEX_EXECUTE` | File edits, refactors, tests, builds, scripts, docs updates, git diff, deterministic verification | Codex | local Codex tools |
| `ROUTE_CODEX_SUBAGENTS` | Independent review axes can run in parallel and return compact findings | Codex main agent | read-only unless planned |
| `ROUTE_CHATGPT_REASONING` | High-depth conceptual, architectural, hardware, paper, novelty, experiment, or go/no-go reasoning | ChatGPT review; Codex executes | `L0_NO_TOOL` unless inspection needed |
| `ROUTE_CHATGPT_PLAN` | ChatGPT produces the spec, UI/data design, ordered task decomposition, or the per-task Codex execution prompt (core of `CHATGPT_ARCHITECT`) | ChatGPT plans; Codex feasibility-checks, executes, and verifies | `L0_NO_TOOL`, or `L1_READ_ONLY`/`L2_DIAGNOSTIC_COMMANDS` to ground the plan in the repo |
| `ROUTE_CHATGPT_LOCAL_READ` | ChatGPT should inspect a large local project directly to save Codex tokens | ChatGPT reviews through the local bridge; Codex executes | `L1_READ_ONLY` or `L2_DIAGNOSTIC_COMMANDS` |
| `ROUTE_CHATGPT_VISION` | PDF schematic, PCB screenshot, UI screenshot, plot, diagram, wiring photo, image critique | ChatGPT visual review; Codex executes | artifact-only or scoped local bridge read |
| `ROUTE_HUMAN_APPROVAL` | Privileged, destructive, irreversible, external, secret-bearing, or hardware-impacting actions | Human decides | explicit approval |

In `NORMAL`, prefer ChatGPT for depth, subagents for breadth, and Codex for execution.

In `TOKEN_SAVING`, prefer ChatGPT for all safe non-mutating reading/reasoning/review by default, and let Codex focus on orchestration, edits, verification, and reporting.

In `CHATGPT_ARCHITECT`, default to `ROUTE_CHATGPT_PLAN` for spec/design/decomposition/prompt-authoring and `ROUTE_CHATGPT_REASONING` for per-task review, while every code change runs as a single-task `ROUTE_CODEX_EXECUTE`. Codex plans nothing beyond a feasibility check; it executes and verifies.

## Permission Levels

Always choose the lowest sufficient level and include it in the ChatGPT Task Packet.

| Level | Meaning | Allowed | Approval |
|---|---|---|---|
| `L0_NO_TOOL` | Prompt-only ChatGPT reasoning | Conceptual advice, architecture, planning, writing | Codex may auto-route |
| `L1_READ_ONLY` | local bridge read-only project inspection | Narrow workspace open/list/read/search | Codex may auto-approve if root is narrow and no secrets/broad dirs |
| `L2_DIAGNOSTIC_COMMANDS` | local bridge non-mutating shell diagnostics | `rg`, directory listing, `git status`, `git diff --stat`, static analysis, dry-runs, test discovery, ERC/DRC checks that do not mutate source | Codex may auto-approve only if scoped, non-mutating, and credential-safe |
| `L3_WORKSPACE_WRITE` | local bridge writes inside the approved workspace | Default: report/handoff outputs under `docs/chatgpt/`. When the user runs ChatGPT as an independent agent: source files inside the one narrow root plus running the project's own non-privileged tests/build/lint to self-verify. Excludes installs, git commit/push/history, deletes beyond the task, secrets, and anything outside the root | Codex may auto-approve only the report-only sub-case; source-write scope requires an explicit user grant |
| `L4_PRIVILEGED_ROOT` | Privileged/root/admin requests | Exact approved command only | Human approval by default; no generic admin shell |
| `L5_IRREVERSIBLE_EXTERNAL` | Destructive, external, costly, hardware-impacting actions | None by default | Always human approval; Codex cannot auto-approve |

Forbidden by default through the local bridge:
- Source edits, KiCad edits, lockfile edits, formatting writes
- Deletes, installs, commits, pushes, git history changes
- Broad home-directory or whole-drive access
- Credential access or secret scanning
- Firmware flashing, hardware mutation, ordering fabrication
- Network exfiltration or sending unrelated private data

Source edits are forbidden by default, but the user may lift that one item by granting the `L3_WORKSPACE_WRITE` independent-agent profile (see `CHATGPT_ARCHITECT`). That grant covers only source writes and self-verification inside the narrow approved root; every other item above stays forbidden - installs, deletes beyond the task, commits/pushes/history, secrets, broad paths, hardware, and network exfiltration are not part of an L3 grant.

### Enforcement reality (read before granting writes)

These levels are policy Codex instructs ChatGPT to honor; the devspace bridge does not enforce them per level. Once the ChatGPT app is OAuth-authorized it can call every tool the bridge exposes: `read_file`, `write_file`, `edit_file`, `grep_files`, `find_files`, `list_directory`, and `run_shell`. The only technically enforced boundaries are:
- OAuth + Owner-password approval - an all-or-nothing gate to connect at all.
- `allowedRoots` path-scoping - confines the file tools (`read_file`/`write_file`/`edit_file` and path args) to the approved root.
- Stopping the bridge - removes reachability.

`run_shell` is NOT confined by `allowedRoots`: it runs with cwd at the root, but the command itself has full local-user reach (it can `cd` out, `git push`, install packages, curl the network, or read files elsewhere). So an authorized ChatGPT app effectively holds local-user code execution.

Consequences:
- Granting `L3` unlocks no new capability - authorization already did. `L3` is the policy decision to let ChatGPT actually write/run; `L1`/`L2` are you asking it not to. The "forbidden even at L3" list is enforced only by ChatGPT's compliance plus root-scoping of the file tools; `run_shell` can bypass it. It is a discipline, not a sandbox.
- So when treating ChatGPT as an independent agent, the real protections are: a narrow root with no secrets inside it, Codex/human review of the diff before any commit/push/release, prompt-injection hygiene on whatever ChatGPT reads, and controller `Off` discipline. For higher assurance run the bridge under a least-privilege OS account or a disposable VM/container, and only authorize the app for a workspace where local-user execution is acceptable.

## Route Selection

1. Choose `NORMAL`, `TOKEN_SAVING`, or `CHATGPT_ARCHITECT`. In `CHATGPT_ARCHITECT`, follow the Architect Loop: ChatGPT plans and reviews, Codex executes one task at a time, and the rest of these steps apply only inside each single task.
2. Classify the task before reading large context.
3. If the task is a small deterministic edit, use `ROUTE_CODEX_EXECUTE` in `NORMAL`; in `TOKEN_SAVING`, still let Codex execute but avoid broad local orientation.
4. If the task has independent review axes, use `ROUTE_CODEX_SUBAGENTS` in `NORMAL`; in `TOKEN_SAVING`, prefer one ChatGPT review if broad synthesis is cheaper than many subagents.
5. If the task needs deep synthesis, high-cost judgment, or the user asks for ChatGPT/Pro/high-intelligence review, use `ROUTE_CHATGPT_REASONING`.
6. If Codex would need to read more than about five large files, long logs, PDFs, screenshots, or broad project context, prefer `ROUTE_CHATGPT_LOCAL_READ` or `ROUTE_CHATGPT_VISION`.
7. If any requested action crosses L3-L5 boundaries, route to `ROUTE_HUMAN_APPROVAL`.
8. After ChatGPT responds, Codex reads only implementation-relevant files, applies accepted changes, verifies, and reports evidence.

Use the existing Chrome skill for transport when sending packets or retrieving replies. Use local bridge only after confirming the workspace root is narrow and appropriate.

## ChatGPT Task Packet

Generate compact packets. Do not include large file contents when ChatGPT can inspect through the local bridge.
Include a tool budget whenever local bridge or other tools are allowed. ChatGPT must stop tool use and answer once the budget is reached or enough evidence has been gathered.

```markdown
# ChatGPT Task Packet
## Task ID
<short-id>
## Route
CHATGPT_REASONING | CHATGPT_LOCAL_READ | CHATGPT_VISION
## Permission Level
L0_NO_TOOL | L1_READ_ONLY | L2_DIAGNOSTIC_COMMANDS | L3_WORKSPACE_WRITE | L4_PRIVILEGED_ROOT | L5_IRREVERSIBLE_EXTERNAL
## Goal
<one sentence>
## Background
<minimal context>
## Workspace
<path or none>
## What to inspect
- <file/path/category>
- <report/log/artifact>
## What not to inspect
- secrets
- auth files
- broad home directories
- unrelated private folders
## Allowed actions
- <allowed action>
- <allowed command class>
## Tool budget
- Maximum local bridge tool calls: <number, usually 3-8>
- Stop condition: after opening the workspace, collecting the requested evidence, or hitting one failed/repeated tool call, stop using tools and return the Action Manifest
## Forbidden actions
- write files unless approved
- delete files
- format files
- install dependencies
- commit/push
- access broad directories
- read secrets
- flash hardware
- destructive commands
## Exact request to ChatGPT
<precise question>
## Required output format
1. Final verdict
2. Evidence inspected
3. Must-fix issues
4. Should-fix issues
5. Acceptable risks
6. Missing evidence
7. Recommended Codex actions
8. Suggested verification commands
9. Permission escalation requests, if any
```

## ChatGPT Action Manifest

Require this response shape so Codex can ingest it without re-reading everything.

````markdown
# ChatGPT Action Manifest
## Final Verdict
<go/no-go/needs-more-evidence>
## Evidence Inspected
- <file/report/command/artifact>
## Must-Fix Issues
1. <issue>
   - Evidence:
   - Risk:
   - Recommended Codex action:
   - Verification:
## Should-Fix Issues
1. <issue>
   - Evidence:
   - Risk:
   - Recommended Codex action:
   - Verification:
## Acceptable Risks
- <risk and rationale>
## Missing Evidence
- <exact missing evidence>
## Recommended Codex Actions
1. <action>
2. <action>
## Suggested Verification Commands
```bash
<commands>
```
## Permission Escalation Requests
If none, write: None.

If needed:
- Requested level:
- Exact command/action:
- Reason:
- Expected output:
- Affected paths/devices:
- Risk:
- Rollback:
- Non-privileged fallback:
````

## Ingestion Rules

After receiving ChatGPT's Action Manifest:

1. Avoid re-reading all context unless necessary.
2. Read only files required for implementation or verification.
3. Classify each recommendation as `accepted`, `rejected`, `needs verification`, or `requires user decision`.
4. Reject or defer anything unsupported by evidence, outside the approved permission level, or inconsistent with local facts.
5. Convert accepted recommendations into a patch plan.
6. Execute source changes locally with Codex tools.
7. Run verification commands locally.
8. Report files changed, commands run, results, unresolved risks, and whether another ChatGPT review is needed.

Never blindly apply ChatGPT suggestions.

## ChatGPT-Authored Codex Execution Prompt

This is the inverse of the ChatGPT Task Packet: in `CHATGPT_ARCHITECT` mode ChatGPT authors one of these per task, and Codex treats it as a scoped work order. ChatGPT writes it; Codex sanity-checks it against the repo, executes only this task, and replies with a compact result. Ask ChatGPT to emit exactly this shape so Codex spends no tokens reformatting it.

```markdown
# Codex Execution Prompt
## Task ID
<projectN-taskM>
## Single Goal
<one concrete outcome; if it needs the word "and", split it into two tasks>
## Context / Spec
<only the spec slice this task needs, not the whole project>
## Files In Scope
- <path to create/edit>
## Out Of Scope
- <what not to touch>
## Constraints
- <language/style/dependency/perf constraints>
## Acceptance Criteria (proposed)
- <observable, checkable conditions; Codex turns these into real tests/commands>
## Verification Commands (proposed)
- <commands Codex should run; Codex may add or replace them>
## Done Means
- diff applied, listed checks pass locally, compact result reported
```

Codex's reply after executing stays compact so the next ChatGPT review is cheap: files changed, commands run with results, any deviation from the prompt, and whether the task's acceptance criteria pass locally. If they do not pass, Codex reports the failure rather than declaring done.

## Architect Loop

Run this loop in `CHATGPT_ARCHITECT` mode:

1. Frame (human): one-line direction, hard constraints, and which actions need approval.
2. Plan (ChatGPT, `ROUTE_CHATGPT_PLAN`): spec -> UI/data design -> ordered small tasks. Ground it via the `L1_READ_ONLY`/`L2_DIAGNOSTIC_COMMANDS` bridge or a Codex-supplied repo map.
3. Feasibility (Codex): fast pass over the plan against the real repo; return missing dependencies, wrong paths, or unorderable tasks to ChatGPT; ChatGPT revises before any code is written.
4. Per task, repeat:
   a. Prompt (ChatGPT): author the Codex Execution Prompt for the next single task.
   b. Execute (Codex, `ROUTE_CODEX_EXECUTE`): implement only that task, run local checks, report a compact result.
   c. Review (ChatGPT, `ROUTE_CHATGPT_REASONING`): review the diff/result; accept, or return a fix prompt.
   d. Codex applies the fix; loop until the task's acceptance criteria pass locally.
5. Gate (human): pause at L4-L5, any irreversible/external/release action, and any write scope the user has not granted (if L3 was not granted, ChatGPT does not write - Codex does).

Keep each Codex turn to one task. Codex's local verification, not ChatGPT's say-so, marks a task done. If ChatGPT stalls or loops, fall back to `NORMAL` and let Codex plan the next step directly.

## Tool Loop Control

When sending ChatGPT a local bridge task, prevent tool-call loops:

- Set a maximum number of local bridge tool calls in the packet.
- Prefer one `open_workspace`, one inventory/search command, and one or two targeted reads/diagnostics.
- Tell ChatGPT to stop tool use after any repeated failure, repeated workspace open, repeated app card, or missing optional evidence.
- If ChatGPT keeps calling tools without producing text, Codex should interrupt with: "Stop calling tools. Based on evidence already gathered, return the Action Manifest now. Put missing items under Missing Evidence."
- Treat a successful local bridge session plus missing final Manifest as a partial E2E success and a router prompt issue, not a local bridge connectivity failure.

## Cost-Aware Routing

`TOKEN_SAVING` and `CHATGPT_ARCHITECT` only pay off if the split respects what each surface is cheap at. "Efficient" and "token-saving" pull opposite ways for execution work, so route by marginal cost, not by habit.

The cost asymmetry:
- A ChatGPT bridge tool call is slow and brittle (Chrome -> tunnel -> Worker -> devspace round-trip, ~300s shell cap, can stall) but spends little Codex quota.
- A Codex local op is fast and reliable but spends Codex quota.

One-line heuristic: route a unit of work to ChatGPT only when the Codex tokens it would otherwise cost greatly exceed one bridge round-trip plus its reliability risk. Otherwise keep it in Codex.

Route by unit of work:
- Dense reading / planning / synthesis / review / vision -> ChatGPT. One ChatGPT turn over a big input replaces the most Codex tokens; this is the high-leverage handoff.
- Many small mechanical ops (apply patch, run tests, rename, iterate) -> Codex. Cheap per-op locally; routing each through the bridge is the worst case - slow, brittle, and it barely saves Codex tokens.
- Interactive / long-running / streaming / >300s / stdin -> Codex only (capability wall).
- git commit/push, releases, secrets, L4/L5 -> Codex or human (trust boundary, not capability).

Batch the handoff - never tool-loop:
- One dense ChatGPT turn beats a chatty back-and-forth. If ChatGPT must see eight files, it reads them as one batch in its own turn then answers, or Codex ships one compact bundle - not "read file, now the next, now edit line 3" over the bridge.
- The chatty path wastes both sides: it burns ChatGPT context and latency while barely saving Codex quota. This is the main efficiency leak; the Tool Loop Control budget exists to stop it.
- Keep one ChatGPT thread per project so it retains repo context across tasks; send deltas, not full re-reads.

ChatGPT is Codex's subagent pool:
- When Codex's plan calls for subagents, the subagents themselves are Codex quota: N Codex subagents cost about N times the context - the exact bottleneck this setup fights. So by default, fill those agent roles with ChatGPT instead of forking Codex subagents; the subagent work then costs ChatGPT, not Codex. Codex stays the single orchestrator that dispatches the roles, integrates their outputs, and verifies.
- ChatGPT subagents are not limited to review. Read-only roles (research, review, reasoning, vision) need only `L1_READ_ONLY`/`L2_DIAGNOSTIC_COMMANDS`; implementing roles can write/edit/run over the bridge under the independent-agent `L3` profile. Give each role the lowest level it needs.
- How to run them: one role = one ChatGPT task packet (one dense turn). For genuine parallelism run one ChatGPT thread per concurrent role (multiple threads/tabs - manual, but every one is off Codex's quota). Collapsing several read-only roles into a single multi-axis turn is cheaper still when one context can hold them.
- What stays with Codex the orchestrator, never delegated: merging subagent outputs, the authoritative verification pass, git/commit/push, final claims, and any interactive / long-running / >300s execution a bridge subagent cannot perform.
- Keep a Codex subagent only as the exception - when a role needs fast local concurrency or a tight execute/iterate loop the bridge serves poorly. In `NORMAL`, choose per cost/capability fit; in `TOKEN_SAVING` and `CHATGPT_ARCHITECT`, ChatGPT subagents are the default.

Make outputs ready-to-apply:
- ChatGPT should emit what Codex can apply with near-zero conversion tokens: full-file contents or unified diffs, exact commands, exact paths. Codex applies and verifies; it does not re-derive. Re-reading context ChatGPT already read, or reformatting its output, is pure waste.

Verification is cheap and stays local:
- Running tests/build is token-cheap in Codex (the output is just pass/fail) and is also the trust anchor. Never spend ChatGPT tokens reasoning about whether something passed - run it in Codex.

Two configs on the dial:
- Max token-saving: independent-agent profile (L3) for bridge-friendly tasks - ChatGPT reads, writes, and self-checks over the bridge; Codex does only a cheap integrator pass (read diff + run tests). Lowest Codex quota, highest latency/brittleness/trust surface.
- Max reliability: advice profile - ChatGPT plans/reviews, Codex writes. More Codex quota, fastest and safest. Default here; shift toward independent-agent only when quota is the binding constraint, the task is bridge-friendly, and the root is narrow.

## Token-Saving Policy

Use ChatGPT plus local bridge instead of Codex reading large context when:
- More than five files must be inspected for conceptual review.
- Files are large, generated, verbose, or log-like.
- PDFs, images, screenshots, plots, schematics, or PCB renders are involved.
- The task is hardware go/no-go, fabrication readiness, paper-level critique, architecture review, or long-context synthesis.
- Codex would otherwise spawn many subagents only to understand context.
- The selected operating mode is `TOKEN_SAVING` and the requested action is safe, non-mutating, and non-secret.

Use Codex directly when:
- Relevant files are few and short.
- The task is a small edit or mechanical refactor.
- A deterministic verification command resolves the question.
- The work requires writes, tests, builds, git, or final artifact creation.

Use subagents when:
- Work is parallel and locally verifiable.
- Independent modules or review axes can produce compact findings.
- The total cost is lower than one large ChatGPT review.

Use ChatGPT instead of subagents when:
- The main cost is synthesis, judgment, or visual reasoning.
- The desired output is a go/no-go review rather than patches.
- Codex's plan calls for subagents at all and saving quota matters: fill the agent roles with ChatGPT rather than forking Codex subagents (each is N times the context), keeping Codex as the orchestrator that integrates and verifies. In `TOKEN_SAVING`/`CHATGPT_ARCHITECT` this is the default; see Cost-Aware Routing, "ChatGPT is Codex's subagent pool".

## Security Rules

Never send or request:
- `.env`, `auth.json`, API keys, SSH keys, `id_rsa`, `*.pem`
- Browser cookies, tokens, OAuth secrets, credential stores
- Private medical, identity, banking, or unrelated personal files
- Broad `C:\Users\<user>` directories, full drives, or broad team-document roots

local bridge workspace must be narrow:
- Prefer one repo, one project directory, one explicit task.
- Avoid home directories, whole drives, persistent tunnels without a task, and unrelated private folders.

Before any handoff, state the allowed root, permission level, and forbidden areas in the packet.

## Hardware-Specific Routing

For KiCad and hardware synchronizer projects:

Codex handles:
- Local source inspection when narrow and small
- Netlist parsing, ERC/DRC command execution, BOM sync
- Documentation updates, patch implementation, verification, git diff

Codex subagents handle independent review axes:
- Power input and protection
- MCU clock/reset/boot/USB
- Trigger outputs
- Livox/GPS/IMU interfaces
- BOM/release consistency
- Layout readiness

ChatGPT handles:
- Schematic PDF visual review
- PCB screenshot visual review
- High-risk electrical go/no-go
- Connector/electrical architecture critique
- Final fabrication readiness review
- Large-context independent review through the local bridge

Before PCB fabrication, require Codex local checks, Codex subagent review, ChatGPT independent review, and user approval.

## Debugging Routing

For hard bugs:

1. Codex reproduces the bug.
2. Codex inspects logs and relevant code.
3. Codex attempts one focused fix with local verification.
4. If unresolved, Codex uses subagents for independent hypotheses.
5. If still unresolved or conceptually unclear, Codex sends a ChatGPT bug packet.
6. ChatGPT returns hypotheses and priority order.
7. Codex verifies hypotheses locally before applying fixes.

## Human Approval Packet

Before L4 or L5, or any sensitive L3 write, ask the user with:

- Exact action
- Exact path or command
- Why it is needed
- What could go wrong
- Rollback plan
- Fallback option
- Whether approval is one-time or reusable for exact fixed arguments only

Never request a generic privileged shell, unrestricted admin PowerShell, or broad root session.

## References

- Read `references/examples.md` when a concrete packet example would help.
- Read `references/hook-design.md` when designing pre-handoff safety checks or future automation.
- Read `references/agents-snippet.md` when a project wants an optional `AGENTS.md` policy snippet without binding this user-level skill to one repository.

## Common Mistakes

| Mistake | Correction |
|---|---|
| Sending large code dumps to ChatGPT | Send paths and a compact task packet; let local bridge inspect narrow roots |
| Letting ChatGPT edit source directly | Ask for an Action Manifest; Codex applies and verifies |
| Treating local bridge as a general remote shell | Use the permission ladder and narrow root |
| Auto-approving installs or deletes | Route to human approval |
| Trusting ChatGPT's verdict without local evidence | Verify with files, tests, builds, generated artifacts, or user confirmation |
| Forgetting tunnel state | Use controller `Status`, `On`, `Off`, and the single-transaction `Reboot` lifecycle |
| Running ChatGPT's task graph unchecked in `CHATGPT_ARCHITECT` | Codex feasibility-checks the plan against the repo, then verifies each task locally before marking it done |
| Over-decomposing trivial work into a plan/review loop | For a few short files or one deterministic edit, Codex executes directly via `ROUTE_CODEX_EXECUTE` |

