# Agent-IDE.nvim (Agents Drawer)

A Neovim plugin that lists your Claude Code sessions in a drawer, grouped by git repository, and opens any session's history as a read-only markdown buffer. Sessions that are running show their state (waiting, busy, idle) next to their name.

## Status

Parts 1, 2 and 5 of 6: the drawer and the history view, chat with Claude Code from Neovim, and the Omarchy indicator (see `omarchy/io.github.sspaeti.agent-ide/README.md`). Prompts, git review and other agents are planned and not available yet.

## Requirements

- Neovim 0.12 or newer
- Claude Code, logged in with a subscription (the plugin reads the transcripts it writes to `~/.claude/projects`, asks `claude agents --json` which sessions are running, and runs `claude -p` for the chat; tested with Claude Code 2.1.306)
- Optional: `cargo` to build the Rust helper (faster scanning and file watching)
- Optional: `tmux` for jumping to the pane of a running session and for continuing a chat in native Claude

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
    chat = { send = '<C-CR>', send_alt = '<leader><CR>', interrupt = '<C-c>', prompt = '<leader>ap', help = '?',
      history_prev = '<C-p>', history_next = '<C-n>', attach = '<leader>af',
      answer_inner = 'ir', answer_outer = 'ar', mode = '<S-Tab>', model = '<leader>aM', answer = '<leader>ay',
      raw = 'gr', raw_event = 'gR', native = '<leader>at' },
  },
  chat = { auto_slash = true, at_picker = true }, -- `/` opens the command menu, `@` the file picker
  icons = { open = '▾', closed = '▸', project = '', waiting = '◐', busy = '●', idle = '○', parked = '·',
    done = '✔', failed = '✖', new = '+' },
})
```

`:Agents` (or the toggle key) opens the Agents tab with the drawer. Inside the Agents tab it closes or reopens the drawer; from any other tab it switches to the Agents tab.

## Keys

Global:

| Key | Action |
|---|---|
| `<leader>aa` | Toggle the Agents tab (same as `:Agents`) |
| `<leader>an` | Go to the next session that needs you: an open question first (oldest first), then a failed or a finished turn you have not seen |

In the drawer:

| Key | Action |
|---|---|
| `<CR>`, `o` | Expand or collapse a project; open a session; start a new session (`+ New session`) |
| `za` | Expand or collapse the node under the cursor |
| `R` | Rescan sessions and refresh running state |
| `gp` | Jump to the tmux pane of a session running elsewhere |
| `q` | Close the drawer |
| `?` | Help |

In the chat (transcript and prompt buffer, unless noted):

| Key | Action |
|---|---|
| `<C-CR>` | Send the prompt (normal and insert mode) |
| `<leader><CR>` | Send the prompt |
| `<C-c>` | Interrupt Claude; queued prompts come back into the prompt buffer |
| `<leader>ap` | Focus the prompt |
| `i`, `a`, `o` | Transcript: write in the prompt |
| `<leader>ay` | Answer what Claude asks (permission, question, plan) |
| `<S-Tab>` | Next permission mode |
| `<leader>aM` | Pick the model |
| `<leader>at` | Continue the session in native Claude in a tmux pane |
| `gr` | Transcript: raw view of what was sent and received; `q` or `gr` returns |
| `gR` | Transcript: raw view at the line of the `unknown` fold under the cursor |
| `ir`, `ar` | Transcript: text object for one Claude answer (`ar` with its header) |
| `<C-p>`, `<C-n>` | Prompt: older or newer prompt (also `<Up>` on the first line, `<Down>` on the last) |
| `<leader>af` | Prompt: pick a file and add an `[attach]` line |
| `/` | Prompt, on an empty line: Claude's commands (menu) |
| `@` | Prompt, after a space: pick a file to attach |
| `za` | Toggle fold |
| `:q`, `ZZ` | Prompt: hide the window; the draft stays |
| `:q!` | Prompt: hide the window and discard the draft |
| `?` | Help |

The history buffer is markdown with folds for tool calls, results and thinking. Anything the viewer does not understand is shown as a fold marked `unknown`, never dropped, and truncated output says how many lines are hidden.

## Chat

Open a session from the drawer, or start one with `+ New session` under a project. The transcript fills the main window of the Agents tab and a prompt buffer opens below it. Opening a session shows its history without starting Claude; the first prompt you send starts `claude -p` for it (resuming the session when it has a history), and the process keeps running until you quit Neovim or hand the session to native Claude. The winbar shows project, title, model, permission mode, state and the number of queued prompts.

**Prompt buffer.** A normal markdown buffer: write as much as you like and send it with `<C-CR>`. Its text is sent as typed, except that an `[attach] <path>` line outside a fenced code block becomes `@<path>` (`@"<path>"` when the path holds spaces), which makes Claude read the file. `@` after a space opens a file picker that adds such a line; `/` on an empty line opens the menu of the commands the session listed (known after its first answer). `<C-p>` and `<C-n>` step through the prompts of the session.

**While Claude works.** Answers stream into the transcript. A prompt sent while a turn runs is queued by the plugin and sent after that turn, in order. `<C-c>` interrupts the turn and puts the queued prompts back into the prompt buffer.

**Permissions, questions and plans.** When Claude asks to use a tool, the ask shows at the end of the transcript and in the drawer, and a picker opens with Allow, Deny and the suggestions Claude made (switch the mode for this session, or always allow a rule; the label says where the rule is saved, for example `.claude/settings.local.json` in the project). The picker opens only when you are in that session's chat in normal mode. Nothing ever interrupts you: an ask from another session never opens a popup, moves the cursor or takes focus; it shows in the drawer and in the footer, and `<leader>an` takes you there. While you type in the same session's prompt, a one-line hint appears instead; `<leader>ay` opens the picker. Questions Claude asks (multiple choice) are answered the same way, one picker per question; a multi-select question takes one option per round until you pick Done choosing. A plan from plan mode can be approved, approved with edits accepted for the rest of the session, or sent back with Keep planning.

**Mode and model.** `<S-Tab>` cycles the permission mode (manual, acceptEdits, plan, auto) and `<leader>aM` picks the model. The winbar shows `old→new` until Claude confirms the change; a refused change says why.

**Raw view.** `gr` in the transcript shows every line sent to Claude (`>>`) and received (`<<`) for the session, byte for byte; for a session that did not run here it shows the transcript file. Anything the chat cannot render shows as an `unknown` fold, and `gR` on it opens the raw view at its line.

**Native Claude.** `<leader>at` inside tmux parks the session (after a question when Claude is working), opens `claude --resume <id>` in a split pane, and reloads the session from disk when that Claude exits; until then the winbar says `in native Claude (tmux pane)` and sending is refused. Outside tmux it parks the session and shows the command to run.

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

## How it works

The plugin reads the local Claude Code transcripts (JSONL files), builds an index of projects and sessions, and renders a transcript as markdown on demand. A small Rust helper (`agent-ide-helper`) can do the scanning, parsing and file watching off the Neovim process. When the helper is not built, or fails, a pure Lua implementation takes over and gives identical results. Neither path blocks the editor: the drawer opens in under 50 ms with 60 projects, a 1 MB history in under 150 ms with the helper, and a cold Lua scan never blocks the UI for more than 16 ms at a time.

## Privacy

Apart from Claude Code itself, everything stays on your machine. The plugin reads transcripts under `projects_dir` and the output of `claude agents --json`, and sends nothing over the network; what you type in a chat goes to the `claude` process it starts, which talks to Anthropic as it always does.

The Rust helper keeps a metadata cache in `stdpath('cache')/agent-ide/index-v2.json` (on Linux usually `~/.cache/nvim/agent-ide/index-v2.json`). It holds the path, title, working directory, branch, size and modification time of each session, so the drawer opens fast. You can delete it at any time; it is rebuilt on the next scan.

## Roadmap

1. Drawer and history (done)
2. Chat and prompt buffer (done)
3. Prompts
4. Git review: changes, commits, diff view
5. Omarchy indicator (done)
6. Other agents

## Development

```sh
make test          # mini.test suite, includes the speed budgets (clones mini.nvim into deps/)
make test-helper   # Rust tests for the helper
make test-real     # drive the real Claude Code (subscription, model haiku) in a temporary git repository
make helper        # build the helper
make bench         # print the four speed measurements next to their budgets
make bench DIR=~/.claude/projects   # timings and counts for your own transcripts only
```

All test data is synthetic. `make test-real` is the exception: it talks to the real Claude Code with tiny prompts, prints only pass or fail per check, and removes its temporary repository and the transcript Claude wrote for it.
