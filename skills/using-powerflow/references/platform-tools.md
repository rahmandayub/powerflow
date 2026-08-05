# Platform Tool Mappings

Powerflow text uses abstract operations ("spawn a subagent", "search the codebase"). Map them with this table. If your platform is missing, use its native equivalents.

## Subagents, Search, Shell

| Platform | Subagent | Search | Shell |
|---|---|---|---|
| Zed | `spawn_agent` | `grep` / `find_path` | `terminal` |
| Claude Code | `Task` | `Grep` / `Glob` | `Bash` |
| Codex | `spawn_agent` (needs `multi_agent = true` in `~/.codex/config.toml`) | `multisearch` | shell tool |
| OpenCode (Go) | `agent` | `grep` / `glob` | `bash` |
| Kilo | `task` | `Grep` / `Glob` | `bash` |
| Antigravity | `invoke_subagent` | `search_for_files` | shell tool |
| Cursor | agent delegation | `Grep` / `Glob` | shell tool |

## Notes

- **Git operations**: all platforms via their shell tool (branch, checkout, merge, commit, log, reset, stash).
- **Task tracking**: if the platform has a todo tool, use it; otherwise keep the task list in `summary.md`.
