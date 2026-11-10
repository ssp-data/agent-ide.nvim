# Agent-IDE.nvim Part 1: Drawer and History — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A drawer in Neovim that lists every Claude Code session grouped by git repository, with title, state and age, and opens any session's history as a read-only markdown buffer with tool calls as folds.

**Architecture:** A Lua plugin reads Claude's transcript files (`~/.claude/projects/<slug>/<session>.jsonl`), turns records into a small shared event model, and renders events to buffer lines plus fold ranges. Sessions are grouped into projects by git root. Live state comes from `claude agents --json`. A Rust helper binary does the same scanning and parsing faster and watches for changes; the plugin works without it through a Lua fallback that produces identical results.

**Tech Stack:** Lua (Neovim 0.12 API, `vim.uv`, `vim.system`), mini.test for Lua tests, Rust (serde, serde_json, rayon, notify) for the helper, Make.

**Spec:** `docs/superpowers/specs/2026-11-10-agents-ide-design.md` (sections 4, 7.1, 7.2 transcript part, 7.3, 8, 9, 11 part 1, 12).

## Global Constraints

- Plugin name `Agent-IDE.nvim`; Lua module `agent-ide`; highlight groups prefixed `AgentIde`; helper binary `agent-ide-helper`; data and cache folders named `agent-ide`.
- Neovim 0.12+. No Lua plugin dependencies at runtime. mini.nvim is a test-only dependency cloned into `deps/` (git-ignored).
- **Privacy:** fixtures are hand-written synthetic transcripts. Never copy content from `~/.claude` into the repo, tests, commit messages or logs. Surveys of real transcripts may print record *types* and counts only.
- **Fidelity (spec 8):** nothing is dropped silently. A transcript record or content block the code does not understand becomes an `unknown` event and a visible fold. Truncation is always marked in the buffer with the number of hidden lines.
- **Speed (spec 9.1):** drawer opens in under 50 ms with 60 projects; a 1 MB history opens in under 150 ms; no synchronous directory scan, transcript parse or subprocess wait on the UI thread.
- The plugin never changes Neovim's global working directory, and never stops a Claude process it did not start.
- Works when not inside tmux, when `claude` is not installed, and when the helper binary is absent.
- No hard-coded personal paths; every path is a setting with a default.
- Commits end with `Co-Authored-By: Claude <noreply@anthropic.com>`. Work on branch `part-1-drawer`; do not commit to `main`.

## Review Focus

1. **Claude's own text looks like fold markup.** An answer containing lines starting with `▸ ` or `│` must render as plain text, not as a fold. → Task 2.
2. **Transcript being written while read.** A last line that is cut off or not valid JSON is skipped; everything before it renders; no error is raised. → Task 1.
3. **Unpaired tool events.** A tool call with no result (interrupted turn) shows as a fold without output; a result whose call is missing shows as its own fold. → Task 2.
4. **Project folder no longer exists, or session has no `cwd`.** The project row still appears, marked missing, and its history opens. → Task 4, Task 7.
5. **`claude` missing, or `claude agents --json` prints something that is not a JSON array.** Drawer works, every session shows parked, one notice at most. → Task 5.

## File Structure

```
plugin/agent-ide.lua                 :Agents command, default keymap
lua/agent-ide/init.lua               setup(opts), toggle()
lua/agent-ide/config.lua             defaults, merged options
lua/agent-ide/transcript/parse.lua   transcript record -> events
lua/agent-ide/transcript/render.lua  events -> lines + fold ranges
lua/agent-ide/index/lua_scan.lua     Lua fallback: session metadata, chunked scan
lua/agent-ide/index/helper.lua       client for the Rust helper
lua/agent-ide/index/init.lua         facade: scan / history / on_change
lua/agent-ide/project.lua            git root lookup, grouping sessions into projects
lua/agent-ide/live.lua               `claude agents --json` polling, state rollup
lua/agent-ide/tmux.lua               find and jump to the pane of a pid
lua/agent-ide/ui/tree.lua            pure: data -> drawer lines, nodes, highlights
lua/agent-ide/ui/drawer.lua          Agents tab, drawer window, keymaps
lua/agent-ide/ui/history.lua         history buffer and window
lua/agent-ide/ui/highlights.lua      highlight group definitions
helper/Cargo.toml, helper/src/{main,protocol,scan,events,cache,watch}.rs
tests/minimal_init.lua, tests/test_*.lua
tests/fixtures/projects/<slug>/<id>.jsonl      synthetic transcripts
tests/fixtures/golden/<name>.events.json       expected events, shared by Lua and Rust tests
Makefile, README.md, .gitignore
```

## Shared Types

**Event** (Lua table; same shape as JSON from the helper):

| kind | fields |
|---|---|
| `prompt` | `text` |
| `text` | `text` |
| `thinking` | `text` |
| `tool_call` | `id`, `name`, `input` (table, as in transcript) |
| `tool_result` | `id`, `text`, `is_error` (boolean) |
| `meta` | `label`, `text` |
| `unknown` | `label`, `raw` (the original JSON text of the record or block) |

Any event may carry `sidechain = true` (record belongs to a subagent).

**SessionMeta:** `{ id, path, cwd|nil, title, branch|nil, mtime (seconds), size (bytes) }`

**Project:** `{ key, name, root|nil, is_git, missing, mtime, sessions }` where each session is a SessionMeta plus `subpath|nil` (cwd relative to root, when different).

**State:** `'waiting' | 'busy' | 'idle' | 'parked'`. Rollup rank: waiting > busy > idle > parked.

---

### Task 1: Test harness and transcript parser

**Files:**
- Create: `Makefile`, `.gitignore`, `tests/minimal_init.lua`, `lua/agent-ide/transcript/parse.lua`
- Create: `tests/fixtures/projects/-home-u-git-alpha/11111111-1111-4111-8111-111111111111.jsonl`, `tests/fixtures/golden/alpha-basic.events.json`
- Test: `tests/test_parse.lua`

**Interfaces:**
- Produces: `parse.parse_line(line: string) -> Event[]` (never raises; returns `{}` for bookkeeping, blank or invalid lines), `parse.parse_text(text: string) -> Event[]`.

Record-to-event rules:

