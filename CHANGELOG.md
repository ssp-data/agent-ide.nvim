# Changelog

All notable changes to Agent-IDE.nvim are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [semantic versioning](https://semver.org/).

## [Unreleased]

First public version.

### Added

- **Drawer** (`:Agents`, `<leader>aa`): every Claude Code session on the machine, grouped by git repository (sub-folders and worktrees fold into one project), with title, age and live state: input required, running, done, failed, idle, parked. Right-aligned state words such as `permission: Bash`, `done, unread`, `tmux 2.1`. Works for folders without git too.
- **Chat in native buffers**: a prompt buffer to write with your own Vim setup and a read-only markdown transcript; streaming answers; tool calls, thinking and subagents as folds; an answer text object (`ir` / `ar`); prompt history; attach files with `@`; send with `<C-CR>` or `<leader><CR>`.
- **Command menu** on `/` in the prompt: Claude's commands and skills, narrowed fuzzily as you type, plus the plugin's own `/model` and `/copy`.
- **Permissions** inside Neovim: allow, deny, and Claude's own suggestions; questions and plans are answered the same way. Requests never open while you type; `<leader>an` jumps to the next session that needs you.
- **Model and permission mode** switching (`<leader>aM`, `<S-Tab>`), interrupt (`<C-c>`), park a session, and hand a session over to the native Claude screen in a tmux pane and back (`<leader>at`).
- **Chat header**: state in the drawer's colours, project, title, the model in italic and the permission mode as a badge.
- **Raw view** (`gr`): the exact JSON lines sent and received for a session.
- **Git review**: per project, the changes against the branch base and the commits on the branch; a side-by-side diff view on the real file with next/previous file and "this commit only"; `gd` on an edit in the transcript opens its diff; `glg` opens lazygit.
- **Commit graph** (`gG` in the drawer, `:AgentsGraph`): branches and merges drawn with coloured lanes and badges for branches, tags and `HEAD`; `<CR>` on a commit lists its files, `<CR>` on a file opens that commit's diff.
- **Search** (`<leader>as`, `s` in the drawer): fuzzy search over titles, prompts, answers and tool calls of all sessions, and a history of every prompt you sent; a preview that highlights every query word and steps through matches with `]n` / `[n`; opening a hit lands on the match in the transcript.
- **Reusable prompts**: a Prompts node with skills and commands and a prompt library (a folder of markdown files, with groups); saved prompts per project (`:w` / `ZZ` in the prompt buffer); save to the library with `<leader>W`.
- **Footer**: a statusline component (lualine or any statusline) with the overall state in four levels, the model, and quota used in the 5-hour and weekly windows; an optional `quota.file` to show the limits another tool wrote.
- **Omarchy bar widget** showing the same four levels with a count, including sessions running in terminals.
- **Rust helper** (`make helper`) for fast scanning, fuzzy search and file watching, with a Lua fallback when it is not built.
- Help in every view with `g?` (also `?` in the drawer), searchable with `/`.
- Icons: a minimal look with a Nerd Font by default, `icons_style = 'plain'` otherwise.

### Notes

- Claude runs through the Claude Code CLI on your subscription; an `ANTHROPIC_API_KEY` in the environment is not passed on.
- The plugin sends nothing over the network and reads no credentials.
- Other agents (Codex, Gemini, opencode) are planned and not included yet.
