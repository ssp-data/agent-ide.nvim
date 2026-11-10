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
- **Hide a session** with `H` on its row: it moves into a collapsed, dimmed `Hidden (n)` group of its project; `H` there shows it again. A hidden session that needs you (waiting, working, done unread, failed) is listed with the others while that lasts. Kept in `hidden.json`, shared by several Neovims.
- **Delete an inactive session** with `D` (after a confirm): what Claude keeps of it moves into the plugin's trash. `:AgentsTrash` restores a session or deletes it for good, `:AgentsTrash empty` deletes everything in the trash for good. The trash keeps the whole session, prompts and answers included, until you empty it; `trash = { keep_days = 30 }` purges older entries at setup, by default nothing is purged.
- **Collapse and expand all** in the drawer with `zM` and `zR`.
- **Project scope** (`scope = 'project'` in `setup()`, `:Agents project`, `:Agents all`, `gs` in the drawer): the drawer, search, `<leader>an` and the footer show one repository; a dimmed last line says when a session of another project needs you.
- **Legend** of the state marks at the bottom of the drawer; `gL` shows or hides it, `drawer = { legend = false }` starts with it hidden.
- **Session keys on a drawer row**: `<leader>aM`, `<S-Tab>`, `<C-c>` (asks first), `<leader>at` and `gr` act on that session as in its chat, without opening it.
- **Close terminal sessions**: `X` on a row of a Claude running in a tmux pane types Claude's own exit (Ctrl-C twice) into that pane after a confirm and a fresh check that this Claude is the pane's foreground program; `:AgentsCloseIdle` does it for every idle one (in project scope for that project, `:AgentsCloseIdle!` for all).
- **Buffer names**: the chat's buffers are named after the session (`agents://<project>/<title>`, `… · prompt`), so a tabline, a bufferline and `:ls` show them instead of `[No Name]`; they follow the title.

### Changed

- The `/` menu lists Claude's commands and your skills from the first keystroke in a new session (the last list seen for the project, kept in `commands.json`).
- `+ New session` pressed again while the new session has sent nothing brings it back with its draft instead of starting another (`2<CR>` starts a separate one).
- `@` puts the file reference where you typed it (mid-line as `@<path>`, on an empty line as an `[attach]` line), types a plain `@` inside a fenced code block, and keeps up with fast typing.
- `<Up>` on the first line and `<Down>` on the last step through the prompt history in insert mode too.

### Fixed

- `/` typed in a burst (fast typing, a macro, `.`) after other text no longer prepares the command menu; it opens only on an empty line.
- Moving into a long transcript no longer freezes Neovim for minutes when a markdown render plugin sets `conceallevel` (treesitter checked every line of the buffer one by one; a 20 000-line session took minutes, now milliseconds).
- `X` right after a Claude restarted in its pane no longer says it cannot reach the session: it asks and then checks the pane itself.

### Notes

- Claude runs through the Claude Code CLI on your subscription; an `ANTHROPIC_API_KEY` in the environment is not passed on.
- The plugin sends nothing over the network and reads no credentials.
- Other agents (Codex, Gemini, opencode) are planned and not included yet.