| Transcript record | Events |
|---|---|
| `type=user`, `message.content` string not starting with `<` | `prompt` |
| `type=user`, string containing `<command-name>X</command-name>` (optional `<command-args>Y</command-args>`) | `prompt` with text `X Y` trimmed |
| `type=user`, string wrapped in `<local-command-stdout>` | `meta`, label `command output`, text = inner text |
| `type=user`, any other string starting with `<`; or record with `isMeta=true` | `meta`, label `meta`, text = content text |
| `type=user`, content list: `tool_result` block | `tool_result` (`id` = `tool_use_id`; `text` = string content, or `text` fields of a list joined with `\n`, non-text items as `[<type>]`) |
| `type=user`, content list: `text` block | `prompt` (or `meta` when `isMeta`) |
| `type=assistant`: `text` block | `text` |
| `type=assistant`: `thinking` block | `thinking` if text non-empty, otherwise nothing |
| `type=assistant`: `tool_use` block | `tool_call` |
| any other content block type | `unknown`, label = block type |
| bookkeeping record types: `last-prompt`, `mode`, `permission-mode`, `atis-latch`, `attachment`, `file-history-snapshot`, `file-history-delta`, `ai-title`, `api-request`, `api-request-shape`, `api-request-blob`, `system`, `summary`, `queue-operation` | none |
| any other record type | `unknown`, label = record type |
| `isSidechain=true` on a record | its events get `sidechain = true` |

- [ ] **Step 1: Harness.** `Makefile` targets: `deps` (clone `https://github.com/echasnovski/mini.nvim` into `deps/mini.nvim` if absent), `test` (`nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"`), `helper` (`cargo build --release --manifest-path helper/Cargo.toml`), `test-helper` (`cargo test --manifest-path helper/Cargo.toml`), `bench`. `tests/minimal_init.lua` puts the repo and `deps/mini.nvim` on `runtimepath` and calls `require('mini.test').setup()`. `.gitignore`: `deps/`, `helper/target/`.

- [ ] **Step 2: Write the fixture and golden file.** The fixture has one record of every row in the table above, in a realistic order: prompt, thinking (empty), text, tool_use `Bash` id `t1`, tool_result `t1`, tool_use `Edit` id `t2`, tool_result `t2` with `is_error=true`, a `/compact` command record, a `<local-command-stdout>` record, an `isMeta` record, an `ai-title` record with `aiTitle="Alpha basics"`, two bookkeeping records, an `image` block inside an assistant message, a record of made-up type `future-thing`, two sidechain records, and a final line cut off mid-JSON. Every conversational record carries `cwd="/home/u/git/alpha"`, `gitBranch="feat/x"`. The golden file is the expected Event list as JSON.

- [ ] **Step 3: Write the failing tests** in `tests/test_parse.lua`:

```lua
local parse = require('agent-ide.transcript.parse')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()
local fx = 'tests/fixtures/projects/-home-u-git-alpha/11111111-1111-4111-8111-111111111111.jsonl'
local function slurp(p) local f = assert(io.open(p)); local s = f:read('a'); f:close(); return s end

T['fixture matches golden events'] = function()
  local golden = vim.json.decode(slurp('tests/fixtures/golden/alpha-basic.events.json'), { luanil = { object = true, array = true } })
  eq(parse.parse_text(slurp(fx)), golden)
end
T['invalid, blank and cut-off lines yield no events and do not raise'] = function()
  eq(parse.parse_line(''), {})
  eq(parse.parse_line('{"type":"user","message":{"content":"hal'), {})
  eq(parse.parse_line('not json'), {})
end
T['unknown record type becomes unknown event with raw text'] = function()
  local line = '{"type":"future-thing","x":1}'
  eq(parse.parse_line(line), { { kind = 'unknown', label = 'future-thing', raw = line } })
end
T['bookkeeping yields nothing'] = function()
  eq(parse.parse_line('{"type":"api-request-blob","hash":"h","message":{"content":"zzz"}}'), {})
end
return T
```

- [ ] **Step 4:** Run `make deps test`. Expected: FAIL, module `agent-ide.transcript.parse` not found.

- [ ] **Step 5: Implement `parse.lua`** per the table. Decode with `vim.json.decode(line, { luanil = { object = true, array = true } })` under `pcall`. A cheap substring check may skip bookkeeping lines before decoding, as long as results are unchanged.

- [ ] **Step 6: Survey real record types (types only).** Run a one-off script over `~/.claude/projects/*/*.jsonl` that prints only the distinct values of `type` and of content-block `type`, with counts. Any type not in the table: decide bookkeeping or conversational, add it to the table in this plan and to the code, and add one synthetic record to the fixture and golden. Do not print or store any content.

- [ ] **Step 7:** Run `make test`. Expected: PASS.

- [ ] **Step 8: Commit** `feat: transcript parser with shared event model`.

---

### Task 2: Renderer

**Files:**
- Create: `lua/agent-ide/transcript/render.lua`
- Test: `tests/test_render.lua`

