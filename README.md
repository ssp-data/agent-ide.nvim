# Agent-IDE.nvim (Agents Drawer)

A Neovim plugin that lists your Claude Code sessions in a drawer, grouped by git repository, and opens any session's history as a read-only markdown buffer. Sessions that are running show their state (waiting, busy, idle) next to their name.


## Why I built Agent-IDE?

Agents-IDE.nvim is my new plugin for agent handling in Neovim, optimized for [my terminal workflow](https://www.ssp.sh/brain/my-terminal-workflow-with-macos-and-linux/). I saw a tweet, [`Herdr or Rex`](https://x.com/omarmsimon/status/2120013311681130603), and then I thought, why not in Neovim? Below is what came out of that question.

Coding is changing, from writing to more navigating and viewing changes, etc. So Neovim is great for all of it, I use nvim with lazygit for seeing all the changes and navigating around changes the agents made. So I thought, why not make it the main control center, as I did for email with [Neomd](https://github.com/ssp-data/neomd), where nvim is the composer.

I want to prompt in neovim (I use `ctrl-g`) for Claude Code anyway to type with my shortcuts [Vim Motions](https://www.ssp.sh/brain/vim-language-and-motions/) and also my snippets and superpowers, and the rendering of responses from Claude Code looks awful, unlike my rendering of Markdown within neovim. So why not use neovim to write and also show the responses in a buffer of Neovim that renders Markdown nicely? That was the premise, and the outcome looks like this:

## Focus
The features and focus are on managing all agent sessions in a single drawer, as I use [Query databases in vim (vim-dadbod)](https://www.ssp.sh/brain/query-databases-in-vim-vim-dadbod/) to query databases within nvim, that's why it's called the **Agents IDE** because it's my IDE for agents.

### Why not a Terminal TUI, why Neovim?
You might ask why not a terminal-based TUI, now that Herdr, Rex, and others are built in the terminal for agents, or even apps nowadays. The reason is that nvim is doing most of the things I like to improve anyway, and I have a 5+ year history of dotfiles for nvim, where I optimized these aspects over the years already - things like: 
- beautiful markdwon rendering
- modal typing and fast moving around
- git integration with lazygit and other shortcuts
- the place to navigate and being an IDE for agents, as it has so many functionalities and is super extensible and composable

## Features
- TODO: List all key veatures here


## Status

Parts 1 to 5 of 6 and search are done: the drawer and the history view, chat with Claude Code from Neovim, reusable prompts, git review (what an agent changed, with a diff view), the Omarchy indicator (see `omarchy/io.github.sspaeti.agent-ide/README.md`), and search across all sessions. Other agents (part 6) are planned and not available yet.

## Prerequisites

| What | Needed | What for |
|---|---|---|
| Neovim 0.12 or newer | required | |
| Claude Code, logged in with a subscription | required | The plugin reads the transcripts Claude Code writes to `~/.claude/projects`, asks `claude agents --json` which sessions are running, and runs `claude -p` for the chat (and `claude --resume` in a tmux pane for native Claude). Tested with Claude Code 2.1.306 |
| `git` | recommended | The `Changes` and `Commits` sections and the diff view. Grouping sessions by repository reads the `.git` folders and works without it |
| A [Nerd Font](https://www.nerdfonts.com) in the terminal | recommended | The default icons (`icons_style = 'nerd'`). Without one, set `icons_style = 'plain'` |
| Extended keys in the terminal (and in tmux) | recommended | `<C-CR>` sends the prompt only when the terminal, and tmux if you use it, pass `<C-CR>` on to Neovim; see [Settings you may need](#settings-you-may-need). `<leader><CR>` sends without it |
| Treesitter parsers `markdown` and `markdown_inline` | recommended | Highlighting in the transcript, which is a `markdown` buffer, when treesitter highlighting is on for markdown (Neovim bundles both parsers; keep them if a plugin manages your parsers) |
| A markdown render plugin | optional | Nicer answers in the transcript; any plugin that renders `markdown` buffers works |
| lualine, or any statusline | optional | The footer with the state of all sessions and the quota (see [Footer](#footer)) |
| `cargo` | optional | Builds the Rust helper: fast scanning, file watching and fuzzy, typo-tolerant search. Without it a Lua backend scans on a timer and search is limited to titles and prompts, exact words only |
| `tmux` | optional | `gp` jumps to the pane of a session running elsewhere (the drawer then shows its pane, `tmux 2.1`), and `<leader>at` continues a chat in native Claude in a tmux pane |
| `lazygit` | optional | `glg` in the drawer and the diff view |
| A `vim.ui.select` provider such as Snacks or Telescope | optional | Nicer pickers (permissions, model, prompts); the built-in one works |
| A clipboard provider | optional | Copying a search hit (`<C-y>`) and yanking a prompt (`y`) also to the `+` register |

### Settings you may need

For `<C-CR>` inside tmux, add to `~/.tmux.conf` (and restart the tmux server):

```tmux
set -s extended-keys on
set -as terminal-features 'xterm*:extkeys'
```

For the footer in lualine, see [Footer](#footer). After updating the plugin, run `make helper` in the plugin folder (or let your plugin manager run its build step) so the helper matches the Lua code; until then the plugin says so and uses its Lua backend.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'your-github-user/Agent-IDE.nvim', -- replace with the repository path
  build = 'make helper', -- optional; needs cargo
  cmd = 'Agents',
  keys = { { '<leader>aa', '<cmd>Agents<cr>', desc = 'Agent-IDE: toggle drawer' } },
  opts = {},
}
```

Without `cargo` leave out `build`; the plugin uses its Lua backend.

If Neovim says that the helper is out of date, the helper binary was built from older sources than the plugin (both must read transcripts by the same rules): run `make helper` in the plugin folder (or let your plugin manager run its build step). Until then the plugin uses its Lua backend.

## Configuration

These are the defaults. Pass only what you want to change to `setup()` (or `opts`).

```lua
require('agent-ide').setup({
  projects_dir = vim.fn.expand('~/.claude/projects'),
  drawer = { width = 44, side = 'right' },
  live = { interval_ms = 5000, cmd = { 'claude', 'agents', '--json' } },
  helper = { enabled = true, path = nil }, -- nil: <plugin root>/helper/target/release/agent-ide-helper
  claude = {
    cmd = { 'claude' },     -- executable and leading arguments for the chat process
    strip_api_key = true,   -- remove ANTHROPIC_API_KEY from the environment of every Claude it starts
    model = nil,            -- model for new sessions (nil: Claude's default)
    version_check = true,   -- one notice when the installed Claude Code is not the tested version
    modes = { 'manual', 'acceptEdits', 'plan', 'auto' }, -- what <S-Tab> cycles through
    default_mode = nil,     -- where the cycle starts before Claude reports a mode
    models = { 'fable', 'opus', 'sonnet', 'haiku' },     -- what the model picker offers
  },
  tcd = true, -- opening a session sets the tab's working directory to its project
  keys = { -- false disables a mapping; keys = false disables all of them
    toggle = '<leader>aa',
    next_waiting = '<leader>an',
    search = '<leader>as', -- search all sessions
    prompt_history = '<leader>aP', -- every prompt, newest first
    -- the search picker's query line; close works in normal mode (insert-mode <Esc> leaves insert mode)
    search_picker = { next = { '<C-n>', '<Down>' }, prev = { '<C-p>', '<Up>' }, open = '<CR>', copy = '<C-y>',
      reuse = '<C-e>', scope = '<Tab>', kinds = '<C-t>', close = { '<Esc>', 'q' } },
    chat = { send = '<C-CR>', send_alt = '<leader><CR>', interrupt = '<C-c>', prompt = '<leader>ap', help = '?',
      history_prev = '<C-p>', history_next = '<C-n>', attach = '<leader>af',
      answer_inner = 'ir', answer_outer = 'ar', mode = '<S-Tab>', model = '<leader>aM', answer = '<leader>ay',
      raw = 'gr', raw_event = 'gR', native = '<leader>at', park = '<leader>ax', diff = { 'gd', '<leader>gd' },
      save_library = '<leader>W', prompts = '<leader>al' },
    -- diff view; each value is a key, a list of keys, or false
    diff = { next_file = { ']f', '<leader>gj' }, prev_file = { '[f', '<leader>gk' }, flip = { 'gb', '<leader>gt' },
      branch = { 'gB', '<leader>gB' }, close = { 'q', '<leader>gq' }, help = { '?' }, refresh = { 'R' }, lazygit = 'glg' },
    -- drawer, on prompt rows (elsewhere these keys keep their normal meaning)
    prompts = { edit = 'e', rename = 'r', delete = 'd', yank = 'y', to_library = 'L' },
  },
  prompts = {
    library_dir = nil,  -- your templates (nil: stdpath('data') .. '/agent-ide/library')
    saved_dir = nil,    -- per-project saved prompts (nil: stdpath('data') .. '/agent-ide/prompts')
    command_dirs = { '~/.claude/commands' }, -- Claude's commands (read only)
    skill_dirs = { '~/.claude/skills' },     -- Claude's skills (read only)
    project_dirs = true, -- also <project>/.claude/commands and /skills of the chat's project
  },
  chat = { auto_slash = true, at_picker = true }, -- `/` opens the command menu, `@` the file picker
  icons_style = 'nerd', -- 'nerd' (needs a Nerd Font) or 'plain' (characters of any monospace font)
  icons = {}, -- override single icons of that set, for example { busy = '*', changes = '' }; '' hides one
})
```

Icon keys: `open`, `closed` (fold arrows), `prompts`, `changes`, `commits`, `worktree`, and the session states `waiting`, `busy`, `idle`, `parked`, `done`, `failed`. Both sets use `▾ ▸` for folds, `⎇` for a worktree and the characters `● ◐ ● ○ ✓ ✗` for waiting, busy, idle, parked, done and failed (waiting and idle differ by colour). The nerd set differs in two places only: a notebook glyph (nf-md-notebook_outline) on the Prompts row and one git glyph (nf-oct-git_compare) on both the `Changes` and `Commits` rows. Nothing else carries an icon: no project icon, no section icons, no per-kind prompt icons.

`:Agents` (or the toggle key) opens the Agents tab with the drawer. Inside the Agents tab it closes or reopens the drawer; from any other tab it switches to the Agents tab.

## Drawer

The drawer has no header line; `?` lists every key. Each row shows its state mark and title on the left and, aligned to the right edge, what needs you and how old it is; a title too long for the drawer is cut with `…`, the right part never.

| Row | Right part |
|---|---|
| Session waiting for you | `permission: <tool>`, `question` or `plan to approve` (in another Claude: `input`) |
| Session done or failed while you were elsewhere | `done, unread`; `failed`, with the start of the error when there is one |
| Session running in another Claude | `tmux <window>.<pane>` when Neovim runs inside tmux and the session in one of its panes, else `elsewhere`; handed to native Claude: `native` |
| Project | the state icon of its most urgent session; `input (n)` while sessions wait, `review (n)` for done or failed ones; then the age of its newest session |
| Changed file, commit | `+added −removed`, the commit's age |

Ages read `now`, `5m`, `3h`, `12d`, then months (`14mo`) and years (`2y`). Colours: waiting violet (bold), busy yellow, idle green, done orange, failed red, parked rows (mark, title, age) and ages dimmed, never italic; the groups are `AgentIdeWaiting`, `AgentIdeBusy`, `AgentIdeIdle`, `AgentIdeDone`, `AgentIdeFailed`, `AgentIdeParked`, `AgentIdeAge` and `AgentIdeSection`, and a colorscheme can set them. The dim groups (`AgentIdeParked`, `AgentIdeAge`, `AgentIdeMissing`, `AgentIdeBranch`, `AgentIdeGitUntracked`) take the foreground of `Comment` at setup and on every `ColorScheme`, without italic or bold. A project row is its fold arrow and bold name; a parked project's name is dimmed. A project whose folder is gone says `(folder missing)`; a session started in a sub-folder of its project shows `<subfolder>/ · <title>`.

## Keys

Global:

| Key | Action |
|---|---|
| `<leader>aa` | Toggle the Agents tab (same as `:Agents`) |
| `<leader>as` | Search all sessions (`:AgentsSearch [query]`) |
| `<leader>aP` | Prompt history: every prompt you sent, newest first |
| `<leader>an` | Go to the next session that needs you: one waiting for your answer here (oldest ask first), then one waiting in another Claude (jumped to in tmux), then a failed turn, then a finished turn you have not seen; from the first of them, the one after it |

In the drawer:

| Key | Action |
|---|---|
| `<CR>`, `o` | Expand or collapse a project; open a session; start a new session (`+ New session`); use a prompt |
| `za` | Expand or collapse the node under the cursor |
| `R` | Rescan sessions and refresh running state |
| `gp` | Jump to the tmux pane of a session running elsewhere |
| `s` | Search the sessions of the project under the cursor |
| `x` | Park the session: stop the Claude process this Neovim runs for it |
| `q` | Close the drawer |
| `glg` | Open lazygit for the row's repository (a worktree row or session: that worktree) |
| `?` | Help |
| `e` | Prompt row: edit its file in the main window (Claude's commands and skills open read-only) |
| `r` | Prompt row: rename (library: `group/name` moves it to another group) |
| `d` | Prompt row: delete the file (asks first) |
| `y` | Prompt row: yank its text (unnamed and `+` registers) |
| `L` | Saved prompt row: copy it into the library (asks for a name) |

The prompt row keys are under `keys.prompts`; elsewhere in the drawer they keep their Vim meaning, and a drawer key above always wins over one of them.

In the chat (transcript and prompt buffer, unless noted):

| Key | Action |
|---|---|
| `<C-CR>` | Send the prompt (normal and insert mode) |
| `<leader><CR>` | Send the prompt |
| `<C-c>` | Normal mode: interrupt Claude; queued prompts come back into the prompt buffer |
| `<leader>ap` | Focus the prompt |
| `i`, `a`, `o` | Transcript: write in the prompt |
| `<leader>ay` | Answer what Claude asks (permission, question, plan) |
| `<S-Tab>` | Next permission mode |
| `<leader>aM` | Pick the model |
| `<leader>ax` | Park the session: stop its Claude process (asks when it is working); the next send resumes it |
| `<leader>at` | Continue the session in native Claude in a tmux pane; while it is there, take it back |
| `gr` | Transcript: raw view of what was sent and received; `q` or `gr` returns |
| `gR` | Transcript: raw view at the line of the `unknown` fold under the cursor |
| `ir`, `ar` | Transcript: text object for one Claude answer (`ar` with its header) |
| `gd`, `<leader>gd` | Transcript, on an `Edit` or `Write` fold: the branch diff of that file |
| `<C-p>`, `<C-n>` | Prompt: older or newer prompt (also `<Up>` on the first line, `<Down>` on the last) |
| `<leader>af` | Prompt: pick a file and add an `[attach]` line |
| `/` | Prompt, on an empty line: Claude's commands (menu) |
| `@` | Prompt, after a space: pick a file to attach |
| `<leader>al` | Pick a prompt: saved prompts, library, Claude's commands and skills |
| `<leader>W` | Prompt: save it to the library (asks for a name; `group/name` makes a folder) |
| `:w`, `:x`, `ZZ` | Prompt: save it (see [Prompts](#prompts)); `:x` and `ZZ` then hide the window |
| `za` | Toggle fold |
| `:q` | Prompt: hide the window; the draft stays |
| `:q!` | Prompt: hide the window and discard the draft |
| `?` | Help |

The history buffer is markdown with folds for tool calls, results and thinking. Anything the viewer does not understand is shown as a fold marked `unknown`, never dropped, and truncated output says how many lines are hidden.

## Chat

Open a session from the drawer, or start one with `+ New session` under a project. The transcript fills the main window of the Agents tab and a prompt buffer opens below it. Opening a session shows its history without starting Claude; the first prompt you send starts `claude -p` for it (resuming the session when it has a history), and the process keeps running until you park the session (`<leader>ax`, or `x` in the drawer), hand it to native Claude, or quit Neovim. Parking asks first when Claude is working, puts queued prompts back into the prompt buffer, and keeps the transcript; the next prompt resumes the session. The winbar shows project, title, model, permission mode, state and the number of queued prompts.

**Prompt buffer.** A normal markdown buffer: write as much as you like and send it with `<C-CR>`. Its text is sent as typed, except that an `[attach] <path>` line outside a fenced code block becomes `@<path>` (`@"<path>"` when the path holds spaces), which makes Claude read the file. `@` after a space opens a file picker that adds such a line; `/` on an empty line opens the menu of the commands the session listed (known after its first answer). `<C-p>` and `<C-n>` step through the prompts of the session.

**While Claude works.** Answers stream into the transcript. A prompt sent while a turn runs is queued by the plugin and sent after that turn, in order. `<C-c>` interrupts the turn and puts the queued prompts back into the prompt buffer.

**Permissions, questions and plans.** When Claude asks to use a tool, the ask shows at the end of the transcript and in the drawer, and a picker opens with Allow, Deny and the suggestions Claude made (switch the mode for this session, or always allow a rule; offered only where Claude saves it in this project's local settings, and labelled so). The picker opens only when you are in that session's chat in normal mode. Nothing ever interrupts you: an ask from another session never opens a popup, moves the cursor or takes focus; it shows in the drawer and in the footer, and `<leader>an` takes you there. While you type in the same session's prompt, a one-line hint appears instead; `<leader>ay` opens the picker. Questions Claude asks (multiple choice) are answered the same way, one picker per question; a multi-select question takes one option per round until you pick Done choosing. A plan from plan mode can be approved, approved with edits accepted for the rest of the session, or sent back with Keep planning.

**Mode and model.** `<S-Tab>` cycles the permission mode (manual, acceptEdits, plan, auto) and `<leader>aM` picks the model. The winbar shows `old→new` until Claude confirms the change; a refused change says why.

**Raw view.** `gr` in the transcript shows every line sent to Claude (`>>`) and received (`<<`) for the session, byte for byte; for a session that did not run here it shows the transcript file. Anything the chat cannot render shows as an `unknown` fold, and `gR` on it opens the raw view at its line.

**Native Claude.** `<leader>at` inside tmux parks the session (after a question when Claude is working), opens `claude --resume <id>` in a split pane, and takes the session back when that pane ends (also when it is killed). Until then the winbar says `in native Claude (tmux pane)` and sending is refused; `<leader>at` again offers to take the session back, which is refused while native Claude still runs it. The session is reloaded from disk in the background: a chat on screen is refreshed in place, otherwise a notice says it is back. Outside tmux the key parks the session and shows the command to run.

**Quitting.** Quitting Neovim while a session is working asks first; `:qa!` and the other forced quits do not ask.

**Subscription.** The plugin removes `ANTHROPIC_API_KEY` from the environment of every Claude process it starts, so Claude uses your subscription login and never bills an API key (`claude.strip_api_key = false` keeps it).

## Footer

`require('agent-ide').statusline()` gives a short text for a statusline: the state of all sessions, the model of the chat you are in and the quota left (percent remaining, with a small bar):

| Level | Colour | Text | When |
|---|---|---|---|
| 1 | green | `agents ok` | nothing running or waiting |
| 2 | yellow | `agents running (n)` | sessions are working |
| 3 | orange | `review (n)` | a turn ended (or failed) in a session you have not looked at since |
| 4 | violet | `input required (n)` | Claude waits for your answer |

followed by, for example, ` · haiku-5-5 · 5h ▰▰▰▰▱ 82% · week ▰▰▰▱▱ 64%`. `statusline_hl()` names the highlight group of the level (`AgentIdeLevel1` to `AgentIdeLevel4`). For lualine:

```lua
require('lualine').setup({
  sections = {
    lualine_x = { require('agent-ide').lualine(), 'filetype' },
  },
})
```

With a lazy-loaded plugin, a component that does not load it:

```lua
{
  function() return require('agent-ide').statusline() end,
  cond = function() return package.loaded['agent-ide'] ~= nil end,
  color = function()
    local hl = vim.api.nvim_get_hl(0, { name = require('agent-ide').statusline_hl(), link = false })
    return hl.fg and { fg = ('#%06x'):format(hl.fg) } or nil
  end,
}
```

**Status files.** Each Neovim writes `status-<pid>.json` to `$XDG_RUNTIME_DIR/agent-ide/` (else `stdpath('run')/agent-ide/`) with `version, pid, updated, level, name, waiting, review, busy` and the sessions that are not parked. A reader (such as the Omarchy indicator) combines all `status-*.json` files and ignores a file whose pid is not running, or whose `updated` is older than 90 seconds while its `level` is above 1.

## Git: what an agent changed

Each git project in the drawer has two more sections below its sessions: `Changes vs <base>` (everything on the branch since it left the default branch, uncommitted and untracked files included; on the default branch, uncommitted changes against `HEAD`) and `Commits on branch` (`Recent commits` on the default branch), each commit expanding to its files. The project row shows the branch when it is not the default branch. The lists refresh when a session of the project finishes a turn, on `R`, and when you come back to the drawer after more than 5 s.

`<CR>` on a file opens a side-by-side diff in the main window, built on Neovim's own diff mode. For branch changes the right side is your real, editable file. In the chat, `gd` (or `<leader>gd`) on an `Edit` or `Write` fold opens the diff of that file. Opening a diff sets the Agents tab's directory to that work tree (`tcd`, like opening a chat), so your own lazygit or picker keys work on it. Sessions in a linked worktree get a row per work tree (worktree icon, `<branch> · <folder>`) with its own Changes and Commits.

| Key (diff view) | Action |
|---|---|
| `]f`, `<leader>gj` / `[f`, `<leader>gk` | Next / previous changed file |
| `gb`, `<leader>gt` | This file in one commit only (pick which); again: back to the whole branch |
| `gB`, `<leader>gB` | Back to the whole-branch diff |
| `R` | Reload the list and the base side |
| `]c` / `[c` | Next / previous hunk (Neovim) |
| `glg` | lazygit for this repository |
| `q`, `<leader>gq` | Close the diff, back to what was shown before (`:q` on either side too) |
| `?` | Help |

The keys are under `keys.diff` (and `keys.chat.diff`) in the configuration; each value is a key, a list of keys, or `false`. Git is only read (`git --no-optional-locks`, never a command that writes); acting is left to lazygit.

## Prompts

Reusable prompts one keypress away, in a `Prompts` node at the top of the drawer (it reads its folders only when you open it) and in a picker (`<leader>al` in the chat, or `require('agent-ide').prompts()`):

- **Skills & commands** are Claude's own: every `*.md` under `~/.claude/commands` (a sub-folder `git/sync.md` is `/git:sync`, the name Claude Code lists for it) and every `~/.claude/skills/<name>/SKILL.md` (named by its frontmatter `name`, else the folder), plus those in `<project>/.claude/` of the chat's project (a project one wins over a user one of the same name). `<CR>` puts `/name ` as the first line of the prompt and leaves you in insert mode for the arguments; Claude loads the command itself. Nothing is copied and these files are never changed (`e` opens them read-only).
- **Library**: your templates, one markdown file per prompt; sub-folders are groups in the drawer. The title is the frontmatter `name` (or `title`), else the first heading, else the file name. `<CR>` loads the text into the prompt buffer for you to fill in and send. A template is loaded and saved exactly as the file is: a frontmatter block, if you use one for a title and description, is part of the text. A draft already in the prompt buffer is never thrown away: you are asked whether to replace it, insert above it, or cancel.
- **Saved prompts** belong to a project and show as `Saved prompts (n)` below its sessions once it has any. They load as the whole file.

With no chat open, a saved prompt starts a new session in its project; anything else asks you to open a session first.

Saving works on the prompt buffer (which is never marked modified, so `:q` and `:qa` never ask about a draft):

| You do | What happens |
|---|---|
| `:w`, `:wq`, `:x` or `ZZ` on a new prompt | Saved under the session's project, named after its first line (`fix-the-login-bug.md`; `-2`, `-3` … when the name is taken, never overwriting another prompt). Text that is already saved word for word is not saved twice (`already saved`), and the buffer stays a new prompt. Further `:w` update the file it wrote |
| `:w` after loading a template or saved prompt | That file is updated in place: it becomes exactly the buffer text. If it changed on disk since you loaded it, you are asked: overwrite, save as new, or cancel |
| Anything else that changes the text for you (inserting a command, "insert above", queued prompts coming back after an interrupt or park, reusing a search hit) | The text becomes a new prompt: the next `:w` never writes it into the file it was loaded from |
| `<leader>W` | Asks for a name and saves to the library; `writing/my post` becomes `writing/my-post.md`. Names with `..`, a leading `/` or characters other than letters, digits, space, `-`, `_`, `.` are refused and asked again; a taken name is never overwritten |
| `:w` on an empty prompt | `nothing to save`; `ZZ` just hides the window |
| Send | The prompt goes out as typed; the buffer forgets which file it came from, so the next `:w` makes a new saved prompt and an edited template you sent without saving stays as it is on disk |
| `:qa`, `:wqa`, `:xa` | Nothing is saved, nothing is asked |

Files are written as typed, with a final newline added when the last line has none, atomically (a temporary file renamed into place; a new file is linked into place, so two Neovims saving the same name both keep theirs). New files are `0600` in folders created `0700`. The plugin writes only to the library and saved-prompts folders and never under a `.claude` folder. Drawer rows refresh on `R`, after a save, rename or delete, and when you come back to the drawer.

To keep your library in git, point `library_dir` at a folder of a repository you manage (outside any `.claude` folder, so Claude does not take the templates for commands):

```lua
opts = { prompts = { library_dir = '~/notes/prompts' } }
```

## Search

`<leader>as` (or `:AgentsSearch [query]`, or `require('agent-ide').search()`) opens a floating picker that searches the titles, your prompts and Claude's answers of every session, live as you type. `<leader>aP` opens the same picker on your prompts only, newest first: the prompt history of all sessions. In the drawer, `s` searches the project under the cursor.

With the Rust helper the search is fuzzy and typo-tolerant ([neo_frizbee](https://crates.io/crates/neo_frizbee)): exact and word-start matches come first, then titles before prompts before answers, then the newest; a fuzzy match must keep its letters close together. Words match in any order; a word with a capital letter matches case-sensitively; umlauts match regardless of case (`über` finds `Über`). A session found only through a word of its project's name is listed last (`proj`). The index is built in the background on first use, kept on disk and updated when a transcript changes. Without the helper the picker says it is limited: titles and prompts only, exact words only.

| Key in the picker | Action |
|---|---|
| typing | Search (results update per keystroke) |
| `<C-n>` / `<C-p>`, `<Down>` / `<Up>` | Move |
| `<CR>` | Open the session's chat on the hit's line |
| `<C-y>` | Copy the hit's full text (prompt, answer or title) |
| `<C-e>` | Put the prompt into the open chat prompt to reuse it |
| `<Tab>` | Scope: all sessions, the current project, the current session |
| `<C-t>` | What to search: everything, prompts, answers, titles, or also tool calls |
| `<Esc>` (normal mode) or `q` | Close; in insert mode `<Esc>` first goes to normal mode |

The keys are under `keys.search_picker`; each is a key, a list of keys, or `false`. Other keys keep their Vim meaning in the query line: `<C-r>` inserts a register, `<C-k>` a digraph (`<C-k>u:` gives `ü`).

The preview shows the hit in its turn, rendered and folded as in the chat, with the hit's fold open. The prompt history lists the newest 500 prompts (the footer says how many there are; type to narrow), and the same prompt sent several times in a row is one row with a count (`×3`).

Tool calls are searched only on request (`<C-t>`), tool output never. The index keeps the first 4 KiB of each prompt and answer; copying and reusing take the full text from the transcript, and refuse with a notice when it cannot be read.

## How it works

The plugin reads the local Claude Code transcripts (JSONL files), builds an index of projects and sessions, and renders a transcript as markdown on demand. A small Rust helper (`agent-ide-helper`) can do the scanning, parsing and file watching off the Neovim process. When the helper is not built, or fails, a pure Lua implementation takes over and gives identical results. Neither path blocks the editor: the drawer opens in under 50 ms with 60 projects, a 1 MB history in under 150 ms with the helper, and a cold Lua scan never blocks the UI for more than 16 ms at a time.

## Privacy

Apart from Claude Code itself, everything stays on your machine. The plugin reads transcripts under `projects_dir` and the output of `claude agents --json`, and sends nothing over the network; what you type in a chat goes to the `claude` process it starts, which talks to Anthropic as it always does.

Prompts you save go to `stdpath('data')/agent-ide/prompts/<project folder>-<short hash>/` (and templates to `stdpath('data')/agent-ide/library` unless you set `prompts.library_dir`).

The Rust helper keeps a metadata cache in `stdpath('cache')/agent-ide/index-v3.json` (on Linux usually `~/.cache/nvim/agent-ide/index-v3.json`). It holds the path, title, working directory, branch, size and modification time of each session, so the drawer opens fast. You can delete it at any time; it is rebuilt on the next scan.

The search index is `search-v1.json` in the same folder. It holds the first 4 KiB of every prompt and answer and a one-line summary of every tool call, with the session titles and paths. It is written at most every 30 seconds; changes since the last write are indexed again on the next start (the helper is stopped right after Neovim closes its input, so a final write is not guaranteed). Both files are ignored when a different helper version, other parse rules or another file format wrote them.

Both files are as private as the transcripts they come from: the folder is created (and tightened to) mode 0700, the files are written with mode 0600 through a temporary file that is renamed into place, and temporary files left by a helper that was killed while writing are removed on the next start. You can delete either file at any time; it is rebuilt on the next scan or search.

## Roadmap

1. Drawer and history (done)
2. Chat and prompt buffer (done)
3. Prompts (done)
4. Git review: changes, commits, diff view (done)
5. Omarchy indicator (done)
6. Other agents (planned)

Search across all sessions is done as well.

## Development

```sh
make test          # mini.test suite, includes the speed budgets (clones mini.nvim into deps/)
make test-helper   # Rust tests for the helper, with the search speed budgets in a release build
make test-helper-release   # only the release-build search tests and budgets
make test-real     # drive the real Claude Code (subscription, model haiku) in a temporary git repository
make helper        # build the helper
make bench         # print the four speed measurements next to their budgets
make bench DIR=~/.claude/projects   # timings and counts for your own transcripts only
```

All test data is synthetic. `make test-real` is the exception: it talks to the real Claude Code with tiny prompts, prints only pass or fail per check, and removes its temporary repository and the transcript Claude wrote for it.
