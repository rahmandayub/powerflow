# Platform Tool Mappings

Powerflow text uses abstract operations ("spawn a subagent", "search the codebase"). Map them with this table. If your platform is missing, use its native equivalents.

## Subagents, Search, Shell, User Interaction

| Platform | Subagent | Search | Shell | User Questions / Checkpoints |
|---|---|---|---|---|
| Zed | `spawn_agent` | `grep` / `find_path` | `terminal` | Chat message |
| Claude Code | `Task` | `Grep` / `Glob` | `Bash` | `AskUserAction` / Chat message |
| Codex | `spawn_agent` (needs `multi_agent = true` in `~/.codex/config.toml`) | `multisearch` | shell tool | Chat message |
| OpenCode (Go) | `agent` | `grep` / `glob` | `bash` | Chat message |
| Kilo | `task` | `Grep` / `Glob` | `bash` | Chat message |
| Antigravity | `invoke_subagent` (use `Workspace: inherit`) | `find_by_name` / `grep_search` | `run_command` | `ask_question` modal |
| Cursor | agent delegation | `Grep` / `Glob` | shell tool | Chat message |

## Notes

- **Git operations**: all platforms via their shell tool (branch, checkout, merge, commit, log, reset, stash).
- **Task tracking**: if the platform has a todo tool, use it; otherwise keep the task list in `summary.md`.
- **Subagent Workspaces**: for harnesses supporting workspace isolation (such as Antigravity), use `Workspace: inherit` so subagents can read and persist directly into `.powerflow/` and edit repository files in place.
