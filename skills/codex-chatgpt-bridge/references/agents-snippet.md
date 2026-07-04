# Optional AGENTS.md Snippet

Use this only when a project explicitly wants to adopt the router policy locally.

```markdown
## Codex, ChatGPT, and local bridge Routing

Use the user-level `codex-chatgpt-bridge` skill when a task may benefit from routing between Codex local execution, ChatGPT reasoning/review, local bridge scoped project inspection, or Chrome-based ChatGPT handoff.

Default division of labor:
- Codex owns source edits, tests, builds, git operations, verification, and final execution.
- ChatGPT owns high-token reasoning, broad review, visual/PDF/screenshot analysis, and independent go/no-go critique.
- local bridge defaults to read-only access to this project only.
- ChatGPT recommendations are not final until Codex verifies them locally.

local bridge policy:
- Prefer `L1_READ_ONLY` for project inspection.
- Allow `L2_DIAGNOSTIC_COMMANDS` only for non-mutating diagnostics scoped to this project.
- Require approval for local bridge writes, privileged/admin actions, destructive commands, hardware-impacting actions, external irreversible actions, or access to secrets.
- Never expose `.env`, auth files, API keys, SSH keys, browser cookies, broad home directories, whole drives, or unrelated private folders.

Before fabrication, release, submission, push, or irreversible external action, require Codex local checks plus explicit user approval.
```


