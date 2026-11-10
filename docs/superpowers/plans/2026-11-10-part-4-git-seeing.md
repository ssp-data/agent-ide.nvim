# Agent-IDE.nvim Part 4: Git seeing — Implementation Plan

**Goal:** Browse what an agent changed without leaving the Agents tab: per git project a
`Changes vs <base>` and a `Commits on branch` section in the drawer, a side-by-side diff on
Neovim's own diff mode, one key to flip a file between "whole branch" and "this commit", keys
to walk the changed files, and `gl` to hand acting over to lazygit (spec 7.6).

**Architecture:**

```
git.lua          async git runner (vim.system, git --no-optional-locks -C <root>) + read-only queries
git_parse.lua    pure parsers of -z raw/numstat, log and status output
git_cache.lua    per-root cache: head, base, changes, commits, commit files; generations,
                 invalidate (reload what was loaded, keep old data until new arrives), listeners
ui/sections.lua  generic registry of extra drawer sections (git now, Prompts next)
ui/git_sections.lua  the git provider: rows, branch suffix, refresh triggers (session turn end,
                 R, drawer focus after 5 s)
ui/diff.lua      diff view lifecycle (windows, buffers, diffthis/diffoff, refresh, repair)
ui/diff_keys.lua keys, help and the commit picker of the diff view
ui/lazygit.lua   gl: Snacks.lazygit or a terminal tab; invalidates on exit
ui/chat_diff.lua gd in a chat transcript on an Edit/Write fold
ui/git_hl.lua    highlight groups of the git rows
```

`tree.build` stays pure: it gets one more optional argument, a function that returns extra
rows (and a suffix for the project row) per project. The drawer passes `sections.collect`.

## Sections hook interface

```lua
local sections = require('agent-ide.ui.sections')
sections.register(name, provider) -- re-registering a name replaces it; order = first registration
-- provider is a function, or a table { rows = fn, setup = fn?, refresh = fn?, focus = fn? }
-- rows(project, ctx) -> rows|nil, suffix|nil
--   ctx = { open = <project expanded>, expanded = <drawer expansion table>, icons, now }
--   rows   = { { pieces = { { text, hl_group|nil }, ... }, node = Node }, ... } (shown when open)
--   suffix = { { text, hl_group|nil }, ... } appended to the project row (open or not)
-- Node: any table with `type`, `project`, and
--   id   = stable unique string (cursor stays on it across re-renders)
--   fold = { key = <expanded key>, default = false, focus = <node id to land on> }  (za / <CR>)
--   open = function(node)  (<CR>; without it <CR> toggles `fold`)
-- setup(): called when the Agents tab is created; refresh(): on R; focus(): drawer gained focus
sections.collect(project, ctx) -- what tree.build calls
```

## Decisions

- Git sections are collapsed by default; their data (counts) loads when the project is expanded,
  their rows show when the section is expanded (`loading…` until then).
- Branch suffix on the project row comes from a throttled background `head` query (max 4 git
  processes at once) so 60 projects never spawn 120 processes in one tick.
- Untracked files are listed with status `?`; their `+n` is counted by reading the file
  asynchronously (first 500, files up to 2 MB, NUL byte = binary).
- On the default branch, or when no merge-base exists: `Changes vs HEAD` and `Recent commits`
  (last 20). No commits at all: changes against the empty tree.
- Diff keys: `]f`/`[f`, `gb`, `gB`, `q`, `?`, `gl` (config `keys.diff`), `gd` in chat.
- Picker for `gb` is `vim.ui.select`.
- A real buffer that left a diff window without our `diffoff` (another plugin replaced it, the
  tab was closed) is repaired with `diffoff` the next time it enters a window that is not part
  of the diff view (Neovim restores 'diff' from the buffer's last window otherwise).

## Tasks (each: failing test first, then code, then commit)

1. **git_parse + git data layer** — `tests/test_git.lua`: temp repos (local user config,
   `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`) covering origin/HEAD, main, master,
   none, no commits, no remote, detached HEAD, no merge-base, renames, deletes, binary, spaces and
   non-ASCII paths, submodule, untracked, default branch, commits order/count, commit files of
   root and merge commits, `show` nil, branch.
2. **sections hook + tree** — `tests/test_sections.lua`: tree.build with a fake provider (rows,
   suffix, ids, purity); existing `tests/test_tree.lua` unchanged and green.
3. **git cache + git provider rows** — `tests/test_git_sections.lua`: labels/counts, loading,
   500 cap with `… n more`, commit expansion, suffix only off the default branch, non-git none,
   invalidate keeps old data and reloads.
4. **drawer integration** — `tests/test_git_ui.lua` (child Neovim): sections appear under a git
   project, expand Changes, `R`, session busy→idle invalidates, focus after 5 s.
5. **diff view** — same file: Enter opens two diff windows (names, filetype, real right side),
   added/deleted/binary/submodule notes, `]f`/`[f`, `gb` (picker), `gB`, `q` back to chat,
   winbars, refresh keeps cursor; lifecycle: repeated opens, opening a chat, tab closed, `:bd`
   on the scratch side, modified unsaved real file, same file in another tab; never `diff` left.
6. **lazygit** — Snacks path, terminal path (fake `lazygit` on PATH), not installed notice,
   invalidation after exit; from drawer and diff.
7. **chat → diff** — `gd` on an Edit/Write fold opens the branch diff of its file.
8. **speed** — `tests/test_git_budget.lua`: 30 collapsed projects re-render < 5 ms; 300 changed
   files rows < 150 ms after the data arrives.
9. **review + smoke check** on real repositories (counts and timings only).
