# Optional Hook Design

This is a design note, not an installed automation. Use it when implementing future pre-handoff checks.

## Pre-Handoff Safety Check

Inputs:
- task packet draft
- workspace path
- permission level
- allowed commands
- allowed write targets

Output:
- allow
- block
- require human approval
- normalized warning list

## Path Rules

Block:
- whole drives such as `C:\`, `D:\`, `E:\`
- home roots such as `C:\Users\<user>`
- `.ssh`, browser profile directories, credential stores
- `.env`, `auth.json`, `id_rsa`, `*.pem`
- broad team-document roots without a narrower project subfolder

Allow:
- one explicit repository or project directory
- one explicit artifact file
- designated report output directory such as `docs/chatgpt/`

## Command Rules

Allow at L2 only when scoped to the workspace and non-mutating:
- `rg`
- directory listing
- `git status`
- `git diff --stat`
- static analysis commands
- dry-run commands
- test discovery such as `pytest --collect-only`
- ERC/DRC/check commands that do not mutate source files
- version checks

Block or escalate:
- install commands
- delete commands
- formatters that write files
- commands that modify lockfiles or generated source
- git commit, push, reset, checkout, rebase, clean
- firmware flashing
- hardware mutation
- credential reads
- arbitrary network upload/download
- admin/root shells

## Permission Gate Pseudocode

```text
if permission in L4,L5:
    require human approval
if path is broad or secret-like:
    block
if command mutates filesystem, git state, hardware, network, or credentials:
    require human approval or block
if permission == L3 and write target not under designated report directory:
    require human approval
if permission <= L2 and packet requests writes:
    block
else:
    allow with warnings
```

## Escalation Packet Requirements

For L4 or L5, require:
- exact command/action
- why privilege is needed
- expected output
- affected paths/devices
- rollback plan
- risk level
- non-privileged fallback

Do not approve generic privileged shells, unrestricted admin terminals, or broad root sessions.


