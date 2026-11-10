# Agent-IDE.nvim (Agents Drawer)

A Neovim plugin that lists your Claude Code sessions in a drawer, grouped by git repository, and opens any session's history as a read-only markdown buffer. Sessions that are running show their state (waiting, busy, idle) next to their name.

## Status

Part 1 of 6: the drawer and the history view. Chat, prompts, git review, an Omarchy indicator and other agents are planned and not available yet.

## Requirements

- Neovim 0.12 or newer
- Claude Code (the plugin reads the transcripts it writes to `~/.claude/projects`; the `claude` command is only used to ask which sessions are running)
- Optional: `cargo` to build the Rust helper (faster scanning and file watching)
- Optional: `tmux` for jumping to the pane of a running session

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
  tcd = true, -- opening a session sets the tab's working directory to its project
  keys = { toggle = '<leader>aa' }, -- false disables the mapping
  icons = { open = '▾', closed = '▸', project = '', waiting = '◐', busy = '●', idle = '○', parked = '·' },
})
```

`:Agents` (or the toggle key) opens the Agents tab with the drawer. Inside the Agents tab it closes or reopens the drawer; from any other tab it switches to the Agents tab.

## Keys in the drawer

| Key | Action |
|---|---|
| `<CR>`, `o` | Expand or collapse a project; open a session's history |
| `za` | Expand or collapse the node under the cursor |
| `R` | Rescan sessions and refresh running state |
| `gp` | Jump to the tmux pane of a running session |
| `q` | Close the drawer |

The history buffer is markdown with folds for tool calls, results and thinking. Anything the viewer does not understand is shown as a fold marked `unknown`, never dropped, and truncated output says how many lines are hidden.

## How it works

The plugin reads the local Claude Code transcripts (JSONL files), builds an index of projects and sessions, and renders a transcript as markdown on demand. A small Rust helper (`agent-ide-helper`) can do the scanning, parsing and file watching off the Neovim process. When the helper is not built, or fails, a pure Lua implementation takes over and gives identical results. Neither path blocks the editor: the drawer opens in under 50 ms with 60 projects, a 1 MB history in under 150 ms with the helper, and a cold Lua scan never blocks the UI for more than 16 ms at a time.

## Privacy

Everything stays on your machine. The plugin reads transcripts under `projects_dir` and the output of `claude agents --json`, and sends nothing over the network.

The Rust helper keeps a metadata cache in `stdpath('cache')/agent-ide/index-v2.json` (on Linux usually `~/.cache/nvim/agent-ide/index-v2.json`). It holds the path, title, working directory, branch, size and modification time of each session, so the drawer opens fast. You can delete it at any time; it is rebuilt on the next scan.

## Roadmap

1. Drawer and history (this release)
2. Chat and prompt buffer
3. Prompts
4. Git review: changes, commits, diff view
5. Omarchy indicator
6. Other agents

## Development

```sh
make test          # mini.test suite, includes the speed budgets (clones mini.nvim into deps/)
make test-helper   # Rust tests for the helper
make helper        # build the helper
make bench         # print the four speed measurements next to their budgets
make bench DIR=~/.claude/projects   # timings and counts for your own transcripts only
```

All test data is synthetic.
