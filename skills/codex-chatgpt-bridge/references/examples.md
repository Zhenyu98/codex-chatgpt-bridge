# Router Examples

Use these examples as starting points. Keep packets compact and replace paths, commands, and artifacts with the current task details.

## KiCad Hardware Review Packet

```markdown
# ChatGPT Task Packet
## Task ID
kicad-sync-review-001
## Route
CHATGPT_LOCAL_READ
## Permission Level
L2_DIAGNOSTIC_COMMANDS
## Goal
Review the synchronizer hardware project for fabrication-blocking schematic risks.
## Background
Codex will own all edits and verification. ChatGPT should perform an independent review and return an Action Manifest only.
## Workspace
D:\projects\hardware-sync-board
## What to inspect
- KiCad schematic/project files
- exported PDF schematic if present
- ERC output if available
- BOM/release notes if present
## What not to inspect
- secrets
- auth files
- broad home directories
- unrelated team folders
## Allowed actions
- list/read/search files in this workspace
- run non-mutating diagnostics such as `git status`, `git diff --stat`, `kicad-cli sch erc` if available
## Forbidden actions
- write files
- delete files
- format files
- install dependencies
- commit/push
- access broad directories
- read secrets
- flash hardware
- destructive commands
## Exact request to ChatGPT
Identify must-fix, should-fix, acceptable risks, missing evidence, and recommended Codex verification before fabrication.
## Required output format
Return a ChatGPT Action Manifest.
```

## Radar Paper/Code Review Packet

```markdown
# ChatGPT Task Packet
## Task ID
radar-method-review-001
## Route
CHATGPT_LOCAL_READ
## Permission Level
L1_READ_ONLY
## Goal
Assess whether the paper code and writeup support the claimed method contribution.
## Background
Codex will verify exact metrics and run scripts locally. ChatGPT should focus on evidence quality, claim boundaries, and missing experiments.
## Workspace
<paper repo path>
## What to inspect
- README or project notes
- experiment scripts
- result summaries
- paper draft sections if present
## What not to inspect
- secrets
- private unrelated papers
- broad document roots
## Allowed actions
- list/read/search files in the scoped project
## Forbidden actions
- write files
- run commands
- change git state
- access credentials
## Exact request to ChatGPT
Return a claim-boundary review: which claims are supported, weak, or unsupported, and what Codex should verify next.
## Required output format
Return a ChatGPT Action Manifest.
```

## Complex Bug Packet

```markdown
# ChatGPT Task Packet
## Task ID
bug-hypothesis-001
## Route
CHATGPT_REASONING
## Permission Level
L0_NO_TOOL
## Goal
Prioritize hypotheses for a bug Codex reproduced but has not fixed.
## Background
Observed failure: <short failure>. Codex already tried <one focused fix> and it failed because <evidence>.
## Workspace
none
## What to inspect
- included log excerpt
- included stack trace
- included architecture summary
## What not to inspect
- local files
- secrets
## Allowed actions
- reason over the supplied evidence
## Forbidden actions
- request broad local access
- propose unverified source edits as final
## Exact request to ChatGPT
Rank likely root causes, define the next local checks Codex should run, and identify what evidence would falsify each hypothesis.
## Required output format
Return a ChatGPT Action Manifest.
```

## Image/PDF Visual Review Packet

```markdown
# ChatGPT Task Packet
## Task ID
visual-review-001
## Route
CHATGPT_VISION
## Permission Level
L0_NO_TOOL
## Goal
Review the attached schematic PDF or screenshot for visual/electrical risks.
## Background
Codex will map findings back to source files and verify with local checks.
## Workspace
none unless local bridge inspection is separately authorized
## What to inspect
- attached PDF/image/screenshot only
## What not to inspect
- local filesystem
- secrets
## Allowed actions
- visual analysis of the provided artifact
## Forbidden actions
- infer unprovided source facts as certain
- request write access
## Exact request to ChatGPT
Classify findings as must-fix, should-fix, acceptable risks, or missing evidence. Avoid overclaiming from visual-only evidence.
## Required output format
Return a ChatGPT Action Manifest.
```

## ChatGPT Architect Workflow (CHATGPT_ARCHITECT)

Two artifacts drive the loop: the planning kickoff Codex sends to ChatGPT, and the per-task execution prompt ChatGPT sends back. Human gives direction only.

### Step A - Codex asks ChatGPT to plan

```markdown
# ChatGPT Task Packet
## Task ID
spaceshooter-plan-001
## Route
CHATGPT_PLAN
## Permission Level
L1_READ_ONLY
## Goal
Plan a single-file JavaScript space-shooter so Codex can build it one task at a time.
## Background
Human direction: "WASD move, space to shoot, enemies in waves, score, particle hits, runs by opening index.html." Codex owns all code, runs, and verification.
## Workspace
<game repo path>
## What to inspect
- existing files, if any (AGENTS.md, PROMPT.md, index.html)
## Allowed actions
- list/read/search the scoped repo to ground the plan
## Tool budget
- Maximum bridge tool calls: 4; then return the plan
## Exact request to ChatGPT
Produce: (1) a compact spec, (2) an ordered task list of small tasks, (3) for Task1 only, a Codex Execution Prompt in the required format. Keep each task to one concrete outcome.
## Required output format
Spec, then ordered task list, then one Codex Execution Prompt for Task1.
```

### Step B - ChatGPT returns a Codex Execution Prompt for one task

```markdown
# Codex Execution Prompt
## Task ID
spaceshooter-task1
## Single Goal
Render a full-window canvas with a player ship that moves on WASD.
## Context / Spec
Single file index.html, no build step, no dependencies. Game loop via requestAnimationFrame.
## Files In Scope
- index.html
## Out Of Scope
- enemies, shooting, score, particles (later tasks)
## Constraints
- vanilla JS, one file, runs by opening index.html
## Acceptance Criteria (proposed)
- canvas fills the window; ship visible; WASD moves it; no console errors
## Verification Commands (proposed)
- open index.html and confirm movement (Codex may script a headless check instead)
## Done Means
- diff applied, checks pass locally, compact result reported
```

Codex then implements Task1 only, verifies locally, reports a compact result, and ChatGPT reviews and issues the Task2 prompt. Codex feasibility-checks the task list against the repo before starting, and declines any prompt that bundles more than one goal.

### Profiles

- Advice profile (default): the prompt above runs at `L1_READ_ONLY`/`L2`; ChatGPT plans, Codex writes `index.html` and verifies.
- Independent-agent profile (user grants `L3_WORKSPACE_WRITE`): the same prompt is handed to ChatGPT, which writes `index.html` itself via the bridge (`write_file`/`edit_file`) and self-checks with `run_shell`, then returns the diff. Codex reviews the diff, runs an independent check, and owns git plus the final claim. ChatGPT still does not commit, push, install dependencies, delete beyond the task, touch secrets, or leave the root - and remember those limits are policy, not a bridge sandbox (see router-policy.md "Enforcement reality"), so keep the root narrow and review before any commit.