**Interfaces:**
- Consumes: Event (Shared Types).
- Produces: `render.render(events: Event[]) -> { lines: string[], folds: {first: integer, last: integer}[] }` (1-based inclusive line ranges; no line contains `\n` or `\r`), `render.fold_levels(folds, line_count) -> string[]` (per line: `'>1'` on a fold's first line, `'1'` inside, `'0'` elsewhere).

Layout rules:

- `prompt`: blank line, `## You`, blank, the text lines, blank. The first non-prompt event after a prompt is preceded by `## Claude` and a blank line.
- `text`: its lines, then a blank line.
- `tool_call`: header `▸ <name>: <summary>`, then body lines each prefixed `│ `. Summary = first line of the first present of `input.command`, `file_path`, `skill`, `pattern`, `description`, `prompt`, cut to 80 characters. Body: `Bash` → `$ <command>`; `Edit` → `old_string` lines prefixed `- `, `new_string` lines prefixed `+ `; `Write` → `content`; anything else → `vim.inspect(input)`.
- `tool_result`: appended to the block of the call with the same `id`, lines prefixed `│ `, first line prefixed `│ ERROR ` when `is_error`. If no such call exists: its own block with header `▸ result (no matching call)`.
- `thinking` → block `▸ thinking`. `meta` → block `▸ <label>`. `unknown` → block `▸ unknown: <label>` with `raw` as body.
- Consecutive events with `sidechain = true` → one block `▸ subagent (<n> events)` whose body is those events rendered by the same rules, every line prefixed `│ `.
- Caps: tool input body 60 lines, result 200 lines, unknown 20 lines. When cut, the last line is `│ … <n> more lines`.
- One fold per block, covering header through last body line. Folds come only from `folds`, never from line text.

- [ ] **Step 1: Write the failing tests:**

```lua
local render = require('agent-ide.transcript.render')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T['prompt, answer, tool call with result'] = function()
  local r = render.render({
    { kind = 'prompt', text = 'run ls' },
    { kind = 'tool_call', id = 't1', name = 'Bash', input = { command = 'ls' } },
    { kind = 'tool_result', id = 't1', text = 'a.txt\nb.txt', is_error = false },
    { kind = 'text', text = 'Done.' },
  })
  eq(r.lines, { '', '## You', '', 'run ls', '', '## Claude', '',
    '▸ Bash: ls', '│ $ ls', '│ a.txt', '│ b.txt', 'Done.', '' })
  eq(r.folds, { { first = 8, last = 11 } })
end
T['answer text that looks like markup is not a fold'] = function()
  local r = render.render({ { kind = 'prompt', text = 'q' }, { kind = 'text', text = '▸ not a fold\n│ nor this' } })
  eq(r.folds, {})
end
T['results attach to their call even when out of order'] = function()
  local r = render.render({
    { kind = 'tool_call', id = 'a', name = 'Read', input = { file_path = '/x' } },
    { kind = 'tool_call', id = 'b', name = 'Read', input = { file_path = '/y' } },
    { kind = 'tool_result', id = 'b', text = 'YY', is_error = false },
    { kind = 'tool_result', id = 'a', text = 'XX', is_error = false },
  })
  local s = table.concat(r.lines, '\n')
  MiniTest.expect.no_equality(s:find('/x.-XX.-/y.-YY'), nil)
end
T['call without result and result without call'] = function()
  local r = render.render({
    { kind = 'tool_call', id = 'a', name = 'Bash', input = { command = 'sleep 9' } },
    { kind = 'tool_result', id = 'zz', text = 'orphan', is_error = false },
  })
  eq(#r.folds, 2)
  eq(r.lines[r.folds[2].first], '▸ result (no matching call)')
end
T['error result, unknown, long output cap'] = function()
  local big = string.rep('x\n', 300)
  local r = render.render({
    { kind = 'tool_call', id = 'a', name = 'Bash', input = { command = 'c' } },
    { kind = 'tool_result', id = 'a', text = big, is_error = true },
    { kind = 'unknown', label = 'future-thing', raw = '{"type":"future-thing"}' },
  })
  eq(r.lines[3], '│ ERROR x')
  eq(vim.tbl_contains(r.lines, '│ … 101 more lines'), true)
  eq(vim.tbl_contains(r.lines, '▸ unknown: future-thing'), true)
end
T['no line contains newline or carriage return'] = function()
  local r = render.render({ { kind = 'text', text = 'a\r\nb\rc' } })
  for _, l in ipairs(r.lines) do eq(l:find('[\r\n]'), nil) end
end
T['sidechain events collapse into one fold'] = function()
  local r = render.render({
    { kind = 'text', text = 'sub says hi', sidechain = true },
    { kind = 'tool_call', id = 's', name = 'Bash', input = { command = 'ls' }, sidechain = true },
  })
  eq(r.lines[1], '▸ subagent (2 events)')
  eq(r.folds, { { first = 1, last = #r.lines } })
end
T['fold_levels'] = function()
  eq(render.fold_levels({ { first = 2, last = 3 } }, 4), { '0', '>1', '1', '0' })
end
return T
```

(`'a\r\nb\rc'` renders as three lines `a`, `b`, `c`; `300` lines of `x` plus the trailing empty piece give 301 lines, 200 shown, 101 hidden.)

- [ ] **Step 2:** Run `make test`. Expected: FAIL, module not found.
- [ ] **Step 3: Implement `render.lua`.** Two passes: collect results by id, then emit blocks.
- [ ] **Step 4:** Run `make test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: render events to lines and fold ranges`.

---

### Task 3: Session metadata and Lua scan

**Files:**
- Create: `lua/agent-ide/index/lua_scan.lua`, `lua/agent-ide/index/init.lua`
- Create fixtures: second project `tests/fixtures/projects/-home-u-git-alpha-docs/2222….jsonl` (cwd `/home/u/git/alpha/docs`, no `ai-title`, first prompt `Write the docs intro paragraph`), third `tests/fixtures/projects/-home-u-notes/3333….jsonl` (cwd `/home/u/notes`), fourth `tests/fixtures/projects/-nocwd/4444….jsonl` (only bookkeeping records)
- Test: `tests/test_scan.lua`

**Interfaces:**
- Produces:
  - `lua_scan.meta(path: string, mtime: integer, size: integer) -> SessionMeta` — reads at most the first 256 KiB.
  - `lua_scan.scan(projects_dir: string, cb: fun(sessions: SessionMeta[]))` — only top-level `*.jsonl` of each sub-directory; processes 8 files per `vim.schedule` tick; missing directory calls `cb({})`.
  - `lua_scan.history(path: string, cb: fun(events: Event[]))` — parses in chunks of 500 lines per tick.
  - `index.scan(cb)`, `index.history(path, cb)`, `index.on_change(fn)`, `index.backend() -> 'lua'|'helper'` — in this task always the Lua backend; `projects_dir` comes from `config` (Task 7 supplies it; until then `index.scan` takes an optional `projects_dir` argument used by tests).
- Title rule: the last `aiTitle` found; otherwise the first `prompt` event's text, newlines replaced by spaces, cut to 60 characters; otherwise `(untitled)`.

- [ ] **Step 1: Write the failing tests:**

```lua
local scan = require('agent-ide.index.lua_scan')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()
local dir = vim.fn.fnamemodify('tests/fixtures/projects', ':p'):gsub('/$', '')
local function run(d) local out; scan.scan(d, function(s) out = s end); vim.wait(2000, function() return out ~= nil end); return out end
local function by_id(list, prefix) for _, s in ipairs(list) do if vim.startswith(s.id, prefix) then return s end end end

T['meta: title from ai-title, cwd and branch'] = function()
  local s = by_id(run(dir), '1111')
  eq({ s.title, s.cwd, s.branch }, { 'Alpha basics', '/home/u/git/alpha', 'feat/x' })
  eq(type(s.mtime), 'number'); eq(s.size > 0, true)
end
T['meta: falls back to first prompt, then (untitled)'] = function()
  local all = run(dir)
  eq(by_id(all, '2222').title, 'Write the docs intro paragraph')
  eq(by_id(all, '4444').title, '(untitled)')
  eq(by_id(all, '4444').cwd, nil)
end
T['scan finds every fixture session and is asynchronous'] = function()
  local called = false
  scan.scan(dir, function() called = true end)
  eq(called, false)
  eq(#run(dir), 4)
end
T['missing projects dir gives empty list'] = function() eq(run('/nonexistent/x'), {}) end
T['history returns the same events as parse_text'] = function()
  local p = by_id(run(dir), '1111').path
  local ev; scan.history(p, function(e) ev = e end); vim.wait(2000, function() return ev ~= nil end)
  local f = io.open(p); local text = f:read('a'); f:close()
  eq(ev, require('agent-ide.transcript.parse').parse_text(text))
end
return T
```

- [ ] **Step 2:** Run `make test`. Expected: FAIL, module not found.
- [ ] **Step 3: Implement** `lua_scan.lua` and `index/init.lua`.
- [ ] **Step 4:** Run `make test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: session metadata scan with Lua backend`.

---

### Task 4: Projects by git repository

**Files:**
- Create: `lua/agent-ide/project.lua`
- Test: `tests/test_project.lua`

**Interfaces:**
- Consumes: SessionMeta.
- Produces:
  - `project.git_root(cwd: string, home: string) -> root: string|nil, exists: boolean` — walks up from `cwd` (starting at the nearest existing ancestor when `cwd` is gone) looking for `.git`. A `.git` *file* whose `gitdir:` points into `<repo>/.git/worktrees/<name>` resolves to `<repo>`. The walk does not use a `.git` found at `home` or above unless `cwd == home`. `exists` is whether `cwd` itself exists.
  - `project.group(sessions: SessionMeta[], opts?: { home: string, root_of: fun(cwd): string|nil, boolean }) -> Project[]` — `root_of` defaults to `git_root` with results cached per cwd.
- Grouping: key = git root, else the cwd, else (no cwd) the transcript's parent directory name. `name` = basename of key; when two projects share a basename, both become `<parent>/<basename>`. `missing` = cwd does not exist or is nil. `subpath` set when cwd is below root. Projects sorted by newest session, sessions newest first.

- [ ] **Step 1: Write the failing tests.** Build real directories under `vim.fn.tempname()`: `repo/` with `.git/` dir and `repo/sub/deep/`; `wt/` with a `.git` file `gitdir: <tmp>/repo/.git/worktrees/wt`; `plain/`; `homefake/` with `.git/` and `homefake/stuff/`.

```lua
T['git_root: nested folder, worktree, plain, home rule, vanished folder'] = function()
  eq({ P.git_root(tmp .. '/repo/sub/deep', '/nohome') }, { tmp .. '/repo', true })
  eq({ P.git_root(tmp .. '/wt', '/nohome') }, { tmp .. '/repo', true })
  eq({ P.git_root(tmp .. '/plain', '/nohome') }, { nil, true })
  eq({ P.git_root(tmp .. '/homefake/stuff', tmp .. '/homefake') }, { nil, true })
  eq({ P.git_root(tmp .. '/homefake', tmp .. '/homefake') }, { tmp .. '/homefake', true })
  eq({ P.git_root(tmp .. '/repo/gone/dir', '/nohome') }, { tmp .. '/repo', false })
end
T['group: sub-folders and worktrees fold into one project'] = function()
  local ps = P.group({
    { id = 'a', cwd = tmp .. '/repo', mtime = 10, title = 'A' },
    { id = 'b', cwd = tmp .. '/repo/sub/deep', mtime = 30, title = 'B' },
    { id = 'c', cwd = tmp .. '/wt', mtime = 20, title = 'C' },
    { id = 'd', cwd = tmp .. '/plain', mtime = 5, title = 'D' },
    { id = 'e', cwd = nil, path = '/x/projects/-nocwd/e.jsonl', mtime = 1, title = 'E' },
  }, { home = '/nohome' })
  eq(#ps, 3)
  eq({ ps[1].name, ps[1].is_git, ps[1].mtime, #ps[1].sessions }, { 'repo', true, 30, 3 })
  eq(vim.tbl_map(function(s) return s.id end, ps[1].sessions), { 'b', 'c', 'a' })
  eq(ps[1].sessions[1].subpath, 'sub/deep')
  eq({ ps[2].name, ps[2].is_git, ps[2].missing }, { 'plain', false, false })
  eq({ ps[3].name, ps[3].missing }, { '-nocwd', true })
end
T['group: same basename gets parent prefix'] = function()
  local ps = P.group({ { id = 'a', cwd = '/x/one/app', mtime = 2 }, { id = 'b', cwd = '/x/two/app', mtime = 1 } },
    { root_of = function() return nil, true end })
  eq({ ps[1].name, ps[2].name }, { 'one/app', 'two/app' })
end
```

- [ ] **Step 2:** Run `make test`. Expected: FAIL.
- [ ] **Step 3: Implement `project.lua`** with `vim.uv.fs_stat`.
- [ ] **Step 4:** Run `make test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: group sessions into projects by git repository`.

---

### Task 5: Live state and tmux jump

**Files:**
- Create: `lua/agent-ide/live.lua`, `lua/agent-ide/tmux.lua`
- Test: `tests/test_live.lua`

**Interfaces:**
- Produces:
  - `live.parse(text: string) -> table<string, { status: string, pid: integer, cwd: string, name: string|nil }>` keyed by `sessionId`; anything that is not a JSON array gives `{}`.
  - `live.state_of(map, session_id) -> State` — `status` of `busy`, `waiting`, `idle` passes through; absent or any other value is `parked`.
  - `live.rollup(states: State[]) -> State` — highest rank; empty list is `parked`.
  - `live.start(opts: { interval_ms: integer, cmd?: string[], on_change: fun(map) })`, `live.stop()`, `live.get() -> map`. Runs `cmd` (default `{ 'claude', 'agents', '--json' }`) with `vim.system` asynchronously, immediately and then every `interval_ms`. `on_change` fires only when the map differs from the previous one. If the command cannot start or exits non-zero: map `{}`, and a single `vim.notify` at WARN for the whole Neovim session.
  - `tmux.match_pane(tty: string, list_panes_output: string) -> string|nil` — output lines are `<pane_tty> <session>:<window>.<pane>`; `tty` may come without `/dev/`.
  - `tmux.jump_to_pid(pid: integer, cb: fun(ok: boolean, reason: string|nil))` — `ps -o tty= -p <pid>`, `tmux list-panes -a -F '#{pane_tty} #{session_name}:#{window_index}.#{pane_index}'`, then `tmux switch-client -t <target>`. Reasons: `not in tmux`, `process not found`, `pane not found`.

- [ ] **Step 1: Write the failing tests:**

```lua
T['parse keeps sessions by id, ignores garbage'] = function()
  local m = live.parse('[{"pid":7,"cwd":"/r","kind":"interactive","sessionId":"s1","name":"n","status":"busy"}]')
  eq(m.s1, { status = 'busy', pid = 7, cwd = '/r', name = 'n' })
  eq(live.parse('Error: not logged in'), {})
  eq(live.parse('{"a":1}'), {})
end
T['state_of and rollup'] = function()
  local m = { a = { status = 'idle' }, b = { status = 'weird' } }
  eq({ live.state_of(m, 'a'), live.state_of(m, 'b'), live.state_of(m, 'zz') }, { 'idle', 'parked', 'parked' })
  eq(live.rollup({ 'idle', 'busy', 'parked' }), 'busy')
  eq(live.rollup({ 'busy', 'waiting' }), 'waiting')
  eq(live.rollup({}), 'parked')
end
T['start: missing command gives empty map and one notice'] = function()
  local notices, changes = 0, 0
  local orig = vim.notify; vim.notify = function() notices = notices + 1 end
  live.start({ interval_ms = 30, cmd = { 'agent-ide-no-such-binary' }, on_change = function() changes = changes + 1 end })
  vim.wait(200); live.stop(); vim.notify = orig
  eq(live.get(), {}); eq(notices, 1)
end
T['start: reports a change once'] = function()
  local n = 0
  live.start({ interval_ms = 30, cmd = { 'echo', '[{"sessionId":"s","status":"idle","pid":1,"cwd":"/"}]' }, on_change = function() n = n + 1 end })
  vim.wait(200); live.stop()
  eq(n, 1); eq(live.get().s.status, 'idle')
end
T['match_pane'] = function()
  local out = '/dev/pts/3 work:1.0\n/dev/pts/9 neomd:2.1\n'
  eq(tmux.match_pane('pts/9', out), 'neomd:2.1')
  eq(tmux.match_pane('/dev/pts/3', out), 'work:1.0')
  eq(tmux.match_pane('pts/4', out), nil)
end
```

- [ ] **Step 2:** Run `make test`. Expected: FAIL.
- [ ] **Step 3: Implement** `live.lua` and `tmux.lua`.
- [ ] **Step 4:** Run `make test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: live session state and tmux pane jump`.

---

### Task 6: Drawer tree model

**Files:**
- Create: `lua/agent-ide/ui/tree.lua`, `lua/agent-ide/ui/highlights.lua`
- Test: `tests/test_tree.lua`

**Interfaces:**
- Consumes: Project, `live.state_of`, `live.rollup`.
- Produces:
  - `tree.ago(mtime: integer, now: integer) -> string` — under 90 s `now`; under 1 h `<n>m`; under 24 h `<n>h`; else `<n>d`.
  - `tree.build(projects: Project[], live_map, expanded: table<string, boolean>, now: integer, icons: table) -> { lines: string[], nodes: table[], hl: { line: integer, col_start: integer, col_end: integer, group: string }[] }`. `nodes[i]` describes line `i`: `{ type = 'project', project }`, `{ type = 'section', project, key }`, `{ type = 'session', project, session, state }`, or `{ type = 'hint' }`.
  - `highlights.setup()` defines, with `default = true` links: `AgentIdeProject` (bold), `AgentIdeWaiting`, `AgentIdeBusy`, `AgentIdeIdle`, `AgentIdeParked`, `AgentIdeMissing`, `AgentIdeAge`, `AgentIdeSection`. Spec colors: waiting violet, busy yellow, idle green, parked dimmed.
- Lines:
  - Project: `<arrow> <project_icon> <name>  <state_icon> <ago>`; missing projects add ` (gone)`. Expanded key is `project.key`.
  - Section (only when project expanded): `  <arrow> Sessions (<n>)`, key `project.key .. '/sessions'`; treated as expanded unless `expanded[key] == false`.
  - Session: `      <state_icon> <title>  <subpath in brackets, if any>  <ago>`. All sessions are listed, no cap.
  - No projects at all: single line `No Claude sessions found in <projects_dir>` with node type `hint`.
- `icons` keys: `open`, `closed`, `project`, `waiting`, `busy`, `idle`, `parked`. Tests pass plain ASCII icons; real defaults (nerd font) live in config (Task 7).

- [ ] **Step 1: Write the failing tests:**

```lua
local icons = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.' }
local projects = {
  { key = '/r/alpha', name = 'alpha', is_git = true, missing = false, mtime = 1000, sessions = {
    { id = 's1', title = 'Fix login', mtime = 1000 },
    { id = 's2', title = 'Docs', mtime = 400, subpath = 'docs' } } },
  { key = '/r/old', name = 'old', is_git = false, missing = true, mtime = 100, sessions = { { id = 's3', title = 'X', mtime = 100 } } },
}
T['ago'] = function()
  eq({ tree.ago(1000, 1050), tree.ago(1000, 1000 + 600), tree.ago(1000, 1000 + 7200), tree.ago(1000, 1000 + 3 * 86400) },
    { 'now', '10m', '2h', '3d' })
end
T['collapsed: one line per project with rolled-up state'] = function()
  local t = tree.build(projects, { s2 = { status = 'waiting' } }, {}, 1060, icons)
  eq(t.lines, { '> P alpha  W now', '> P old  . 16m (gone)' })
  eq(t.nodes[1].type, 'project')
end
T['expanded: section and all sessions'] = function()
  local t = tree.build(projects, { s1 = { status = 'busy' } }, { ['/r/alpha'] = true }, 1060, icons)
  eq(t.lines, { 'v P alpha  B now', '  v Sessions (2)', '      B Fix login  now', '      . Docs  [docs]  11m', '> P old  . 16m (gone)' })
  eq({ t.nodes[3].type, t.nodes[3].session.id, t.nodes[3].state }, { 'session', 's1', 'busy' })
  eq(t.nodes[2], { type = 'section', project = projects[1], key = '/r/alpha/sessions' })
end
T['section can be closed'] = function()
  local t = tree.build(projects, {}, { ['/r/alpha'] = true, ['/r/alpha/sessions'] = false }, 1060, icons)
  eq(#t.lines, 3)
end
T['highlights name the state group on the state icon'] = function()
  local t = tree.build(projects, { s1 = { status = 'busy' } }, {}, 1060, icons)
  local groups = vim.tbl_map(function(h) return h.group end, vim.tbl_filter(function(h) return h.line == 1 end, t.hl))
  eq(vim.tbl_contains(groups, 'AgentIdeBusy'), true)
  eq(vim.tbl_contains(groups, 'AgentIdeProject'), true)
end
T['empty'] = function()
  local t = tree.build({}, {}, {}, 0, icons)
  eq(t.nodes[1].type, 'hint')
end
```

- [ ] **Step 2:** Run `make test`. Expected: FAIL.
- [ ] **Step 3: Implement** `tree.lua` and `highlights.lua`. `tree.build` takes `projects_dir` for the hint line through an optional sixth argument.
- [ ] **Step 4:** Run `make test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: drawer tree model and highlight groups`.

---

### Task 7: Drawer, Agents tab, history view, setup

**Files:**
- Create: `lua/agent-ide/config.lua`, `lua/agent-ide/init.lua`, `lua/agent-ide/ui/drawer.lua`, `lua/agent-ide/ui/history.lua`, `plugin/agent-ide.lua`
- Modify: `lua/agent-ide/index/init.lua` (read `projects_dir` from config)
- Test: `tests/test_ui.lua`

**Interfaces:**
- Consumes: `index.scan`, `index.history`, `index.on_change`, `project.group`, `live.start/get/state_of`, `tree.build`, `render.render`, `render.fold_levels`, `tmux.jump_to_pid`, `highlights.setup`.
- Produces:
  - `require('agent-ide').setup(opts?)`, `.toggle()`.
  - Config defaults:

```lua
{
  projects_dir = vim.fn.expand('~/.claude/projects'),
  drawer = { width = 44, side = 'right' },
  live = { interval_ms = 5000, cmd = { 'claude', 'agents', '--json' } },
  helper = { enabled = true, path = nil },   -- nil: <plugin root>/helper/target/release/agent-ide-helper
  tcd = true,
  keys = { toggle = '<leader>aa' },          -- false disables the mapping
  icons = { open = '▾', closed = '▸', project = '', waiting = '◐', busy = '●', idle = '○', parked = '·' },
}
```

  - `:Agents` and the toggle key call `toggle()`.
  - `drawer.state()` returns `{ tab, win, buf, projects, nodes }` for tests.
  - `history.open(session, project)`.

Behavior:

- **Toggle:** no Agents tab → create a tab with an empty main window and the drawer on `drawer.side` at `drawer.width`, `winfixwidth`. In the Agents tab with drawer open → close the drawer window. In the Agents tab with drawer closed → reopen it. In another tab → switch to the Agents tab.
- **Drawer buffer:** `buftype=nofile`, `filetype=agent-ide`, not modifiable, no line numbers, `cursorline`. Renders immediately from the last known projects (empty on first open), then `index.scan` → `project.group` → re-render. Cursor stays on the same node (matched by project key / session id) across re-renders. Highlights applied from `tree.build().hl` with extmarks.
- **Keys in drawer:** `<CR>`, `o` — project or section: toggle expansion; session: open history. `za` — toggle expansion of the project/section under the cursor (on a session: its section). `R` — rescan and refresh live state now. `gp` — on a session with live state: `tmux.jump_to_pid`; otherwise or on failure a one-line notice with the reason. `q` — close the drawer window.
- **Live:** `live.start` when the Agents tab is created, `live.stop` when it closes. A change re-renders the drawer.
- **`index.on_change`** triggers a rescan (debounced 200 ms).
- **Opening a session:** the main window of the Agents tab (the non-drawer window; created if missing) shows the history buffer. When `tcd` is true and the project key exists as a directory, `:tcd` to it. The global working directory is never changed.
- **History buffer:** named `agent-ide://history/<session id>`, `buftype=nofile`, `filetype=markdown`, not modifiable. Shows `Loading…` until `index.history` returns, then the rendered lines. Window options: `wrap`, `linebreak`, `foldmethod=expr`, `foldexpr=v:lua.require'agent-ide.ui.history'.foldexpr(v:lnum)`, `foldlevel=0`, `foldtext=` (empty). Fold levels are stored per buffer from `render.fold_levels`. Cursor is placed on the last line. Winbar: `<project name> · <title> · <state> · history (read-only)`.
- **Reopening:** the buffer is reused when the transcript's mtime and size are unchanged, and reloaded when either changed.
- **Sending is not part of this plan.** Nothing in the history view accepts input.

- [ ] **Step 1: Write the failing tests** (each test runs in a fresh child Neovim via `MiniTest.new_child_neovim()`, started with `tests/minimal_init.lua`, with `setup({ projects_dir = <fixtures>, helper = { enabled = false }, live = { interval_ms = 50, cmd = { 'echo', '[{"sessionId":"11111111-1111-4111-8111-111111111111","status":"waiting","pid":1,"cwd":"/home/u/git/alpha"}]' } }, icons = <ASCII icons from Task 6> })`):

```lua
T['toggle creates Agents tab with drawer on the right at width 44'] -- tabpage count 2; drawer win is rightmost; width 44; filetype 'agent-ide'
T['drawer lists fixture projects with live state']  -- after wait: a line matching '^> P alpha  W ' exists; a line containing '(gone)' exists for '-nocwd'
T['enter on project expands; enter on session opens history']
  -- move to alpha line, <CR>; lines now contain 'Sessions ('; move to 'Alpha basics' line, <CR>
  -- main window buffer name ends with 'agent-ide://history/11111111-1111-4111-8111-111111111111'
  -- buffer contains '## You' and '▸ Bash:'; vim.fn.foldclosed(<line of '▸ Bash:'>) == that line
  -- vim.bo.modifiable == false; winbar contains 'history (read-only)'
T['history of a session with unknown records shows an unknown fold'] -- buffer contains '▸ unknown: future-thing'
T['global cwd unchanged, tab cwd set only when project folder exists']
  -- getcwd(-1, -1) before == after; create a temp git repo + fixture session pointing at it in a temp projects_dir, open it: getcwd(-1, 0) == that repo
T['toggle twice closes and reopens drawer; from another tab jumps back']
T['history reloads after the transcript file changes'] -- append a prompt record to a temp copy, reopen via drawer, new prompt text present
T['gp outside tmux reports a reason'] -- with $TMUX unset: last notification contains 'not in tmux'
T['q closes the drawer window, tab stays']
```

Write each as real mini.test cases with `child.lua_get`, `child.type_keys` and `MiniTest.expect.equality`, using the assertions in the comments.

- [ ] **Step 2:** Run `make test`. Expected: FAIL, `agent-ide` module has no `setup`.
- [ ] **Step 3: Implement** `config.lua`, `init.lua`, `plugin/agent-ide.lua`, `ui/drawer.lua`, `ui/history.lua`.
- [ ] **Step 4:** Run `make test`. Expected: PASS.
- [ ] **Step 5: Manual check on real data.** `nvim --cmd "set rtp+=." -c "lua require('agent-ide').setup()" -c Agents`. Confirm: projects appear grouped by repository (one `dotfiles` row), states match the tmux sessions that are open, a large real session opens with folds closed, `za` opens a fold, `gp` on a live session switches tmux to its pane. Record what was observed in the commit body. Do not paste session content.
- [ ] **Step 6: Commit** `feat: Agents tab with drawer and read-only history view`.

---

### Task 8: Rust helper

**Files:**
- Create: `helper/Cargo.toml`, `helper/src/main.rs`, `protocol.rs`, `events.rs`, `scan.rs`, `cache.rs`, `watch.rs`
- Test: unit tests in each module; `helper/tests/golden.rs`

**Interfaces:**
- Produces binary `agent-ide-helper [--cache-dir <dir>]`. Protocol: one JSON object per line on stdin and stdout.
  - Request `{"id":<n>,"method":"scan","params":{"projects_dir":"…"}}` → `{"id":<n>,"result":{"sessions":[SessionMeta…]}}`
  - Request `{"id":<n>,"method":"history","params":{"path":"…"}}` → `{"id":<n>,"result":{"events":[Event…]}}`
  - Request `{"id":<n>,"method":"watch","params":{"projects_dir":"…"}}` → `{"id":<n>,"result":{}}`, then notifications `{"method":"changed","params":{"paths":["…"]}}`, batched at most once per 200 ms.
  - Errors: `{"id":<n>,"error":{"message":"…"}}`. Unknown method and malformed request lines produce an error response (id `null` when unreadable) and the process keeps running. Exits when stdin closes.
- SessionMeta and Event JSON use exactly the field names in Shared Types. `cwd` and `branch` are `null` when absent. `sidechain` is present only when true. `tool_call.input` is passed through unchanged. `unknown.raw` is the original line text for unknown records, and the block's compact JSON for unknown blocks.
- Unlike the Lua fallback, `scan` reads whole files, so the title is the last `aiTitle` anywhere in the file. Files are processed in parallel (rayon).
- Cache: `<cache-dir>/index-v1.json`, map path → `{ mtime, size, meta }`. An entry is reused only when both mtime and size match. A corrupt or unreadable cache file is ignored and rewritten. Without `--cache-dir` there is no cache.

- [ ] **Step 1: Write the failing tests.**
  - `tests/golden.rs`: for every `tests/fixtures/golden/*.events.json` in the repo root, parse the matching fixture transcript with `events::parse_text` and assert equality with the golden as `serde_json::Value`. (Map of golden name → fixture path is a small table in the test; `alpha-basic` → the Task 1 fixture.)
  - `scan.rs` tests: scanning `tests/fixtures/projects` returns 4 sessions; the `1111…` one has title `Alpha basics`, cwd `/home/u/git/alpha`, branch `feat/x`; `4444…` has title `(untitled)` and null cwd; a missing directory returns an empty list.
  - `cache.rs` tests: second scan with unchanged files does not re-read them (assert through a read counter); changing a file's size invalidates its entry; a cache file containing `garbage` is ignored.
  - `protocol.rs` tests: a line `nonsense` yields an error response with `id: null`; `{"id":3,"method":"nope"}` yields an error with id 3.
  - `events.rs` test: a cut-off last line and an invalid line yield no events and no error.
- [ ] **Step 2:** Run `make test-helper`. Expected: FAIL to compile, modules missing.
- [ ] **Step 3: Implement** the crate. Dependencies: `serde`, `serde_json` (with `preserve_order`), `rayon`, `notify`. `events.rs` follows the record-to-event table of Task 1, including any types added by its survey step.
- [ ] **Step 4:** Run `make test-helper`. Expected: PASS. Run `make helper`. Expected: binary at `helper/target/release/agent-ide-helper`.
- [ ] **Step 5: Parity check on real data (counts only).** A throwaway script runs both backends over every real transcript and prints, per file, only whether the two event lists are equal, plus totals. Expected: all equal. Any difference: fix the side that departs from the Task 1 table, and add a synthetic record reproducing it to the fixture and golden.
- [ ] **Step 6: Commit** `feat: Rust helper for scan, history and change watching`.

---

### Task 9: Helper client and backend choice

**Files:**
- Create: `lua/agent-ide/index/helper.lua`
- Modify: `lua/agent-ide/index/init.lua`
- Test: `tests/test_helper_client.lua`

**Interfaces:**
- Consumes: the helper protocol of Task 8; `lua_scan`.
- Produces:
  - `helper.path() -> string` (config `helper.path` or the default), `helper.available() -> boolean` (file exists and is executable).
  - `helper.request(method: string, params: table, cb: fun(err: string|nil, result: table|nil))` — starts the process on first use with `--cache-dir <stdpath('cache')>/agent-ide`; times out after 5000 ms with `err = 'timeout'`.
  - `helper.on(method: string, fn: fun(params))`, `helper.stop()`.
  - `index.backend()` returns `'helper'` when `config.helper.enabled` and `helper.available()`, else `'lua'`.
  - `index.scan` / `index.history` use the helper when it is the backend. On any helper error, timeout or process exit they answer that same request through `lua_scan`, switch the backend to `'lua'` for the rest of the session, and notify once at WARN: `Agent-IDE: helper failed (<reason>), using Lua fallback`.
  - `index.on_change(fn)`: with the helper, sends `watch` once and calls `fn` on each `changed` notification. With the Lua backend, `fn` is called by a timer every 5000 ms only while the drawer is visible (`index.set_visible(boolean)`, called by the drawer).
  - JSON from the helper is decoded with `luanil` for objects and arrays so events are identical to the Lua backend's.

- [ ] **Step 1: Write the failing tests.** Tests that need the binary call `MiniTest.skip('helper not built')` when `helper.available()` is false; `make test` depends on `make helper` in CI and locally when cargo exists.

```lua
T['backend is lua when helper disabled or missing']      -- enabled=false -> 'lua'; path='/nonexistent' -> 'lua'
T['helper scan equals lua scan on fixtures']             -- same ids, titles, cwd, branch (compare sorted by id)
T['helper history equals lua history on fixture']        -- deep equality of event lists
T['failing helper falls back and notifies once']
  -- config.helper.path = a script that prints 'garbage' and exits 1 (written to tempname, chmod +x)
  -- index.scan still returns 4 sessions; index.backend() == 'lua'; exactly one WARN notification after two scans
T['changed notification reaches on_change']              -- watch a temp projects_dir, append to a transcript, fn called within 2 s
```

- [ ] **Step 2:** Run `make test`. Expected: FAIL, module `agent-ide.index.helper` not found.
- [ ] **Step 3: Implement** `helper.lua` and the backend choice in `index/init.lua`; call `index.set_visible` from `drawer.lua`.
- [ ] **Step 4:** Run `make helper test`. Expected: PASS, no skipped helper tests.
- [ ] **Step 5: Commit** `feat: use Rust helper when present, Lua fallback otherwise`.

---

### Task 10: Speed budgets, docs, cleanup, wiring

**Files:**
- Create: `tests/bench.lua`, `README.md`
- Delete: `spike/agent_spike.lua`
- Create (other repo): `~/git/general/dotfiles/nvim/.config/nvim/lua/sspaeti/plugins/agent-ide.lua`
- Test: `tests/test_budget.lua`

**Interfaces:**
- Consumes: everything above.
- Produces: `make bench` printing a table; a budget test.

- [ ] **Step 1: Write `tests/bench.lua`.** It generates, under `tempname()`, 60 project directories with 5 synthetic sessions each (about 200 KB each: repeated prompt / text / tool_use / tool_result records plus `api-request-blob` filler lines), and one 1 MB session. It measures, for each backend available: (a) time from `toggle()` until the drawer buffer shows 60 project lines on a second open (index warm), (b) the same on first open (cold), (c) time from Enter on the 1 MB session until the history buffer is filled, (d) the longest single blocking stretch on the UI thread during a cold scan, measured with a 1 ms repeating timer and the largest gap between its ticks. Prints one row per measurement with the spec budget next to it.

- [ ] **Step 2: Write the failing budget test** `tests/test_budget.lua`, using the same generator at the same size:

```lua
T['warm drawer open under 50 ms']            -- measurement (a) < 50
T['1 MB history under 150 ms with helper']   -- measurement (c) < 150; skipped when helper not built
T['cold Lua scan never blocks the UI longer than 16 ms'] -- measurement (d) < 16
```

- [ ] **Step 3:** Run `make helper test`. Expected: budget tests pass, or fail with numbers. For each failure, profile and fix the cause in the owning module (typical: decoding bookkeeping lines, chunk size too large, re-rendering the drawer per file instead of once). Do not loosen a budget; if one cannot be met, stop and report the numbers.

- [ ] **Step 4:** Run `make bench` on the real `~/.claude/projects` (pass the directory as an argument; print timings only). Record the numbers in the commit body.

- [ ] **Step 5: README.md.** Sections: what it is (two sentences), status (part 1 of 6: drawer and history; chat, prompts, git review, Omarchy indicator, other agents to come), requirements (Neovim 0.12+, Claude Code; optional: cargo for the helper, tmux for jump-to-pane), install with lazy.nvim (`build = 'make helper'`), default configuration block (copied from `config.lua`), keys in the drawer, how privacy is handled (reads local transcripts, sends nothing anywhere), running tests.

- [ ] **Step 6: Delete the spike** (`git rm -r spike`). The design's section 11 says it goes when part 1 lands.

- [ ] **Step 7: Wire into the user's Neovim config.** Create `lua/sspaeti/plugins/agent-ide.lua` in the dotfiles repo:

```lua
return {
  {
    dir = '~/git/neovim/agents-ide.nvim',
    name = 'agent-ide.nvim',
    build = 'make helper',
    cmd = 'Agents',
    keys = { { '<leader>aa', '<cmd>Agents<cr>', desc = 'Agent-IDE: toggle drawer' } },
    opts = {},
  },
}
```

Check first that nothing else in that config maps `<leader>aa` (`grep -rn "leader>aa" lua/`). Do not commit in the dotfiles repo; leave that change for the user and say so in the final report.

- [ ] **Step 8: Final verification.** `make helper test test-helper` all pass. Start the user's normal Neovim, press `<leader>aa`: drawer opens; `:checkhealth` shows no errors from the plugin; lualine, markdown renderer and `<C-h/j/k/l>` window navigation still work inside the Agents tab.

- [ ] **Step 9: Commit** `feat: speed budgets, README, remove spike`.

---

## Not in this plan (later parts)

Chat and prompt buffer, permissions, model and mode switching, footer quota and status colors, status file, raw view (part 2). Prompts node (part 3). Changes and Commits nodes, diff view, lazygit launcher (part 4). Omarchy indicator (part 5). Other agents (part 6). Full-text search across sessions (after part 1; the helper is where it will live).
