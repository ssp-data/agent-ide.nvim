# Agent-IDE.nvim (Agents Drawer)

A Neovim plugin to run and review all your Claude Code sessions from one place: a drawer lists every session grouped by git repository, you chat in native buffers (a prompt buffer to write, a Markdown buffer to read), and you review what the agent changed with git diffs, without leaving Neovim.

YT Video with demoing the features:
[![YouTube Video](docs/images/main.png)](https://www.youtube.com/watch?v=0uQ2r7eiQjE)

> [!NOTE]
> **Agent-IDE is built for Claude Code.** Every feature here targets the Claude Code CLI on your subscription. Support for other agents (Gemini CLI, opencode, and Codex through Zed's [codex-acp](https://github.com/zed-industries/codex-acp)) exists on the [`acp`](../../tree/acp) branch, via the Agent Client Protocol. That branch is parked: matching every Claude Code feature for other agents isn't worth the effort yet, as I use Claude Code exclusively. The architecture is ready for other agents if that changes.

## Why I built Agent-IDE?

Agent-IDE.nvim is my new plugin for agent handling in Neovim, optimized for [my terminal workflow](https://www.ssp.sh/brain/my-terminal-workflow-with-macos-and-linux/). I saw a tweet, [`Herdr or Rex`](https://x.com/omarmsimon/status/2120013311681130603), and then I thought, why not in Neovim? Below is what came out of that question.

Coding is changing, from writing to more navigating and viewing changes, etc. So Neovim is great for all of it, I use nvim with lazygit for seeing all the changes and navigating around changes the agents made. So I thought, why not make it the main control center, as I did for email with [Neomd](https://github.com/ssp-data/neomd), where nvim is the composer.

I want to prompt in neovim (I use `ctrl-g`) for Claude Code anyway to type with my shortcuts [Vim Motions](https://www.ssp.sh/brain/vim-language-and-motions/) and also my snippets and superpowers, and the rendering of responses from Claude Code looks awful, unlike my rendering of Markdown within neovim. So why not use neovim to write and also show the responses in a buffer of Neovim that renders Markdown nicely? That was the premise, and the outcome looks like this:

![Agent-IDE: the drawer with all sessions, a chat and the prompt buffer](docs/images/main.png)

What you see, from right to left. **The drawer** shows the `Prompts` node (library, skills and commands) and every project with its sessions in all states: running elsewhere (`elsewhere`), waiting for a permission (`permission: Bash`), done and not read yet (`done, unread`), failed (`failed: API Error…`), idle and parked (dimmed). A project row sums its sessions up (`input (1)`, `review (1)`). Below the sessions are a branch's `Changes vs main` and `Commits on branch`, and a second worktree. **The chat** fills the main window: a rendered markdown transcript with tool calls (`Read`, `Edit`, `Bash`, `Write`) and thinking folded, and a winbar with project, title, model, permission mode and state. **The prompt buffer** below holds a draft with an `[attach]` line. **The footer** in lualine shows the overall state and the quota.

If you like set `scope = 'project'` in opts, Agent-ide will open only the project you are in right now. This is handy when you want to open agent-IDE next to your app or code, in a split view in tmux or other for example. You can also open code in Neovim, as it's Neovim right, but it works better to have one open that only acts as Prompter with agents-IDE, at least for me.

![scope project](docs/images/demo-scope-project.webp)

The diff view: what the agent changed on the branch, side by side, with your real file on the right:

![Agent-IDE: side-by-side diff of a changed file](docs/images/diff.png)

The search across all sessions, with a rendered preview of the hit:

![Agent-IDE: search picker with preview](docs/images/search.png)

The screenshots use synthetic demo sessions and repositories.

![Omarchy Plugin](docs/images/omarchy-plugin.webp)


## Focus
The features and focus are on managing all agent sessions in a single drawer, as I use [Query databases in vim (vim-dadbod)](https://www.ssp.sh/brain/query-databases-in-vim-vim-dadbod/) to query databases within nvim, that's why it's called the **Agent IDE** because it's my IDE for agents.

### Why not a Terminal TUI, why Neovim?
You might ask why not a terminal-based TUI, now that Herdr, Rex, and others are built in the terminal for agents, or even apps nowadays. The reason is that nvim is doing most of the things I like to improve anyway, and I have a 5+ year history of dotfiles for nvim, where I optimized these aspects over the years already - things like: 
- beautiful markdown rendering
- modal typing and fast moving around
- git integration with lazygit and other shortcuts
- the place to navigate and being an IDE for agents, as it has so many functionalities and is super extensible and composable

### Features List (short)
- **One drawer for all sessions**, grouped by git repository, with live state: input required, running, done, idle
- **Chat in native buffers**: write prompts with your own Vim setup, read answers as rendered markdown, tool calls folded
- **Never interrupts typing**: permission requests and finished sessions wait; one key jumps to the next one
- **Git review built in**: changes and commits per project, side-by-side diffs, jump from an edit to its diff
- **Fuzzy search** across all sessions and every prompt you ever sent
- **Reusable prompts**: a prompt library, skills and commands, saved prompts per project
- **Status in your statusline** (and an Omarchy bar widget): state, model, quota
- **Uses your Claude subscription** through the Claude Code CLI; no API key
- **Fast**: Rust helper for scanning, search and file watching, with a Lua fallback


### Why Not Tmux, Or Herdr?
Although it's not the same, the agents-IDE does an fraction of it. What's comparable is that you manage all agents sessions in one UI (currently optimized for Claude Code), but you have one "harness" for all sessions. What is not the same, it does not do any multi-plexing, obvisouly, or also can't integrate Claude Web apps, it's a terminal first, inside Neovim.

## Status

Everything above is built and in daily use: the drawer, chat with Claude Code from Neovim, reusable prompts, git review with the diff view and the commit graph, search across all sessions, and the Omarchy indicator (see `omarchy/io.github.sspaeti.agent-ide/README.md`). Other agents (Codex, Gemini, opencode) are not part of this version; the parked work is on the `acp` branch.

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
| `tmux` | optional | `gT` jumps to the pane of a session running elsewhere (the drawer then shows its pane, `tmux 2.1`) and continues a chat in native Claude in a tmux pane |
| `lazygit` | optional | `glg` in the drawer and the diff view |
| `delta` | optional | Syntax colours and word-level changes in the [full diff](#full-diff); without it the view uses the plugin's own colours |
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
  'ssp-data/agent-ide.nvim',
  build = 'make helper', -- optional; needs cargo
  cmd = 'Agents',
  keys = { { '<leader>aa', '<cmd>Agents<cr>', desc = 'Agent-IDE: toggle drawer' } },
  opts = {},
}
```

Without `cargo` leave out `build`; the plugin uses its Lua backend. If Neovim says that the helper is out of date, the helper binary was built from older sources than the plugin (both must read transcripts by the same rules); see [Settings you may need](#settings-you-may-need).

Lazy-loaded on `cmd = 'Agents'` (or the key above), the plugin starts with the first `:Agents`: until then the other global keys (`<leader>an`, `<leader>as`, `<leader>aP`), `:AgentsSearch`, the footer and the status file for a desktop bar do not exist yet. To have them from the start, load it after startup instead:

```lua
{
  'ssp-data/agent-ide.nvim',
  build = 'make helper',
  event = 'VeryLazy',
  opts = {},
}
```

## Configuration

These are the defaults. Pass only what you want to change to `setup()` (or `opts`).

```lua
require('agent-ide').setup({
  projects_dir = vim.fn.expand('~/.claude/projects'),
  drawer = { width = 44, side = 'right', legend = true }, -- legend: the state marks at the bottom (gL)
  live = { interval_ms = 5000, cmd = { 'claude', 'agents', '--json' } },
  helper = { enabled = true, path = nil }, -- nil: <plugin root>/helper/target/release/agent-ide-helper
  claude = {
    cmd = { 'claude' },     -- executable and leading arguments for the chat process
    strip_api_key = true,   -- remove ANTHROPIC_API_KEY from the environment of every Claude it starts
    model = nil,            -- model for new sessions (nil: Claude's default)
    version_check = true,   -- one notice when the installed Claude Code is not the tested version
    modes = { 'manual', 'acceptEdits', 'auto' }, -- what <S-Tab> cycles through (plan: <leader>am)
    default_mode = nil,     -- where the cycle starts before Claude reports a mode
    models = nil,           -- what the model picker offers (nil: every model Claude Code lists; a list
                            -- of names such as { 'opus', 'sonnet' } offers exactly those)
  },
  tcd = true, -- opening a session sets the tab's working directory to its project
  scope = 'all', -- 'project': start with only the repository of Neovim's working directory (see Project scope)
  -- each key option is a key, a list of keys, or false (no mapping); keys = false turns off all of
  -- these except the drawer's own keys, which then keep their defaults. Fixed, not configurable:
  -- q / <Esc> in help floats, q in the raw view, ]c / [c in the diff view, and / and @ in the
  -- prompt (chat.auto_slash, chat.at_picker)
  keys = {
    toggle = '<leader>aa',
    next_waiting = '<leader>an',
    search = '<leader>as', -- search all sessions
    prompt_history = '<leader>aP', -- every prompt, newest first
    -- the search picker's query line; close works in normal mode (insert-mode <Esc> leaves insert mode)
    search_picker = { next = { '<C-n>', '<Down>' }, prev = { '<C-p>', '<Up>' }, open = '<CR>', copy = '<C-y>',
      reuse = '<C-e>', scope = '<Tab>', kinds = '<C-f>', close = { '<Esc>', 'q' } },
    chat = { send = '<C-CR>', send_alt = '<leader><CR>', interrupt = '<C-c>', prompt = '<leader>ap', help = 'g?',
      history_prev = '<C-p>', history_next = '<C-n>', attach = '<leader>af',
      answer_inner = 'ir', answer_outer = 'ar', mode = '<S-Tab>', plan = '<leader>am', model = { '<leader>aM', '<leader>M' },
      answer = '<leader>ay', raw = 'gr', raw_event = 'gR', park = '<leader>ax', compact = '<leader>aC',
      diff = { 'gd', '<leader>gd' },
      -- native: continue in native Claude in a tmux pane; a typed key (gT) works in the transcript
      -- only, since the prompt buffer is where you edit text (gT stays Vim's there)
      native = { 'gT', '<leader>aT' },
      queue = { 'Q', '<leader>aQ' }, -- the queue panel (Q is Ex mode, which the prompt buffer does not need)
      next_session = ']s', prev_session = '[s', -- next / previous session of the project
      save_library = '<leader>W', prompts = '<leader>al' },
    -- diff view, on both sides; a one-character key (q, ?, R) only on the left side, since the
    -- right side is your own file, where they stay macro recording, search and Replace mode
    diff = { next_file = { ']f', '<leader>gj' }, prev_file = { '[f', '<leader>gk' }, flip = { 'gb', '<leader>gt' },
      branch = { 'gB', '<leader>gB' }, close = { 'q', '<leader>gq' }, help = { '?', 'g?' },
      refresh = { 'R', '<leader>gR' }, lazygit = 'glg' },
    -- the drawer's own keys (see Drawer); on a row that has its own handler for a key (the
    -- prompt row keys below) that handler runs instead
    drawer = { open = { '<CR>', 'o' }, fold = 'za', collapse_all = 'z0', expand_all = 'z9', refresh = 'R',
      tmux = { 'gT', '<leader>aT' }, search = { 'S', '<leader>ff', '<leader>S' }, park = 'sP', hide = 'H',
      delete = 'D', yank = 'y', lazygit = 'glg', close = 'q', help = { '?', 'g?' }, graph = 'G', full_diff = 'gd', scope = '<S-Tab>', legend = { 'gL', '<leader>aL' }, close_tmux = 'X', rename = 'r',
      next_session = ']s', prev_session = '[s' }, -- open the next / previous session of the project
    -- drawer, on prompt rows (elsewhere these keys keep their normal meaning)
    prompts = { edit = 'e', rename = 'r', delete = 'D', yank = 'y', to_library = 'sL' },
    -- commit graph view, buffer-local
    graph = { open = '<CR>', next_commit = ']]', prev_commit = '[[', full_diff = 'gd', all = 'a', refresh = 'R', more = 'L',
      yank = 'y', lazygit = 'glg', close = 'q', help = 'g?' },
    -- full diff view (every change of a branch in one buffer), buffer-local
    full_diff = { open = '<CR>', next_file = ']f', prev_file = '[f', next_hunk = ']c', prev_hunk = '[c', fold = 'za',
      collapse_all = 'z0', expand_all = 'z9', refresh = 'R', yank = 'y', lazygit = 'glg', close = 'q', help = 'g?' },
  },
  prompts = {
    library_dir = nil,  -- your templates (nil: stdpath('data') .. '/agent-ide/library')
    saved_dir = nil,    -- per-project saved prompts (nil: stdpath('data') .. '/agent-ide/prompts')
    command_dirs = { '~/.claude/commands' }, -- Claude's commands (read only)
    skill_dirs = { '~/.claude/skills' },     -- Claude's skills (read only)
    project_dirs = true, -- also <project>/.claude/commands and /skills of the chat's project
  },
  quota = { file = nil }, -- footer quota from a file another tool writes (see Footer); nil: off
  trash = { keep_days = nil }, -- deleted sessions (D) older than this are purged at setup; nil: kept until :AgentsTrash empty
  chat = { auto_slash = true, at_picker = true, prompt_label = true }, -- `/` opens the command menu, `@` the file picker; the prompt's `↑ title · model` label
  -- the size of a session's conversation (see Token usage): from `threshold` tokens on (false: never)
  -- a send that resumes a parked session asks first (Send / Compact first / Cancel) and parking
  -- offers a /compact first; each question can be turned off on its own
  context = { threshold = 50000, confirm_resume = true, compact_before_park = true, large = 200000 },
  -- a soft chime when a session needs you; chime: 'two', 'soft', 'bell', 'rising' or 'pop'
  -- (:AgentsChime <name> plays one); cmd: the player (nil: pw-play, paplay, aplay or afplay,
  -- whichever exists), the chime's WAV path is appended to it
  sound = { waiting = true, chime = 'two', cmd = nil },
  -- Claude runs under a small detached process of the plugin's (a keeper), so quitting Neovim
  -- leaves it running and a new Neovim reattaches (see Background sessions); idle_minutes: an
  -- idle Claude with no Neovim attached is closed after that long (false: never).
  -- enabled = false: Claude is a child of Neovim and ends with it, as before
  keeper = { enabled = true, idle_minutes = 30 },
  icons_style = 'nerd', -- 'nerd' (needs a Nerd Font) or 'plain' (characters of any monospace font)
  icons = {}, -- override single icons of that set, for example { busy = '*', changes = '' }; '' hides one
})
```

Icon keys: `open`, `closed` (fold arrows), `prompts`, `changes`, `commits`, `worktree`, and the session states `waiting`, `busy`, `idle`, `parked`, `done`, `failed`. Both sets use `▾ ▸` for folds, `⎇` for a worktree and the characters `● ◐ ● ○ ✓ ✗` for waiting, busy, idle, parked, done and failed (waiting and idle differ by colour). The nerd set differs in two places only: a pencil glyph (nf-md-pencil_outline) on the Prompts row and one git glyph (nf-oct-git_compare) on both the `Changes` and `Commits` rows. Nothing else carries an icon: no project icon, no section icons, no per-kind prompt icons.

`:Agents` (or the toggle key) opens the Agents tab with the drawer. Inside the Agents tab it closes or reopens the drawer; from any other tab it switches to the Agents tab.


## Components
### Drawer

The drawer has no header line; `?` lists every key. Each row shows its state mark and title on the left and, aligned to the right edge, what needs you and how old it is; a title too long for the drawer is cut with `…`, the right part never.

| Row | Right part |
|---|---|
| Session waiting for you | `permission: <tool>`, `question` or `plan to approve` (in another Claude: `input`) |
| Session done or failed while you were elsewhere | `done, unread`; `failed`, with the start of the error when there is one |
| Session running in another Claude | `tmux <window>.<pane>` when Neovim runs inside tmux and the session in one of its panes, else `elsewhere`; handed to native Claude: `native` |
| Project | the state icon of its most urgent session; `input (n)` while sessions wait, `review (n)` for done or failed ones; then the age of its newest session |
| Changed file, commit | `+added −removed`, the commit's age |

Ages read `now`, `5m`, `3h`, `12d`, then months (`14mo`) and years (`2y`). Colours: waiting violet (bold), busy yellow, idle a filled mark in mid grey (`●`; parked is the hollow `○` in the dimmer comment colour), done orange, failed red, parked rows (mark, title, age) and ages dimmed, never italic; the groups are `AgentIdeWaiting`, `AgentIdeBusy`, `AgentIdeIdle`, `AgentIdeDone`, `AgentIdeFailed`, `AgentIdeParked`, `AgentIdeAge` and `AgentIdeSection`, and a colorscheme can set them. The dim groups (`AgentIdeParked`, `AgentIdeAge`, `AgentIdeMissing`, `AgentIdeBranch`, `AgentIdeGitUntracked`) take the foreground of `Comment` at setup and on every `ColorScheme`, without italic or bold. A project row is its fold arrow and bold name; a parked project's name is dimmed. A project whose folder is gone says `(folder missing)`; a session started in a sub-folder of its project shows `<subfolder>/ · <title>`.

**Legend.** The bottom of the drawer explains the state marks: `● input  ◐ running  ● idle  ○ parked  ✓ done  ✗ failed`, each mark in its colour (the marks of your icon set), over one or two lines. It stays put while the list scrolls, never takes the focus and never covers the cursor row (the list scrolls instead). It hides itself while the drawer is shorter than 12 lines or narrower than 24 columns. `gL` (or `<leader>aL`) shows or hides it, and that choice is remembered across restarts (`prefs.json`); `drawer = { legend = false }` is the start before you ever toggled it.

**Session names.** A session's title is what Claude Code wrote for it (its own title, else your first prompt), which says little about a session you keep coming back to. `r` on a session row asks for a name of your own; the drawer, the chat's winbar, the buffer names, search results and the footer then show that name instead. Nothing in Claude's files changes, and nothing is inferred: the mapping is a small file of the plugin's, `names.json` (see [Privacy](#privacy)), shared by several Neovims. An empty answer, or the title itself, brings Claude's title back.

**Hidden sessions.** `H` on a session row hides it: nothing is deleted, the session only moves into a collapsed, dimmed `Hidden (n)` group, the last row of its project's `Sessions (n)` section (which counts the visible ones only). `<CR>` or `za` expands the group; its rows open like any other session, and `H` on one shows it again. Hidden sessions do not count for the project's age, order or state mark, except while one needs you: a hidden session that is waiting, busy, done-unread or failed is listed among the normal rows (and counted in the roll-up, the footer and `<leader>an`) for as long as that lasts. A project whose sessions are all hidden still shows, with `Sessions (0)` and its group. Search finds hidden sessions as usual. The list is kept in `hidden.json` (see [Privacy](#privacy)); several Neovims share it.

### Project scope

With many sessions across many repositories, large ones can bury the session you are after. The project scope narrows Agent-IDE to one repository: the drawer, search, `<leader>an` and the footer then show only that project. You can, for example, run one Neovim per project in project scope, and open the overview only now and then.

- **Setting.** `scope = 'all'` (the default) or `scope = 'project'` in `setup()` decides how each Neovim starts. The scope belongs to one Neovim and is not saved.
- **Commands.** `:Agents project` switches to the project of Neovim's working directory (the global one, `:pwd`) and opens the drawer if it is closed. Each run looks at the working directory again, so after a `:cd` it re-anchors. `:Agents all` goes back to every project. `:Agents` alone toggles the drawer as before, in the current scope.
- **Key.** `<S-Tab>` in the drawer flips between the two. From `all`, on a row of a project (its row, a session, a section), it narrows to that project; elsewhere to the working directory's.
- **Which project.** The same one the drawer groups by: the git repository root, with its sub-folders and linked worktrees folded in; a folder without git is its own project. A repository without sessions yet shows `Sessions (0)`, and `+ New session` starts in its root.

In project scope the drawer has no project row. Its first, dimmed line names the project and branch and says `<S-Tab>: all` (`<CR>` on it goes back to all). Below it come the Prompts node, then `+ New session`, `Sessions (n)` (open), `Saved prompts`, `Changes` and `Commits`, all at the top level. Every drawer key works as usual on these rows. Sessions of other projects keep running in this Neovim, they are just not listed. When one of them needs you (waiting, done unread, failed, also a Claude in a terminal that waits for input), a dimmed last line says so, for example `1 session in other projects needs you · <S-Tab>`, and `<leader>an` with nothing to do in the project says `nothing in this project; 1 in other projects (<S-Tab>)`. Each scope remembers its own open folds.

Search (`<leader>as`, `<leader>aP`, `S` outside a project row) opens on `project <name>`, and `<Tab>` widens it to all sessions. The status file for the desktop bar keeps listing all sessions of this Neovim. `:AgentsCloseIdle` closes only the project's idle terminal sessions (its confirm names the project); `:AgentsCloseIdle!` closes those of every project. The prompt history (`<C-p>`, `<C-n>`) is the session's own in either scope, so it never shows prompts of another project.

Open a terminal straight into a project:

```sh
nvim +'Agents project'
```
### Deleting sessions

Claude Code has no command to delete one session. `D` on a session row (also in a `Hidden` group) moves what Claude keeps of it into the plugin's trash, after a confirm (default: no). Claude's folder is the parent of `projects_dir` (by default `~/.claude`). Moved, when present:

- the transcript `projects/<slug>/<id>.jsonl` and the folder beside it, `projects/<slug>/<id>/` (subagents, tool results);
- `file-history/<id>/`, `session-env/<id>/`, `tasks/<id>/`;
- the lines of `history.jsonl` that belong to the session (the prompts you typed); every other line stays byte for byte, and the plugin detects and carries over lines appended during the rewrite.

Not removed: pasted-text cache files (`paste-cache/`), usage statistics (`stats-cache.json`) and settings. Only an inactive session can be deleted: `D` is refused while the session is active in this Neovim (park it first with `sP`), handed to native Claude, running in another Claude (asked afresh with `claude agents --json`; when that fails, nothing is deleted), or while its prompt holds unsent text. Its chat and raw buffers are closed and it leaves `hidden.json`.

The trash is `stdpath('data')/agent-ide/trash/<YYYYMMDD-HHMMSS>-<id>/` (folder `0700`; files keep their modes): the moved entries in their layout, `history.jsonl` with the removed lines and `manifest.json` (where each entry came from, title, project, time). **The trash still holds the whole session**, prompts and answers included, until you empty it: for sensitive data run `:AgentsTrash empty` afterwards. `:AgentsTrash` lists the trashed sessions to restore one (refused when something is at its old place; the history lines go back in time order) or delete it for good; `:AgentsTrash empty` deletes all of them for good after a confirm. Nothing is purged automatically unless you set `trash = { keep_days = 30 }`, which purges older entries at setup.


#### Closing terminal sessions

`X` on a session row that runs in another Claude in a tmux pane (the row shows `tmux <window>.<pane>`) ends that Claude the way you would there: Ctrl-C into the pane, and again 300 ms later (Claude's own exit). Text typed in that Claude's input box is lost. The confirm (default: no) comes first, right on the key; a session that is working or waiting for input asks a second time. Only then does the plugin check, afresh: Claude still lists the session with the same process (and still idle, if idle is what you confirmed); that process is a Claude (`claude`, or `node` for an npm install) on the terminal of a tmux pane and is that terminal's foreground program (so not suspended with Ctrl-Z behind another program, not a Claude another Neovim started, not one in a Neovim `:terminal`); the pane is in no mode (such as copy mode) and its window does not synchronize panes. If any of that does not hold, nothing is sent and a notice says why. The process itself is never signalled. If Claude still runs 5 s later, a notice says so and nothing more happens. Outside tmux `X` says it cannot reach the session (`gT` jumps to it); for a session running in this Neovim use `sP`. `:AgentsCloseIdle` closes every Claude that is idle in a tmux pane after one confirm (with their count when the drawer's live state is current), the same checks for each, and then says how many it closed and how many it skipped and why; in project scope only those of the project (`:AgentsCloseIdle!` for all).

### Keys

Global:

| Key | Action |
|---|---|
| `<leader>aa` | Toggle the Agents tab (same as `:Agents`) |
| `<leader>as` | Search all sessions (`:AgentsSearch [query]`) |
| `<leader>aP` | Prompt history: every prompt you sent, newest first |
| `<leader>an` | Go to the next session that needs you: one waiting for your answer here (oldest ask first), then one waiting in another Claude (jumped to in tmux), then a failed turn, then a finished turn you have not seen; from the first of them, the one after it |

In the drawer (`keys.drawer`; the prompt row keys are `keys.prompts`, the session row keys the chat's, `keys.chat`):

| Key | Action |
|---|---|
| `<CR>`, `o` | Expand or collapse a project; open a session; start a new session (`+ New session`; pressed again while that one has sent nothing, it comes back with its draft; `2<CR>` starts a separate one); use a prompt |
| `za` | Expand or collapse the node under the cursor |
| `z0` | Collapse all: only the top-level rows remain (a project opened again shows its sessions) |
| `z9` | Expand all projects with their `Sessions`; `Changes`, `Commits`, `Saved prompts`, `Hidden` and the Prompts node stay as they are (opening them loads git or prompts for every project). `z9` again, with nothing changed in between, opens everything (a commit's own file list excepted). Git counts of closed sections load a few projects at a time |
| `R` | Rescan sessions and refresh running state |
| `gT`, `<leader>aT` | To tmux: on a session running elsewhere, jump to its tmux pane; on any other session, continue it in native Claude in a tmux pane (see [Native Claude](#chat)) |
| `S`, `<leader>ff`, `<leader>S` | Search the sessions of the project under the cursor |
| `sP` | Park the session: stop the Claude process this Neovim runs for it |
| `H` | Hide the session into its project's `Hidden (n)` group; on a hidden session: show it again (Vim's `H` motion is not available in the drawer) |
| `r` | Session row: give the session a name of your own (see [Session names](#session-names)); empty, or the title itself, brings Claude's title back. Prompt row: rename the file |
| `D` | Session row: delete an inactive session, moving it to the plugin's trash after a confirm (see [Deleting sessions](#deleting-sessions)). Prompt row: delete the file (asks first) |
| `y` | Session row: yank the last prompt sent in it. Prompt row: yank its text (unnamed and `+` registers). Elsewhere Vim's `y` |
| `<leader>aM` / `<leader>M`, `<C-c>`, `gr` | On a session row, what they do in its chat, for that session and without opening it: pick the model, interrupt (only while Claude works, after a confirm), raw view in the main window. A session without a process takes the model when it starts; one running in another Claude is refused (the raw view still opens). On other rows `<C-c>` keeps its Vim meaning. (The chat's mode key, `<S-Tab>`, is the drawer's scope key, so the mode cycle is not on the row; remap `keys.chat.mode` to have it there) |
| `X` | Close the Claude that runs the session in a tmux pane, after a confirm (see [Closing terminal sessions](#closing-terminal-sessions)) |
| `Q`, `<leader>aQ` | On any row: show or hide the queue panel of the chat (see [Queue panel](#queue-panel)); on a session row while no chat is open, open that session with its panel, the focus staying in the drawer |
| `q` | Close the drawer |
| `gL`, `<leader>aL` | Show or hide the legend of the state marks (remembered) |
| `]s`, `[s` | Open the next or previous session of the project (from the session row, else the chat shown); the drawer keeps the focus and its cursor follows |
| `G` | Commit graph of the row's repository (a worktree session: that worktree; see [Commit graph](#commit-graph)) |
| `gd` | Full diff of the row: its project or section (the branch, or the commits), a commit, or a file with the cursor on it (see [Full diff](#full-diff)) |
| `glg` | Open lazygit for the row's repository (a worktree row or session: that worktree) |
| `<S-Tab>` | Scope: only the row's project (else the working directory's), or back to all projects (see [Project scope](#project-scope)) |
| `?`, `g?` | Help: a list of every key you can filter by typing; `<CR>` on a row presses that key (see [Help](#help)) |
| `e` | Prompt row: edit its file in the main window (Claude's commands and skills open read-only) |
| `r` | Prompt row: rename (library: `group/name` moves it to another group) |
| `sL` | Saved prompt row: copy it into the library (asks for a name) |

Each of these is a key, a list of keys, or `false`. A prompt row key acts on prompt rows even when a drawer key has the same lhs (`D`, `y`); elsewhere in the drawer it keeps its Vim meaning. The session row keys are the chat's (`keys.chat`), so a remap applies to both.

In the chat (transcript and prompt buffer, unless noted):

| Key | Action |
|---|---|
| `<C-CR>` | Send the prompt (normal and insert mode) |
| `<leader><CR>` | Send the prompt |
| `<C-c>` | Normal mode: interrupt Claude; queued prompts come back into the prompt buffer |
| `<leader>ap` | Focus the prompt |
| `i`, `a`, `o` | Transcript: write in the prompt |
| `<leader>ay` | Answer what Claude asks (permission, question, plan) |
| `<S-Tab>` | Next permission mode (manual, acceptEdits, auto); in plan mode, leaves it |
| `<leader>am` | Plan mode on, or off again (back to the mode you had before) |
| `<leader>aM`, `<leader>M` | Pick the model |
| `<leader>ax` | Park the session: stop its Claude process (asks when it is working; a large conversation is offered a `/compact` first); the next send resumes it |
| `<leader>aC` | Send `/compact`: Claude summarizes the conversation in one request that reads all of it, and every turn after it is smaller. Queued behind a running turn; a parked session is resumed for it |
| `gT`, `<leader>aT` | Continue the session in native Claude in a tmux pane; while it is there, take it back (`gT` in the transcript only; the prompt buffer keeps Vim's `gT`) |
| `gr` | Transcript: raw view of what was sent and received; `q` or `gr` returns |
| `gR` | Transcript: raw view at the line of the `unknown` fold under the cursor |
| `ir`, `ar` | Transcript: text object for one Claude answer (`ar` with its header) |
| `gd`, `<leader>gd` | Transcript, on an `Edit` or `Write` fold: the branch diff of that file |
| `<C-p>`, `<C-n>` | Prompt: older or newer prompt, normal and insert mode (also `<Up>` on the first line, `<Down>` on the last) |
| `<leader>af` | Prompt: pick a file and add an `[attach]` line |
| `/` | Prompt, on an empty line: the command menu; typing narrows it (fuzzy), nothing is inserted until you choose (`<C-n>`, `<C-y>`) |
| `@` | Prompt, at line start or after a space (not in a code fence): pick a file to attach at that spot |
| `<leader>al` | Pick a prompt: saved prompts, library, Claude's commands and skills |
| `<leader>W` | Prompt: save it to the library (asks for a name; `group/name` makes a folder) |
| `Q`, `<leader>aQ` | Show or hide the queue panel (see [Queue panel](#queue-panel)) |
| `]s`, `[s` | Open the next or previous session of the project, in the drawer's order (wraps around, hidden sessions skipped); focus stays where you pressed it and the drawer's cursor follows. In the prompt they replace Vim's spelling motions |
| `:w`, `:x`, `ZZ` | Prompt: save it (see [Prompts](#prompts)); `:x` and `ZZ` then hide the window |
| `za` | Toggle fold |
| `:q` | Prompt: hide the window; the draft stays |
| `:q!` | Prompt: hide the window and discard the draft |
| `g?` | Help, filterable (`?` stays Vim's backward search) |

The history buffer is markdown with folds for tool calls, results and thinking. Claude's own words, an answer or a remark between two tool calls, start with a green `●` (`AgentIdeAnswerMark`; virtual text, so yanks and the `ir` / `ar` text objects copy the words only), while it streams too. An `Edit` fold shows the edit as a diff: the unchanged lines of the old text as context (three around each change, the rest counted as `… n unchanged lines`), the removed lines red and the added ones green (`AgentIdeDiffDel`, `AgentIdeDiffAdd`), and inside a changed line the text that differs with its colour as the background (`AgentIdeDiffDelText`, `AgentIdeDiffAddText`), so what changed stands out at a glance. `Edit` folds start open, so you watch the changes as they come (`za` folds one, `zM` all); `gd` on the fold opens the branch diff of that file. In a `Bash` fold the command has its own colour (`AgentIdeCommand`), apart from its output. Colour codes in tool output show as the colours they stand for, from your colorscheme's terminal palette, and the raw view keeps the exact bytes. Anything the viewer does not understand is shown as a fold marked `unknown`, never dropped, and truncated output says how many lines are hidden.

#### Help

`?` in the drawer and `g?` in every view open the keys of that view as a palette: a query line over the list. Type to filter it (fuzzy: `legnd` finds the legend key), `<C-n>` / `<C-p>` or the arrows move, `<CR>` closes the help and presses the selected key in the window you came from, so the help doubles as a command palette. `<Esc>` leaves the query line, and `<Esc>` or `q` there closes the help. With an empty query the keys show in their groups.

### Chat

Open a session from the drawer, or start one with `+ New session` under a project. The transcript fills the main window of the Agents tab and a prompt buffer opens below it. Opening a session shows its history without starting Claude; the first prompt you send starts `claude -p` for it (resuming the session when it has a history), and the process keeps running until you park the session (`<leader>ax`, or `x` in the drawer), hand it to native Claude, or quit Neovim. Parking asks first when Claude is working (and, between turns, offers to compact a large conversation first), puts queued prompts back into the prompt buffer, and keeps the transcript; the next prompt resumes the session. The winbar shows the state as the drawer does (its mark and word in the same colours: `● permission: Bash`, `◐ busy`, `✓ done, unread`, `✗ failed: <reason>`, `◐ tmux 2.1`), the number of queued prompts, the project in bold and the title, and on the right the model in italic (`AgentIdeModel`), the size of the conversation (`~123k`, in `AgentIdeContext`; see [Token usage](#token-usage)) and the permission mode as a badge (`[manual]` in `AgentIdeMode`; any other mode, such as `[acceptEdits]`, `[plan]`, `[auto]` or `[bypassPermissions]`, in `AgentIdeModeHot`, linked to `WarningMsg`). It fits its window: the title is cut with `…` first, then the model, the queue count and the badge give way (the project takes what is left), and only last the state word is cut. In a tabline, a bufferline or `:ls` the chat's buffers are named after the session: `agents://<project>/<title>` for the transcript and `… · prompt` for the prompt buffer (`agents://drawer`, `agents://help` and so on for the rest); the names follow the title, never stand for a file and change nothing about `:w` or `ZZ`. The prompt window's own winbar names the session it sends to, dimmed on the right (`↑ <title> · <model>`, `AgentIdePromptLabel`; `chat.prompt_label = false` turns it off). Put another session's transcript into the window above (`:b`, a jump) and its prompt follows below; while you type, the prompt stays and the label says `prompt of <title> · not the transcript above` in `AgentIdePromptOther` (linked to `WarningMsg`).

**Prompt buffer.** A normal markdown buffer (long lines wrap): write as much as you like and send it with `<C-CR>`. Its text is sent as typed, except that an `[attach] <path>` line outside a fenced code block (a fence starting at column 0) becomes `@<path>` on the same line (`@"<path>"` when the path holds spaces), which makes Claude read the file; nothing is moved or reordered. `@` at the start of a line or after a space, outside a fenced code block, opens a file picker and puts the file where you typed `@`: in a line of text as `@<path>` followed by a space, on an empty line as an `[attach] <path>` line, so references stay in place in a long text. Text you type while the file list loads does not move that spot. Cancelling the picker leaves the `@` you typed. `<leader>af` in normal mode adds an `[attach]` line above the cursor's line. `/` on an empty line opens the command menu: the commands the session listed and the commands and skills the Prompts node finds on disk and, on top, two of the plugin's own, marked `plugin`: `/model` opens the model picker and `/copy` copies the last answer to the unnamed and `+` registers. They act when chosen from the menu or sent as the whole prompt, and are never sent to Claude. Claude sends its command list with each turn, so before a session's first turn the menu is filled from the last list known for its project (else the most recent list of any project), kept across restarts in `commands.json`. `<C-p>` and `<C-n>` step through the prompts of the session, in normal and insert mode, as do `<Up>` on the first line and `<Down>` on the last (elsewhere the arrows move the cursor; while a completion menu is open the keys work the menu). The draft you were writing comes back when you step past the newest prompt.

**Drafts.** What you type in a prompt buffer is also kept on disk, so a prompt closed by accident or a Neovim that dies does not lose it: `stdpath('state')/agent-ide/drafts/<session id>.md` (a small frontmatter with the session id and project folder, then the text as typed), written half a second after a change and when you leave the buffer or Neovim. A successful send, `:q!` (the explicit discard) and deleting the session remove it. When a session's prompt opens again the draft comes back with a notice. `+ New session` takes over the newest draft an earlier Neovim left for an unsent new session of that project, so a draft of a session that never got a prompt is not lost either.

**While Claude works.** Answers stream into the transcript. A prompt sent while a turn runs is queued by the plugin and sent after that turn, in order. `<C-c>` interrupts the turn and puts the queued prompts back into the prompt buffer.

**Queue panel.** `Q` opens a narrow window left of the transcript with the session's prompts as a timeline: every prompt you sent, the first one too (dim, `✓`; the panel opens at the end), the one Claude works on (`◐`, or `●` while it waits for you) and the ones queued behind it, numbered. It never takes the focus, follows the chat when you open another session, and redraws as prompts go out. `Q` works in the chat, in the drawer (on any row) and in the panel itself, so the panel is one key away wherever you are. In the panel, `<CR>` on a sent or running prompt puts the transcript cursor on it and `<CR>` on a queued one focuses the prompt buffer; `x` takes a queued prompt out of the queue, back into the prompt buffer above your draft; `e` opens a queued prompt in a buffer of its own, where `:w` puts the edited text back in its place in the queue (an empty save takes it out); `dd` deletes a queued prompt (its text goes to the unnamed register) and `J` / `K` move one down or up. Claude only sees a prompt when it starts, so a queued one can be changed until then; one that started while you edited it stays as it was, and `:w` says so. Claude Code reads a prompt sent during a turn only after that turn ends; to have it read sooner, interrupt (`<C-c>`) and send again. `q` closes the panel, `g?` lists its keys.

Below the prompts the panel shows what the session weighs and what its turn does, so a session that grows heavy is visible before the limit is:

```
Session  ~412k  ▲ large
  turn 6m12s · 38 requests

Agents · 2 running · 1 done · 54 req
◐ Explore  find fold callers
    ~58k · 14 tools · Grep
◐ general-purpose  rewrite budget test
    ~97k · 31 tools · Bash
✓ Plan  design the cursor state
    ~41k · 9 tools · 2m03s
```

`Session` is the size of the conversation, the same `~412k` as the winbar, marked `▲ large` from `context.large` tokens on (200 000; `false` never marks). `turn` is how long the current turn runs and how many requests it made to the model: each request reads the whole conversation again, so many requests on a large conversation are what uses up a session limit. Under `Agents`, every subagent of the turn: its type and task, its own context, its tool uses and the tool it runs now (or how long it took), and in the header the requests the agents made together. `<CR>` on an agent puts the transcript cursor on the call that started it. A background agent stays listed until its task finishes, across turns. Everything comes from what Claude already sends (the `usage` of each message, the agent calls and their results); nothing asks the model. For a session not run in this Neovim (parked, or in a terminal), the agents of its last turn are listed from the transcript, without sizes or times.

**Permissions, questions and plans.** When Claude asks to use a tool, the ask shows at the end of the transcript and in the drawer, and a picker opens with Allow, Deny and the suggestions Claude made (switch the mode for this session, or always allow a rule; offered only where Claude saves it in this project's local settings, and labelled so). The picker opens only when you are in that session's chat in normal mode. Nothing ever interrupts you: an ask from another session never opens a popup, moves the cursor or takes focus; it shows in the drawer and in the footer, and `<leader>an` takes you there. While you type in the same session's prompt, a one-line hint appears instead; `<leader>ay` opens the picker, also again after a picker was closed without an answer. Questions Claude asks (multiple choice) are answered the same way, one picker per question; a multi-select question takes one option per round until you pick Done choosing. A plan from plan mode can be approved, approved with edits accepted for the rest of the session, or sent back with Keep planning. A soft chime plays when a session of this Neovim starts waiting for you (at most once every two seconds), through `pw-play`, `paplay`, `aplay` or `afplay`, whichever is installed, or the player you set in `sound.cmd`; `sound = { waiting = false }` turns it off. Five chimes to choose from with `sound.chime`: `two` (two rising notes, the default), `soft` (one low note), `bell` (one ringing note), `rising` (three quick notes) and `pop` (a short blip); `:AgentsChime bell` plays one so you can pick. Each is a small WAV the plugin generates once, `stdpath('cache')/agent-ide/chime-<name>.wav`, nothing is downloaded.

**Mode and model.** `<S-Tab>` cycles the permission mode (manual, acceptEdits, auto), `<leader>am` turns plan mode on and off again, and `<leader>aM` (or `<leader>M`) picks the model. Before a session's first prompt the winbar and the prompt's label name the model it will start with: the one you picked for it, else `claude.model` when set, else, for a session that has answered before, the model of its last answer (from its transcript), else the model last used in this plugin (the last one picked, or reported by a Claude it started; kept in `prefs.json`), else Claude's own default (`default`, or its name when Claude's list is known). New and resumed sessions start with that model, so a model picked in one session never changes another. The winbar shows `old→new` until Claude confirms a change; a refused change says why. The picker lists every model your Claude Code offers, with name and description (`Fable 5.2 — … (claude-fable-5-2)`, the current one marked `●`), as Claude reports them when a process starts (no turn, kept in `models.json`; on a fresh install a short-lived Claude is asked first, for at most 1.5 s), and the winbar and the prompt's label name the model the same way (`fable 5.1`).

**Raw view.** `gr` in the transcript shows every line sent to Claude (`>>`) and received (`<<`) for the session, byte for byte; for a session that did not run here it shows the transcript file. Anything the chat cannot render shows as an `unknown` fold, and `gR` on it opens the raw view at its line.

**Native Claude.** `gT` (or `<leader>aT`) inside tmux parks the session (after a question when Claude is working), opens `claude --resume <id>` in a split pane, and takes the session back when that pane ends (also when it is killed). Until then the winbar's state word says `native` and sending is refused; the key again offers to take the session back, which is refused while native Claude still runs it. The session is reloaded from disk in the background: a chat on screen is refreshed in place, otherwise a notice says it is back. Outside tmux the key parks the session and shows the command to run.

**Quitting.** With keepers on (the default) quitting never ends a Claude: see [Background sessions](#background-sessions). With `keeper = { enabled = false }` Claude is a child of Neovim; quitting while a session is working then asks first, and `:qa!` and the other forced quits do not ask.

**Subscription.** The plugin removes `ANTHROPIC_API_KEY` from the environment of every Claude process it starts, so Claude uses your subscription login and never bills an API key (`claude.strip_api_key = false` keeps it).

### Background sessions

Every Claude the plugin starts runs under a **keeper**: a small headless Neovim of the plugin's own (`nvim --headless --clean -l lua/agent-ide/keeper/main.lua`), started detached, that owns Claude's pipes and keeps every line sent and received. Quitting Neovim, on purpose or by a crash, leaves Claude running: a turn goes on, an ask waits, and the prompts still queued are handed to the keeper, which sends them one after the other as each turn ends. Nothing is lost and nothing asks you before you quit.

A new Neovim finds the keepers (their files in the runtime folder) and shows their sessions in the drawer with the state the keeper knows, the dim word `background` behind a running or idle one and `input` behind one that waits for you; the footer and `<leader>an` count them too. Opening such a session, or sending to it, attaches: the transcript before the keeper's Claude started comes from disk, the keeper replays everything since through the same decoder the live chat uses, so the events, the text that was streaming, the open asks, model, mode and state come back as the earlier Neovim had them, and the chat goes on live. Only one Neovim drives a session at a time: a second one is told so and shown the transcript from disk.

An idle Claude with no Neovim attached is closed by its keeper after `keeper.idle_minutes` (30; `false` keeps it forever); the session resumes from disk the next time you send to it. Parking (`sP`, `<leader>ax`) and the quit of a keeper's Claude work as before: the keeper closes Claude's input and, after half a second, ends the process; then the keeper exits. If a keeper itself dies, Claude loses its pipes and exits on its own; the session is parked with an `error` line saying `keeper lost`.

Rules that still hold: the keeper is the plugin's own process, started with the same command, folder and environment (the API key stripped) as a direct Claude would be; nothing is ever sent to a Claude the plugin did not start; the keeper's files are in the plugin's runtime folder, 0600 in 0700, and go with the keeper. `keeper = { enabled = false }` returns to Claude as a child of Neovim.

### Footer (Statusline in Neovim)

`require('agent-ide').statusline()` gives a short text for a statusline: the state of all sessions and the quota used (the model is named in the chat's winbar and on its prompt window) (percent used, with a small bar that fills as you use it):

| Level | Colour | Text | When |
|---|---|---|---|
| 1 | green | `agents ok` | nothing running or waiting |
| 2 | yellow | `agents running (n)` | sessions are working |
| 3 | orange | `review (n)` | a turn ended (or failed) in a session you have not looked at since |
| 4 | violet | `input required (n)` | Claude waits for your answer |

followed by, for example, ` · 5h ▰▱▱▱▱ 18% · week ▰▰▱▱▱ 36%`. The quota comes from the rate-limit reports of the Claude processes this Neovim runs (kept across restarts): `5h`, `week`, and `week <model>` for a per-model weekly window; overage windows only when there is nothing else. Values older than 10 minutes say how old they are (` · 25m old`); after an hour, or once a window's reset time has passed, its bar is drawn dimmed with `?` instead of the percentage. The plugin never reads credentials and never asks the network for the quota.

**`quota.file`.** If another tool on your machine already keeps the usage up to date, point `quota.file` at the JSON file it writes, `{ "limits": [ { "label": "…", "percent": 0.42, "resetsAt": "2026-11-10T18:00:00+01:00" } ], "updatedAt": "…" }` (`percent` is the fraction used, 0 to 1; a value above 1 is read as percent; `resetsAt` and `updatedAt` are ISO 8601 times or epoch seconds; without `updatedAt` the file's modification time counts; other fields are ignored). The footer then shows those limits, with their labels, instead of its own. It reads the file at most once a minute, without blocking, and falls back to its own values while the file is missing, unreadable, malformed or older than 30 minutes. For example, Omarchy's agents panel writes such a file:

```lua
opts = { quota = { file = '~/.local/state/omarchy/agents/usage/claude.json' } }
```

`statusline_hl()` names the highlight group of the level (`AgentIdeLevel1` to `AgentIdeLevel4`). For lualine:

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

### Git: what an agent changed

Each git project in the drawer has two more sections below its sessions: `Changes vs <base>` (everything on the branch since it left the default branch, uncommitted and untracked files included; on the default branch, uncommitted changes against `HEAD`) and `Commits on branch` (`Recent commits` on the default branch), each commit expanding to its files. The commits section starts with the `commit graph` row and `uncommitted (n)`: what is not committed yet, the working tree and the index against `HEAD` with untracked files, expanding to its files like a commit; `<CR>` on one of them diffs your working file against `HEAD`. The project row shows the branch when it is not the default branch. The lists refresh when a session of the project run in this Neovim finishes a turn, on `R`, and when you come back to the drawer after more than 5 s.

`<CR>` on a file opens a side-by-side diff in the main window, built on Neovim's own diff mode. For branch changes the right side is your real, editable file. In the chat, `gd` (or `<leader>gd`) on an `Edit` or `Write` fold opens the diff of that file. Opening a diff sets the Agents tab's directory to that work tree (`tcd`, like opening a chat), so your own lazygit or picker keys work on it. Sessions in a linked worktree get a row per work tree (worktree icon, `<branch> · <folder>`) with its own Changes and Commits.

| Key (diff view) | Action |
|---|---|
| `]f`, `<leader>gj` / `[f`, `<leader>gk` | Next / previous changed file |
| `gb`, `<leader>gt` | This file in one commit only (pick which); again: back to the whole branch |
| `gB`, `<leader>gB` | Back to the whole-branch diff |
| `R` (left side), `<leader>gR` | Reload the list and the base side |
| `]c` / `[c` | Next / previous hunk (Neovim's motions, also when a filetype plugin maps these keys) |
| `glg` | lazygit for this repository |
| `q` (left side), `<leader>gq` | Close the diff, back to what was shown before (`:q` on either side too) |
| `?` (left side), `g?` | Help |

The right side is your own file, so the one-character keys `q`, `?` and `R` are mapped only on the left (base) side; on your file they stay macro recording, backward search and Replace mode, and the `<leader>g…` and `g?` forms work on both sides. Your own buffer-local mappings on the right side are put back when the diff closes. The keys are under `keys.diff` (and `keys.chat.diff`) in the configuration; each value is a key, a list of keys, or `false`. Git is only read (`git --no-optional-locks`, never a command that writes); acting is left to lazygit.

#### Full diff

To read a whole branch top to bottom instead of file by file, open its **full diff**: one read-only buffer in the main window with every changed file, the way lazygit shows a branch. Each file starts with a header line (status, path, `+added −removed`), then only its hunks with three lines of context, in Neovim folds, a blank line between files. The `@@` lines are dim (`AgentIdeDiffHunk`). Binary files, submodules and files too large to read get a one-line note (`AgentIdeDiffNote`); untracked files show as added lines. A file whose patch is longer than 500 lines starts folded. The winbar names the scope and sums it up: `myapp · full diff · vs main · 12 files +340 −120`.

**Colours.** With [delta](https://github.com/dandavison/delta) installed, the patch goes through `delta --color-only` and you get what delta gives you in lazygit: syntax colours, a background per changed line and the changed words stronger, in your delta configuration (`~/.gitconfig` `[delta]`), after Neovim's `background` (`--dark` or `--light`). Tabs and long lines pass through unchanged. Patches over 20 000 lines, and everything without delta, use the plugin's own colours: whole lines as Neovim's diff mode shows them (`AgentIdeFullDiffAdd` and `AgentIdeFullDiffDel`, linked to `DiffAdd` and `DiffDelete`) and the changed text inside a modified line marked like its `DiffText` (`AgentIdeFullDiffText`). `git = { delta = false }` turns delta off, a command list of your own (`delta = { 'delta', '--features', 'nvim' }`) replaces the plain `delta`; `'auto'` is the default. Colours are drawn for the lines on screen only, so a long patch opens as fast as a short one.

Four scopes, one view: **branch** (the merge-base against your working tree, uncommitted and untracked included: what `Changes vs <base>` lists), **commits** (the merge-base against `HEAD`, committed changes only: what `Commits on branch` lists; on the default branch, the recent commits it lists), **one commit** (against its first parent), and **uncommitted** (`HEAD` against the working tree). `gd` on any row of a git project in the drawer opens the scope the row stands for: the project row, a session or the `Changes` section give the branch; a file under `Changes` the same with the cursor on that file; the `Commits` section the commits; a commit row that commit (a file under it: with the cursor on the file); the `uncommitted` row that scope. Two dimmed `full diff · gd` rows, like the `commit graph · G` row, sit at the top of an open `Changes` section and after the graph row in `Commits`. In the commit graph, `gd` on a commit opens its full diff and `q` returns to the graph. `:AgentsDiff` opens the branch scope for the current context, as `:AgentsGraph` finds it.

`<CR>` on any line jumps into the side-by-side diff view of that file, the right side's cursor on the line under yours; `q` there comes back to the full diff where you were. (In the commits scope the side-by-side view shows the branch, with your working file on the right; on the default branch it shows the newest listed commit touching the file.) The view reloads when the project's git data does (a session's turn ends, `R` in the drawer or here), keeping the cursor on its file and hunk and your folds as you left them; a commit's full diff never reloads.

| Key (full diff) | Action |
|---|---|
| `gd` (drawer, graph) | Open the full diff of the row: its project, section, commit or file |
| `<CR>` | Side-by-side diff of this file, on this line; `q` there comes back here |
| `]f` / `[f` | Next / previous file |
| `]c` / `[c` | Next / previous hunk (closed files skipped) |
| `za` | Fold or unfold this file |
| `z0` / `z9` | Fold / unfold every file (`zM` / `zR` and the other fold keys work too) |
| `R` | Refresh (the drawer's lists reload too) |
| `y` | Yank the file's path (unnamed and `+` registers) |
| `glg` | lazygit for this repository |
| `q` | Close, back to what was shown before |
| `g?` | Help |

The keys are under `keys.full_diff` (`open`, `next_file`, `prev_file`, `next_hunk`, `prev_hunk`, `fold`, `collapse_all`, `expand_all`, `refresh`, `yank`, `lazygit`, `close`, `help`), the drawer's and the graph's key under `keys.drawer.full_diff` and `keys.graph.full_diff`; each a key, a list of keys, or `false`. The buffer is `agents://<project>/full diff`, filetype `agent-ide-fulldiff`.

#### Commit graph

`G` on any row of a git project in the drawer (the project row, its sections, a session), or `<CR>` on the `commit graph` row at the top of an expanded `Commits` section, opens the project's history as a graph in the main window, the way GitKraken or SourceTree show branches and merges. On a session that works in a linked worktree it shows that worktree. `:AgentsGraph` opens it for the current context: the chat's session, the full diff's or the diff view's repository, the drawer row, else the current file's (or the working directory's) repository (`:AgentsDiff` opens the [full diff](#full-diff) the same way). Outside a git repository you get a notice and nothing opens.

```
 myapp · graph · all branches                                       (winbar)
 ●   a1b2c3d main HEAD origin/main Merge branch 'retry'                8m  ben
 ├─╮
 ● │ 9f8e7d6 chore: drop the old poller                               28m  ben
 │ ● 77aa001 feat/retry test: retry with a fake server                 2h  ana
 │ ● 4c5d6e7 feat: retry loop                                          2h  ana
 ├─╯
 ● 1e2f3a4 v0.3.0 release notes                                        1d  ben
```

Git draws the graph (`git log --graph --date-order`); the view turns its characters into box-drawing ones and colours each lane column. Branches, remote branches (dim), tags and `HEAD` show as badges after the hash; a long subject is cut with `…` so the age and the author stay visible. It shows the newest 300 commits of every branch, tag and remote (the stash left out); when there are more, the last line says so and `L` loads 300 more. The graph reloads when the project's git data does (a session's turn ends, `R` in the drawer or here), keeping the cursor on its commit, and never takes the focus.

| Key (graph) | Action |
|---|---|
| `G` (drawer) | Open the graph of the row's repository |
| `<CR>` | On a commit: show / hide its changed files below it. On a file: the diff of that commit only (a merge against its first parent, the first commit against nothing); closing the diff comes back to the graph |
| `]]` / `[[` | Next / previous commit |
| `gd` | Full diff of the commit (on a file: with the cursor on it); `q` there comes back to the graph (see [Full diff](#full-diff)) |
| `a` | All branches / the current branch only |
| `R` | Refresh |
| `L` | Load 300 more commits |
| `y` | Yank the commit's full hash (unnamed and `+` registers) |
| `glg` | lazygit for this repository |
| `q` | Close, back to what was shown before |
| `g?` | Help |

Vim motions and `/` search work as usual. The keys are under `keys.graph` (`open`, `next_commit`, `prev_commit`, `full_diff`, `all`, `refresh`, `more`, `yank`, `lazygit`, `close`, `help`), each a key, a list of keys, or `false`; the number of commits per load is `git = { graph_limit = 300 }`. Highlight groups: `AgentIdeGraph1` to `AgentIdeGraph6` (the lane colours), `AgentIdeGraphBranch`, `AgentIdeGraphRemote`, `AgentIdeGraphTag`, `AgentIdeGraphHead` and `AgentIdeGraphHash`, all overridable by a colorscheme.

### Prompts

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

Files are written as typed, with a final newline added when the last line has none, atomically (a temporary file renamed into place; a new file is linked into place, so two Neovims saving the same name both keep theirs). New files are `0600` in folders created `0700`. The plugin writes only to the library and saved-prompts folders and never under a `.claude` folder (deleting a session with `D` is the one exception, see [Deleting sessions](#deleting-sessions)). Drawer rows refresh on `R`, after a save, rename or delete, and when you come back to the drawer.

To keep your library in git, point `library_dir` at a folder of a repository you manage (outside any `.claude` folder, so Claude does not take the templates for commands):

```lua
opts = { prompts = { library_dir = '~/notes/prompts' } }
```

### Search

`<leader>as` (or `:AgentsSearch [query]`, or `require('agent-ide').search()`) opens a floating picker that searches the titles, your prompts and Claude's answers of every session, live as you type. `<leader>aP` opens the same picker on your prompts only, newest first: the prompt history of all sessions. In the drawer, `S` searches the project under the cursor.

With the Rust helper the search is fuzzy and typo-tolerant ([neo_frizbee](https://crates.io/crates/neo_frizbee)): exact and word-start matches come first, then titles before prompts before answers, then the newest; a fuzzy match must keep its letters close together. Words match in any order; a word with a capital letter matches case-sensitively; umlauts match regardless of case (`über` finds `Über`). A session found only through a word of its project's name is listed last (`proj`). The index is built in the background on first use, kept on disk and updated when a transcript changes. Without the helper the picker says it is limited: titles and prompts only, exact words only.

| Key in the picker | Action |
|---|---|
| typing | Search (results update per keystroke) |
| `<C-n>` / `<C-p>`, `<Down>` / `<Up>` | Move |
| `<CR>` | Open the session's chat on the hit's line |
| `<C-y>` | Copy the hit's full text (prompt, answer or title) |
| `<C-e>` | Put the prompt into the open chat prompt to reuse it |
| `<Tab>` | Scope: all sessions, the current project, the current session |
| `<C-f>` | What to search: everything, prompts, answers, titles, or also tool calls |
| `]n` / `[n` (normal mode), `<M-n>` / `<M-p>` | Preview: next / previous occurrence of the query (wraps; the footer says `match 3/7`) |
| `<Esc>` (normal mode) or `q` | Close; in insert mode `<Esc>` first goes to normal mode |

The keys are under `keys.search_picker` (the match steps are `next_match` and `prev_match`; a step key that starts with a typed character, such as `]n`, works in normal mode only, so typing stays free); each is a key, a list of keys, or `false`. Other keys keep their Vim meaning in the query line: `<C-r>` inserts a register, `<C-k>` a digraph (`<C-k>u:` gives `ü`).

The preview shows the hit in its turn, rendered and folded as in the chat, with the hit's fold open. Every occurrence of every query word is marked (`AgentIdeSearchMatch`, linked to `Search`; the current one `AgentIdeSearchMatchCurrent`, linked to `CurSearch`), with the search's own matching (smart case, umlauts regardless of case; for a fuzzy match, what the search matched). The preview scrolls to the first occurrence of a word the result row does not already show in its title or project name, so a query such as `mailer signature` on a session titled "Mailer settings" lands on `signature`; when every word is only in the title or project name, the preview shows the top and its footer says `matched in title/project`.

`<CR>` opens the chat with the cursor on the first occurrence in the hit's event, and the query stays marked in that transcript window: `]n` / `[n` step through every occurrence in the transcript, `<Esc>` in normal mode clears the marks (a global `<Esc>` mapping of yours still runs after). The marks are window-local matches, never the search register or `'hlsearch'`; they go when the window closes or shows another buffer, and with the next search. A key the transcript buffer already maps is left alone. The prompt history lists the newest 500 prompts (the footer says how many there are; type to narrow), and the same prompt sent several times in a row is one row with a count (`×3`).

Tool calls are searched only on request (`<C-f>`), tool output never. The index keeps the first 4 KiB of each prompt and answer; copying and reusing take the full text from the transcript, and refuse with a notice when it cannot be read.

## How it works

The plugin reads the local Claude Code transcripts (JSONL files), builds an index of projects and sessions, and renders a transcript as markdown on demand. A small Rust helper (`agent-ide-helper`) can do the scanning, parsing and file watching off the Neovim process. When the helper is not built, or fails, a pure Lua implementation takes over and gives identical results for the drawer and the history; search without the helper is limited (titles and prompts, exact words). Neither path blocks the editor: the drawer opens in under 50 ms with 60 projects, a 1 MB history in under 150 ms with the helper, and a cold Lua scan never blocks the UI for more than 16 ms at a time.

### The Architecture

The different pieces involved you see here with the **session states**:

```mermaid
flowchart LR
  subgraph NVIM["Neovim (Lua)"]
    direction TB
    UI["UI<br/>drawer · chat transcript · prompt buffer<br/>diff · commit graph · search · help · footer"]
    SES["Session<br/>state · queue · events · pending asks"]
    DEC["Stream decoder<br/>claude/stream.lua (pure)"]
    REN["Transcript render<br/>transcript/render.lua (pure)"]
    IDX["Index client<br/>index/ + Lua fallback"]
    GIT["git queries<br/>read-only, async"]
    LIVE["live.lua<br/>polls claude agents --json"]
    STAT["status.lua<br/>footer + status file"]
  end

  subgraph PROCS["Processes the plugin starts"]
    direction TB
    KEEP["Keeper<br/>nvim --headless -l keeper/main.lua"]
    CLAUDE["claude -p<br/>stream-json in/out"]
    HELP["agent-ide-helper (Rust)<br/>scan · history · watch · search"]
  end

  DISK[("~/.claude/projects/*.jsonl<br/>transcripts")]
  REPO[("git repositories")]
  API(["Anthropic"])
  BAR["Omarchy bar widget"]
  TMUX["tmux pane<br/>claude --resume"]

  UI <--> SES
  SES -- "JSON lines" --> KEEP
  KEEP <--> CLAUDE
  KEEP -- "replayed + live lines" --> DEC
  DEC -- Actions --> SES
  SES -- Events --> REN --> UI
  CLAUDE <--> API
  CLAUDE -- writes --> DISK
  HELP -- reads --> DISK
  IDX <--> HELP
  IDX --> UI
  GIT --> REPO
  GIT --> UI
  LIVE --> UI
  SES --> STAT --> BAR
  UI -. "gT hand-off" .-> TMUX
```

Modules jobs:

| Module | Job |
|---|---|
| `claude/process.lua` | one long-lived `claude -p` child: spawn, write a line, read lines, stop (close stdin, SIGTERM after 500 ms). No protocol knowledge |
| `claude/stream.lua` | Claude's stream objects → Actions (`init`, `delta`, `event`, `permission`, `result`, `quota`, `unknown`, …). Pure |
| `session/object.lua`, `session/actions.lua` | the Session: prompt queue, state machine, pending asks, model and mode requests; reacts to Actions and to the process exit |
| `keeper/` | the detached process that owns Claude's pipes, its socket client, discovery of running keepers |
| `transcript/parse.lua`, `render.lua`, `live.lua` | transcript lines → Events (the same rules as the Rust parser), Events → markdown lines and folds, the live buffer that only rewrites the current turn |
| `index/`, `helper/` | scan, history, file watching and search, in Rust over stdio with a Lua fallback |
| `git*.lua` | read-only git (`--no-optional-locks`), parsed by pure functions, cached |
| `live.lua` | which sessions run in another terminal (`claude agents --json` every 5 s) |
| `status.lua` | the overall level, the statusline text, `status-<pid>.json` for the bar |
| `ui/` | everything you see; pure layout (`tree.lua`, `layout.lua`, `graph_render.lua`) is kept apart from windows |


The **keeper**, the agent abstraction of the **parked** `acp` branch and more are drawn in [ARCHITECTURE.md](ARCHITECTURE.md).

## Token usage

Agent-IDE never talks to a model itself. Every chat is the Claude Code CLI (`claude -p` speaking stream-json), started in the project folder with your usual settings, `CLAUDE.md`, skills, hooks and MCP servers, so a prompt costs about what the same prompt costs in Claude Code's own terminal UI.

What the plugin adds, and what it costs in model tokens:

| What | How | Tokens |
|---|---|---|
| A prompt you send | one user message, sent verbatim; no extra system prompt, no buffers, diagnostics or editor state added | the same as typing it into `claude` |
| `[attach]` and `@` | become `@<path>`, Claude Code's own file mention | the same as `@<path>` in `claude` |
| Drawer, history, search, diffs, commit graph | read from the transcript files on disk and git | none |
| Which sessions run elsewhere | `claude agents --json` every 5 s; it reads Claude's local session files and answers without a network | none, nothing sent to Anthropic |
| The model picker's list | a short-lived Claude that is only asked `initialize`: no prompt, no turn, and it answers without a network (your `SessionStart` hooks do run) | none |
| Permissions, questions, plans | answered over Claude's control channel instead of its terminal UI | none beyond what Claude Code asks anyway |
| Footer quota | read from the rate-limit objects Claude already sends | none |
| Raw view, queue panel (its sizes and agents included), drafts | local | none |

**What talks to Anthropic.** Only the `claude -p` process of a session you chat in. Everything else (the drawer, `claude agents --json`, the model picker, search, git) stays on your machine. The plugin never starts a turn on its own: no title generation, no summary, no suggestion request.

The flags the plugin passes to `claude -p` (stream-json in and out, partial messages, replaying your prompt, permissions over the pipe) change what Claude prints and where it asks, not what the model reads or writes. `--bare` is not used, so hooks, skills, MCP servers and `CLAUDE.md` load as in an interactive session, and your usual `/usage` attribution applies.

Where it can cost more is a **restart of a session's process**. Claude Code sends the whole conversation with every request, in the terminal as much as here: the API keeps no state between requests. While you work, that history is read from Anthropic's prompt cache at the cached rate, a fraction of the price. Opening a session from the drawer costs nothing: Claude starts only when you send a prompt. Parking (`<leader>ax`), handing a session to native Claude and back (`gT`), or quitting with `keeper = { enabled = false }` stops the process, and the next prompt starts `claude --resume`. The conversation is the same, but a new process may rebuild parts of its prompt, and after a pause the cache has expired anyway, so the first turn after a resume can read the whole conversation uncached. That is what `claude --resume` in a terminal costs too; the plugin only makes it one key away. `keeper.idle_minutes` frees memory and does not change tokens: the cache expires after a pause whether the process still runs or not.

**The size of a conversation.** The chat's winbar shows it beside the model: `~123k`, the input tokens of the session's last request, which is what the next prompt reads again. It follows the stream while Claude runs and comes from the end of the transcript for a parked session; nothing asks the model. From `context.threshold` tokens on (50 000 by default; `false` never asks):

- a send that would resume a parked session asks first: **Send** (reads the ~123k once, then every turn), **Compact first** (`/compact` goes first, your prompt after it: the same read once, then every turn is smaller) or **Cancel** (the text stays in the prompt). `context.confirm_resume = false` turns it off;
- parking a session between turns (`<leader>ax`, `sP`) offers **Park now**, **Compact, then park** (so the next resume reads less) or **Cancel**. `context.compact_before_park = false` turns it off.

`<leader>aC` sends `/compact` at any time; behind a running turn it is queued. A compaction shows as a `system: compact_boundary` fold, and the size after it.

Running several sessions at once costs what each of them costs; the drawer only makes that easy.

### Using the fewest tokens

- **Pick the model per session.** `<leader>aM` (or `/model`) before the first prompt; `claude.model` sets the default. A smaller model is plenty for renames, small fixes and questions about the code.
- **One task per session.** Every turn sends the conversation so far, so a long session makes every new prompt more expensive. Start unrelated work with `+ New session`; keep related work in one session so you do not explain the context twice.
- **Do not park a session you are still working in**, and avoid going back and forth with `gT` in the middle of a task. Parking a session you are done with costs nothing; parking one you will come back to is the moment to compact (the offer on `<leader>ax`), so the resume reads less.
- **Write the whole prompt, then send it.** The prompt buffer is made for long prompts: one complete prompt costs less than a short one and three corrections, since each follow-up sends the conversation again. Keep instructions you repeat as saved or library prompts (`:w`, `<leader>W`).
- **Attach only what is needed.** `[attach]` makes Claude read the whole file. For a large file, name the function or the lines in the prompt and let Claude read what it needs.
- **Interrupt early.** `<C-c>` stops a turn that goes the wrong way; queued prompts come back to the prompt buffer so you can rewrite them.
- **Look at the context.** The winbar's `~123k` is the size; `/context` from the `/` menu runs inside Claude Code without a model turn and shows what fills it. `<leader>aC` (or `/compact`) summarizes the conversation: one request that reads the whole history, and every turn after it is smaller. Worth it before you step away from a long session you will come back to; for a fresh start, `+ New session` costs nothing.
- **Keep the shared part small.** As in Claude Code: a short `CLAUDE.md`, and only the MCP servers a project needs, since their tool definitions travel with every turn.
- **Watch it.** The footer shows the quota windows; the raw view (`gr`) shows each turn's `result` line with its `usage`.

## Privacy

Apart from Claude Code itself, everything stays on your machine. The plugin reads transcripts under `projects_dir`, the output of `claude agents --json` and, when you set it, `quota.file`; it sends nothing over the network and never reads credentials. What you type in a chat goes to the `claude` process it starts, which talks to Anthropic as it always does.

What it writes, all of it private (new files `0600`, folders it creates `0700`, written through a temporary file renamed into place; a prompt file you already had keeps its mode):

| File | Where | Holds |
|---|---|---|
| `index-v3.json` (helper only) | `stdpath('cache')/agent-ide/` (on Linux usually `~/.cache/nvim/agent-ide/`) | session metadata, see below; files of earlier format versions (`index-v1.json`, …) there are removed when it is written |
| `search-v1.json` (helper only) | the same folder | the search index, see below |
| `chime-<name>.wav` | the same folder | the chime played when a session needs you (generated, nothing of yours) |
| `status-<pid>.json`, one per Neovim | `$XDG_RUNTIME_DIR/agent-ide/` (else `stdpath('run')/agent-ide/`) | level, counts and the sessions that are not parked (id, project folder name, title, state, the tool an ask is about); removed when that Neovim quits |
| `keeper-<session id>.json`, `keeper-<session id>.sock` | the same folder | per Claude under a keeper (see [Background sessions](#background-sessions)): session id, project folder, transcript path, the keeper's and Claude's pids, a coarse state (busy, waiting, idle), whether a Neovim is attached, how many prompts are queued; and the socket (0600) a Neovim attaches through. Both go when Claude ends |
| `quota.json` | `stdpath('state')/agent-ide/` | the last quota windows (percent used, reset times) and when they were reported |
| `hidden.json` | `stdpath('data')/agent-ide/` | the ids of the sessions you hid with `H` |
| `names.json` | `stdpath('data')/agent-ide/` | the names you gave sessions with `r` (session id and name) |
| Trash (`<YYYYMMDD-HHMMSS>-<id>/` per deleted session) | `stdpath('data')/agent-ide/trash/` | everything `D` moved out of Claude's folder (transcripts, file history, the session's `history.jsonl` lines) and a manifest, until `:AgentsTrash empty` or `trash.keep_days` |
| `commands.json` | `stdpath('state')/agent-ide/` | Claude's command names last seen per project (at most 50), keyed by a short hash of the project folder, for the `/` menu |
| `models.json` | `stdpath('state')/agent-ide/` | the models Claude Code last listed (value, name, description, full id), its version and when; nothing about your account |
| `prefs.json` | `stdpath('state')/agent-ide/` | the model last used (new sessions start with it) and whether the legend is shown |
| Drafts (`<session id>.md` per prompt buffer) | `stdpath('state')/agent-ide/drafts/` | the text of a prompt buffer as you type it, until it is sent or discarded (see Drafts under [Chat](#chat)) |
| Saved prompts (per project) | `stdpath('data')/agent-ide/prompts/<project folder>-<short hash>/`, or `prompts.saved_dir` | the prompts you save with `:w` |
| Library prompts (templates) | `stdpath('data')/agent-ide/library`, or wherever you point `prompts.library_dir` | the prompts you save with `<leader>W`, rename or move |

A save notice names the kind: `saved as a project prompt of <project>: <name>` for a per-project prompt (in the plugin's data folder, not in your project) and `saved to the library: <group>/<name>` for a library prompt (in `prompts.library_dir`).

The Rust helper's metadata cache `index-v3.json` holds the path, title, working directory, branch, size and modification time of each session, so the drawer opens fast. You can delete it at any time; it is rebuilt on the next scan.

The search index is `search-v1.json` in the same folder. It holds the first 4 KiB of every prompt and answer and a one-line summary of every tool call, with the session titles and paths. It is written at most every 30 seconds; changes since the last write are indexed again on the next start (the helper is stopped right after Neovim closes its input, so a final write is not guaranteed). Both files are ignored when a different helper version, other parse rules or another file format wrote them.

Both files are as private as the transcripts they come from: the folder is created (and tightened to) mode 0700, the files are written with mode 0600 through a temporary file that is renamed into place, and temporary files left by a helper that was killed while writing are removed on the next start. You can delete either file at any time; it is rebuilt on the next scan or search.

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

### Releasing

`CHANGELOG.md` is kept current under `## [Unreleased]`. `make release-notes` prints that section. `make release VERSION=x.y.z` (on `main`, clean tree, green tests) turns it into the version's section, sets the helper's version, commits and creates an annotated tag, all locally. `make publish VERSION=x.y.z` pushes the branch and the tag and creates the GitHub release (needs `gh`). Notes for coding agents are in `AGENTS.md`.
