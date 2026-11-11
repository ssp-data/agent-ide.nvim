# Changelog

All notable changes to Agent-IDE.nvim are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [semantic versioning](https://semver.org/).

## [Unreleased]

### Added

- `]s` / `[s` in the drawer and the chat (transcript and prompt) open the next or previous session of the same project, in the drawer's order, and the drawer's cursor follows (`keys.drawer.next_session` and `keys.chat.next_session`, `prev_session`; focus stays in the pane you pressed it in).
- Omarchy bar widget: clicking a session also switches to the workspace of, and focuses, the terminal window that shows tmux, and switches that tmux client to the session's exact session, window and pane.

- The removed and added lines of an `Edit` fold in a transcript are red and green (`AgentIdeDiffDel`, `AgentIdeDiffAdd`), also inside a subagent fold and in the search preview. `gd` on the fold opens the file's branch diff, as before.
- The command in a `Bash` fold has its own colour (`AgentIdeCommand`, linked to `Special`), so it stands apart from its output.
- Colour codes in tool output (`make test`, `git`, `cargo`) are shown as colours and bold, as a terminal shows them, instead of `^[[1m` noise. The colours follow the colorscheme's terminal palette; the raw view (`gr`) keeps the exact bytes.
- Background tasks (an async subagent, a shell run in the background) show as `task started: <description>` and `task completed: <description>` folds with the summary, tokens, tool uses and duration, instead of `unknown: system/task_started` folds of raw JSON. Foreground tasks no longer add a fold: their tool call already shows them.

### Changed

- Plan mode has its own key: `<leader>am` turns it on, and off again back to the mode you had before (`keys.chat.plan`). `<S-Tab>` now cycles manual, acceptEdits and auto (`claude.modes`; add `'plan'` to have it there again), and in plan mode it leaves plan.

### Fixed

- `<S-Tab>` no longer gets stuck on a mode Claude refuses, for example leaving plan mode while a turn runs. The cycle skips the refused mode and asks for the next one; it stops when it is back at the mode in effect.
- Opening a session whose Claude another Neovim drives shows the "another Neovim drives this session" warning once and then the transcript from disk. Before, it kept trying to attach, so the warnings piled up and covered the screen.
- Hand-off to native Claude (`gT`): a bare `claude` in the configured command is resolved through Neovim's own `$PATH` before the tmux pane runs it. The pane used to inherit the tmux server's environment, where `claude` can resolve to a different binary (a version manager's wrapper, say) that never starts.

## [0.1.0] - 2026-11-10

First public version.

### Added

- **Drawer** (`:Agents`, `<leader>aa`): every Claude Code session on the machine, grouped by git repository (sub-folders and worktrees fold into one project), with title, age and live state: input required, running, done, failed, idle, parked. Right-aligned state words such as `permission: Bash`, `done, unread`, `tmux 2.1`. Works for folders without git too.
- **Chat in native buffers**: a prompt buffer to write with your own Vim setup and a read-only markdown transcript; streaming answers; tool calls, thinking and subagents as folds; an answer text object (`ir` / `ar`); prompt history; attach files with `@`; send with `<C-CR>` or `<leader><CR>`.
- **Command menu** on `/` in the prompt: Claude's commands and skills, narrowed fuzzily as you type, plus the plugin's own `/model` and `/copy`.
- **Permissions** inside Neovim: allow, deny, and Claude's own suggestions; questions and plans are answered the same way. Requests never open while you type; `<leader>an` jumps to the next session that needs you.
- **Model and permission mode** switching (`<leader>aM`, `<S-Tab>`), interrupt (`<C-c>`), park a session, and hand a session over to the native Claude screen in a tmux pane and back (`gT`, `<leader>aT`).
- **Chat header**: state in the drawer's colours, project, title, the model in italic and the permission mode as a badge.
- **Raw view** (`gr`): the exact JSON lines sent and received for a session.
- **Git review**: per project, the changes against the branch base and the commits on the branch; a side-by-side diff view on the real file with next/previous file and "this commit only"; `gd` on an edit in the transcript opens its diff; `glg` opens lazygit.
- **Commit graph** (`G` in the drawer, `:AgentsGraph`): branches and merges drawn with coloured lanes and badges for branches, tags and `HEAD`; `<CR>` on a commit lists its files, `<CR>` on a file opens that commit's diff.
- **Search** (`<leader>as`, `s` in the drawer): fuzzy search over titles, prompts, answers and tool calls of all sessions, and a history of every prompt you sent; a preview that highlights every query word and steps through matches with `]n` / `[n`; opening a hit lands on the match in the transcript.
- **Reusable prompts**: a Prompts node with skills and commands and a prompt library (a folder of markdown files, with groups); saved prompts per project (`:w` / `ZZ` in the prompt buffer); save to the library with `<leader>W`.
- **Footer**: a statusline component (lualine or any statusline) with the overall state in four levels, the model, and quota used in the 5-hour and weekly windows; an optional `quota.file` to show the limits another tool wrote.
- **Omarchy bar widget** showing the same four levels with a count, including sessions running in terminals.
- **Rust helper** (`make helper`) for fast scanning, fuzzy search and file watching, with a Lua fallback when it is not built.
- Help in every view with `g?` (also `?` in the drawer), searchable with `/`.
- Icons: a minimal look with a Nerd Font by default, `icons_style = 'plain'` otherwise.
- **Hide a session** with `H` on its row: it moves into a collapsed, dimmed `Hidden (n)` group of its project; `H` there shows it again. A hidden session that needs you (waiting, working, done unread, failed) is listed with the others while that lasts. Kept in `hidden.json`, shared by several Neovims.
- **Delete an inactive session** with `D` (after a confirm): what Claude keeps of it moves into the plugin's trash. `:AgentsTrash` restores a session or deletes it for good, `:AgentsTrash empty` deletes everything in the trash for good. The trash keeps the whole session, prompts and answers included, until you empty it; `trash = { keep_days = 30 }` purges older entries at setup, by default nothing is purged.
- **Collapse and expand all** in the drawer with `z0` and `z9`.
- **Project scope** (`scope = 'project'` in `setup()`, `:Agents project`, `:Agents all`, `<S-Tab>` in the drawer): the drawer, search, `<leader>an` and the footer show one repository; a dimmed last line says when a session of another project needs you.
- **Legend** of the state marks at the bottom of the drawer; `gL` shows or hides it, `drawer = { legend = false }` starts with it hidden.
- **Session keys on a drawer row**: `<leader>aM`, `<C-c>` (asks first), `gT` and `gr` act on that session as in its chat, without opening it.
- **Close terminal sessions**: `X` on a row of a Claude running in a tmux pane types Claude's own exit (Ctrl-C twice) into that pane after a confirm and a fresh check that this Claude is the pane's foreground program; `:AgentsCloseIdle` does it for every idle one (in project scope for that project, `:AgentsCloseIdle!` for all).
- **Buffer names**: the chat's buffers are named after the session (`agents://<project>/<title>`, `… · prompt`), so a tabline, a bufferline and `:ls` show them instead of `[No Name]`; they follow the title.
- **Help you can filter**: `?` / `g?` open the keys of a view as a palette with a query line; typing narrows the list fuzzily, `<CR>` presses the selected key in the window you came from.
- **Drafts kept on disk**: the text of a prompt buffer is written to `stdpath('state')/agent-ide/drafts/<session id>.md` as you type and when you leave; it comes back when the session's prompt opens again (also after a crash), and `+ New session` takes over a draft left for an unsent new session of the project. A send, `:q!` and a deleted session remove it.
- **The model before the first prompt**: the winbar and the footer name the model a session will start with (picked for it, else `claude.model`, else the model last used here, kept in `prefs.json`, else Claude's default); new and resumed sessions start with it.
- **Commit graph row**: an expanded `Commits` section starts with a dimmed `commit graph` row; `<CR>` opens the graph.
- **Uncommitted row**: right below it, `uncommitted (n)` lists what is not committed yet (working tree and index against `HEAD`, untracked files included); `<CR>` on a file diffs it against `HEAD`.
- `y` on a session row in the drawer yanks the last prompt sent in it.
- Every drawer key is configurable under `keys.drawer` (a key, a list of keys, or `false`).
- The legend toggle (`gL`, `<leader>aL`) is remembered across restarts (`prefs.json`).
- The prompt window wraps long lines (`wrap`, `linebreak`).
- The idle mark is a filled `●` in mid grey instead of green (green read as running); parked stays the hollow `○` in the dim comment colour.
- **Background sessions**: every Claude the plugin starts runs under a keeper, a small detached headless Neovim that owns its pipes, so quitting Neovim (or a crash) leaves it running; queued prompts are handed over and sent at the end of each turn. A new Neovim lists such sessions as `background` (or `input` when one waits for you) and reattaches when you open or send to one: the transcript, the text that was streaming, open asks, model, mode and state come back as they were. An idle Claude with no Neovim attached is closed after `keeper.idle_minutes` (30). The quit guard no longer asks. `keeper = { enabled = false }` keeps Claude a child of Neovim.
- **Queue panel** (`Q` in the chat): the session's prompts as a timeline, sent, running and queued; `x` takes a queued prompt back into the prompt buffer, `<CR>` jumps to a sent one in the transcript.
- A soft chime when a session needs you (`sound = { waiting = true, chime = 'two', cmd = nil }`; five to choose from: two, soft, bell, rising, pop; `:AgentsChime <name>` plays one; played through pw-play, paplay, aplay or afplay).
- Claude's own text in a transcript starts with a `●` (`AgentIdeAnswerMark`, virtual text), so what it tells you stands out from the tool folds, also while it streams and in the search preview.

### Changed

- The `/` menu lists Claude's commands and your skills from the first keystroke in a new session (the last list seen for the project, kept in `commands.json`).
- `+ New session` pressed again while the new session has sent nothing brings it back with its draft instead of starting another (`2<CR>` starts a separate one).
- `@` puts the file reference where you typed it (mid-line as `@<path>`, on an empty line as an `[attach]` line), types a plain `@` inside a fenced code block, and keeps up with fast typing.
- `<Up>` on the first line and `<Down>` on the last step through the prompt history in insert mode too.
- The model picker lists every model Claude Code offers, with names and descriptions (`Fable 5.2 — … (claude-fable-5-2)`), and marks the current one; the winbar and the footer name the model the same way (`fable 5.1`). `claude.models` now defaults to Claude's own list (kept in `models.json`); a list you set is used as given.
- New default keys in the drawer: `z0` / `z9` collapse and expand all (were `zM` / `zR`); `gT` or `<leader>aT` goes to tmux (jumps to the pane of a session running elsewhere, else continues the session in native Claude in a tmux pane; were `gp` and `<leader>at`); `S`, `<leader>ff` or `<leader>S` search the project (was `s`); `sP` parks (was `x`); `D` also deletes a prompt file (was `d`); `G` opens the commit graph (was `gG`); `<S-Tab>` flips the scope (was `gs`; on a session row it no longer cycles the permission mode, which stays the chat's `<S-Tab>`); `sL` copies a saved prompt into the library (was `L`); `gL` or `<leader>aL` toggle the legend. In the chat, `<leader>M` also picks the model and `gT` / `<leader>aT` continue in native Claude (`gT` in the transcript only). In the search picker `<C-f>` picks what to search (was `<C-t>`, a common tmux prefix).
- A prompt row key (edit, rename, delete, yank, to library) acts on its rows even when a drawer key has the same lhs; elsewhere the drawer key acts.

### Fixed

- `/` typed in a burst (fast typing, a macro, `.`) after other text no longer prepares the command menu; it opens only on an empty line.
- Moving into a long transcript no longer freezes Neovim for minutes when a markdown render plugin sets `conceallevel` (treesitter checked every line of the buffer one by one; a 20 000-line session took minutes, now milliseconds).
- `X` right after a Claude restarted in its pane no longer says it cannot reach the session: it asks and then checks the pane itself.

### Notes

- Claude runs through the Claude Code CLI on your subscription; an `ANTHROPIC_API_KEY` in the environment is not passed on.
- The plugin sends nothing over the network and reads no credentials.
- Other agents (Codex, Gemini, opencode) are planned and not included yet.
