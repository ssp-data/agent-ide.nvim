-- Closing a Claude in a tmux pane (ui/tmux_close.lua): `X` on a drawer row and :AgentsCloseIdle.
-- A fake `tmux` and a fake `ps` on PATH: `tmux` records its arguments, prints the panes from
-- files and, on the second `send-keys` into a pane, ends that pane's "Claude" (a `sleep` this test
-- started) when a `victim-<pane>` file names it, as Claude's double Ctrl-C would. `ps -A` prints
-- the process tree from a file, `ps -p` the ttys for the drawer's pane labels.
local eq = MiniTest.expect.equality
local close = require('agent-ide.ui.tmux_close')
local child = MiniTest.new_child_neovim()

local A, B, C = '0000000a-0000-4000-8000-000000000000', '0000000b-0000-4000-8000-000000000000',
  '0000000c-0000-4000-8000-000000000000'
local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F' }

local FAKE_TMUX = [[#!/bin/sh
for a in "$@"; do printf '%s\037' "$a"; done >> "$FAKE_DIR/log"
printf '\n' >> "$FAKE_DIR/log"
case "$1" in
  list-panes)
    case "$*" in *pane_pid*) cat "$FAKE_DIR/panes" ;; *) cat "$FAKE_DIR/labels" ;; esac
    exit 0 ;;
  send-keys)
    f="$FAKE_DIR/sent-$3"
    n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$f"
    if [ "$n" -ge 2 ] && [ -e "$FAKE_DIR/victim-$3" ]; then kill "$(cat "$FAKE_DIR/victim-$3")" 2>/dev/null; fi
    exit 0 ;;
esac
exit 0
]]
local FAKE_PS = [[#!/bin/sh
case "$*" in *-A*) cat "$FAKE_DIR/ps_all" ;; *) cat "$FAKE_DIR/ps_tty" ;; esac
]]

local tmp, dir, procs

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    dir = tmp .. '/fake'
    vim.fn.mkdir(dir .. '/bin', 'p')
    vim.fn.writefile(vim.split(FAKE_TMUX, '\n'), dir .. '/bin/tmux')
    vim.fn.writefile(vim.split(FAKE_PS, '\n'), dir .. '/bin/ps')
    vim.fn.setfperm(dir .. '/bin/tmux', 'rwxr-xr-x')
    vim.fn.setfperm(dir .. '/bin/ps', 'rwxr-xr-x')
    local pdir = tmp .. '/projects/-x-repo'
    vim.fn.mkdir(pdir, 'p')
    for id, title in pairs({ [A] = 'Alpha task', [B] = 'Beta task', [C] = 'Gamma task' }) do
      local rec = vim.json.encode({ type = 'user', uuid = 'u-' .. id, cwd = '/x/repo', message = { role = 'user', content = title } })
      vim.fn.writefile({ rec }, pdir .. '/' .. id .. '.jsonl')
    end
    procs = {}
  end,
  post_case = function()
    child.stop()
    for _, p in ipairs(procs) do pcall(p.kill, p, 9) end
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

-- A stand-in "Claude": a process that runs until killed.
local function claude_proc()
  local p = vim.system({ 'sleep', '60' })
  procs[#procs + 1] = p
  return p.pid
end

local function alive(pid) return vim.uv.kill(pid, 0) == 0 end

-- `sessions`: { { id, status, pid, pane = '%5', label = '2.1', tty = 'pts/5', victim = true } }:
-- the live list, the process tree (pid -> pane shell 500+n -> 1), the panes and their labels.
local function world(sessions)
  local live, ps_all, ps_tty, panes, labels = {}, {}, {}, {}, {}
  for n, s in ipairs(sessions) do
    live[#live + 1] = { sessionId = s.id, status = s.status, pid = s.pid, cwd = '/x/repo' }
    if s.pane then
      local shell = 500 + n
      ps_all[#ps_all + 1] = s.pid .. ' ' .. shell
      ps_all[#ps_all + 1] = shell .. ' 1'
      ps_tty[#ps_tty + 1] = s.pid .. ' ' .. s.tty
      panes[#panes + 1] = s.pane .. ' ' .. shell .. ' ' .. s.label
      labels[#labels + 1] = '/dev/' .. s.tty .. ' ' .. s.label
      if s.victim then vim.fn.writefile({ tostring(s.pid) }, dir .. '/victim-' .. s.pane) end
    end
  end
  vim.fn.writefile({ vim.json.encode(live) }, dir .. '/live.json')
  vim.fn.writefile(ps_all, dir .. '/ps_all')
  vim.fn.writefile(ps_tty, dir .. '/ps_tty')
  vim.fn.writefile(panes, dir .. '/panes')
  vim.fn.writefile(labels, dir .. '/labels')
end

local function start(opts)
  opts = opts or {}
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local dir, in_tmux, setup = ...
    vim.env.FAKE_DIR = dir
    vim.env.PATH = dir .. '/bin:' .. vim.env.PATH
    vim.env.TMUX = in_tmux and '/tmp/fake-tmux,1,0' or nil
    local close = require('agent-ide.ui.tmux_close')
    close._gap_ms, close._wait_ms, close._step_ms = 50, 600, 20
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    _G.confirms, _G.answers = {}, {}
    vim.fn.confirm = function(msg, choices, default)
      table.insert(_G.confirms, { msg = msg, choices = choices, default = default })
      if _G.hook then _G.hook() end
      return table.remove(_G.answers, 1) or default
    end
    require('agent-ide').setup(setup)
  ]], { dir, opts.in_tmux ~= false, {
    projects_dir = tmp .. '/projects',
    helper = { enabled = false },
    live = { interval_ms = 100, cmd = { 'cat', dir .. '/live.json' } },
    icons_style = 'plain', icons = ICONS,
  } })
end

local function wait_for(cond, what, ms)
  if not vim.wait(ms or 5000, cond, 20) then error('timed out waiting for ' .. what, 2) end
end

local function has_line(lines, text)
  for i, l in ipairs(lines) do
    if l:find(text, 1, true) then return i end
  end
end

local function drawer_lines()
  return child.lua_get([[(function()
    local s = require('agent-ide.ui.drawer').state()
    return s.buf and vim.api.nvim_buf_get_lines(s.buf, 0, -1, false) or {}
  end)()]])
end

local function drawer_cursor_to(text)
  wait_for(function() return has_line(drawer_lines(), text) ~= nil end, 'drawer line ' .. text)
  local row = has_line(drawer_lines(), text)
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })', { row })
end

local function show_drawer()
  child.lua('require("agent-ide").toggle()')
  drawer_cursor_to('> repo')
  child.type_keys('<CR>')
  wait_for(function() return has_line(drawer_lines(), 'Alpha task') ~= nil end, 'sessions')
end

-- tmux calls in order, as argument lists.
local function calls()
  local out = {}
  if vim.fn.filereadable(dir .. '/log') == 0 then return out end
  for _, l in ipairs(vim.fn.readfile(dir .. '/log')) do
    if l ~= '' then
      local args = vim.split(l, '\031', { plain = true })
      if args[#args] == '' then table.remove(args) end
      out[#out + 1] = args
    end
  end
  return out
end
local function sent()
  return vim.tbl_filter(function(c) return c[1] == 'send-keys' end, calls())
end

local function notes() return child.lua_get('_G.notes') end
local function last_note() local n = notes(); return n[#n] or '' end
local function confirms() return child.lua_get('_G.confirms') end

-- Pure ----------------------------------------------------------------------------------------

T['pane_of: the pane whose process is the pid or an ancestor of it'] = function()
  local parents = close.parse_parents('  42   7\n   7   1\n 99 1\n')
  local panes = close.parse_panes('%3 7 2.1\n%4 99 3.0\nnot a pane\n')
  eq(panes, { { id = '%3', pid = 7, label = '2.1' }, { id = '%4', pid = 99, label = '3.0' } })
  eq(close.pane_of(42, parents, panes).id, '%3')
  eq(close.pane_of(99, parents, panes).id, '%4')
  eq(close.pane_of(43, parents, panes), nil) -- not running
  eq(close.pane_of(42, parents, { { id = '%4', pid = 99, label = '3.0' } }), nil)
end

-- X on a drawer row ------------------------------------------------------------------------

local function idle_world(status, victim)
  local pid = claude_proc()
  world({ { id = A, status = status or 'idle', pid = pid, pane = '%5', label = '2.1', tty = 'pts/5', victim = victim ~= false } })
  return pid
end

T['X on an idle session in a pane: confirm (default No), Ctrl-C twice into its pane id, closed'] = function()
  local pid = idle_world()
  start()
  show_drawer()
  wait_for(function() return has_line(drawer_lines(), 'tmux 2.1') ~= nil end, 'pane label')
  drawer_cursor_to('Alpha task')
  child.lua('_G.answers = { 1 }')
  child.type_keys('X')
  wait_for(function() return last_note() == 'Agent-IDE: closed "Alpha task"' end, 'closed notice')
  local c = confirms()
  eq(#c, 1)
  eq(c[1], { msg = 'Close Claude "Alpha task" in tmux pane 2.1 (idle)?', choices = '&Close\n&Cancel', default = 2 })
  eq(sent(), { { 'send-keys', '-t', '%5', 'C-c' }, { 'send-keys', '-t', '%5', 'C-c' } })
  eq(alive(pid), false)
  -- the lookup right before acting: the process tree and the panes with their ids
  local i = 0
  for n, call in ipairs(calls()) do if call[1] == 'send-keys' and i == 0 then i = n end end
  eq(calls()[i - 1], { 'list-panes', '-a', '-F', '#{pane_id} #{pane_pid} #{window_index}.#{pane_index}' })
end

T['X: No sends nothing; a working or waiting session asks again'] = function()
  local pid = idle_world()
  start()
  show_drawer()
  wait_for(function() return has_line(drawer_lines(), 'tmux 2.1') ~= nil end, 'pane label')
  drawer_cursor_to('Alpha task')
  child.lua('_G.answers = { 2 }')
  child.type_keys('X')
  vim.wait(200)
  eq(sent(), {})
  eq(alive(pid), true)
  -- busy there: a second confirm, No
  child.lua('_G.confirms = {}; _G.answers = { 1, 2 }')
  idle_world('busy')
  wait_for(function() return has_line(drawer_lines(), 'B Alpha task') ~= nil end, 'busy row')
  drawer_cursor_to('Alpha task')
  child.type_keys('X')
  vim.wait(200)
  local c = confirms()
  eq(#c, 2)
  eq(c[1].msg:find('(working)', 1, true) ~= nil, true)
  eq(c[2], { msg = 'It is working; close anyway?', choices = '&Close anyway\n&Cancel', default = 2 })
  eq(sent(), {})
  -- waiting for input, both Yes: closed
  child.lua('_G.confirms = {}; _G.answers = { 1, 1 }')
  local p2 = idle_world('waiting')
  wait_for(function() return has_line(drawer_lines(), 'W Alpha task') ~= nil end, 'waiting row')
  drawer_cursor_to('Alpha task')
  child.type_keys('X')
  wait_for(function() return #sent() == 2 end, 'keys sent')
  eq(confirms()[2].msg, 'It is waiting for input; close anyway?')
  wait_for(function() return not alive(p2) end, 'ended')
end

T['X: the pane gone, or the pid no longer below it, by the time it acts: nothing sent'] = function()
  idle_world()
  start()
  show_drawer()
  wait_for(function() return has_line(drawer_lines(), 'tmux 2.1') ~= nil end, 'pane label')
  drawer_cursor_to('Alpha task')
  -- the pane closes while the confirm is open
  child.lua('_G.answers = { 1 }; _G.hook = function() vim.fn.writefile({}, vim.env.FAKE_DIR .. "/panes"); _G.hook = nil end')
  child.type_keys('X')
  wait_for(function() return last_note():find('is gone or runs something else; nothing sent', 1, true) ~= nil end, 'notice')
  eq(sent(), {})
  -- the pane is there, but now runs another program: the Claude is not its descendant
  local pid = idle_world()
  wait_for(function() return has_line(drawer_lines(), 'tmux 2.1') ~= nil end, 'pane label')
  drawer_cursor_to('Alpha task')
  child.lua([[_G.notes = {}; _G.answers = { 1 }; _G.hook = function()
    vim.fn.writefile({ ']] .. pid .. [[ 900', '900 1', '501 1' }, vim.env.FAKE_DIR .. '/ps_all'); _G.hook = nil end]])
  child.type_keys('X')
  wait_for(function() return last_note():find('nothing sent', 1, true) ~= nil end, 'notice 2')
  eq(sent(), {})
  eq(alive(pid), true)
end

T['X: still running after the wait: a notice, nothing more'] = function()
  local pid = idle_world('idle', false)
  start()
  show_drawer()
  wait_for(function() return has_line(drawer_lines(), 'tmux 2.1') ~= nil end, 'pane label')
  drawer_cursor_to('Alpha task')
  child.lua('_G.answers = { 1 }')
  child.type_keys('X')
  wait_for(function() return last_note():find('still runs 5 s later (pane 2.1); nothing more was done', 1, true) ~= nil end, 'notice')
  eq(#sent(), 2)
  eq(alive(pid), true)
end

T['X: outside tmux, pane unknown, owned here, not running: a notice, nothing sent'] = function()
  idle_world()
  start({ in_tmux = false })
  show_drawer()
  wait_for(function() return has_line(drawer_lines(), 'elsewhere') ~= nil end, 'elsewhere row')
  drawer_cursor_to('Alpha task')
  child.type_keys('X')
  eq(last_note(), 'Agent-IDE: cannot reach that session (no tmux pane known here); gp jumps to it')
  -- in tmux, but the pane is unknown
  world({ { id = A, status = 'idle', pid = claude_proc() } })
  start()
  show_drawer()
  wait_for(function() return has_line(drawer_lines(), 'elsewhere') ~= nil end, 'elsewhere row')
  drawer_cursor_to('Alpha task')
  child.type_keys('X')
  eq(last_note(), 'Agent-IDE: cannot reach that session (no tmux pane known here); gp jumps to it')
  -- a session this Neovim runs; one that runs nowhere
  child.lua('require("agent-ide.session").open({ id = ..., cwd = "/x/repo" }).owned = true', { A })
  child.type_keys('X')
  eq(last_note(), 'Agent-IDE: this session runs in this Neovim; use x to park it')
  drawer_cursor_to('Beta task')
  child.type_keys('X')
  eq(last_note(), 'Agent-IDE: session is not running')
  eq(confirms(), {})
  eq(sent(), {})
end

-- :AgentsCloseIdle ---------------------------------------------------------------------------

T[':AgentsCloseIdle: one confirm with the count, Ctrl-C twice into each idle pane; a predicate limits it'] = function()
  local pa, pb, pc = claude_proc(), claude_proc(), claude_proc()
  world({
    { id = A, status = 'idle', pid = pa, pane = '%5', label = '2.1', tty = 'pts/5', victim = true },
    { id = B, status = 'idle', pid = pb, pane = '%6', label = '2.2', tty = 'pts/6', victim = true },
    { id = C, status = 'busy', pid = pc, pane = '%7', label = '3.0', tty = 'pts/7', victim = true },
  })
  start()
  child.lua('_G.answers = { 1 }')
  child.cmd('AgentsCloseIdle')
  wait_for(function() return last_note():find('closed', 1, true) ~= nil end, 'summary')
  eq(last_note(), 'Agent-IDE: closed 2 of 2')
  eq(confirms(), { { msg = 'Close 2 idle Claude session(s) in tmux panes?', choices = '&Close\n&Cancel', default = 2 } })
  local keys = vim.tbl_map(function(c) return table.concat(c, ' ') end, sent())
  table.sort(keys)
  eq(keys, { 'send-keys -t %5 C-c', 'send-keys -t %5 C-c', 'send-keys -t %6 C-c', 'send-keys -t %6 C-c' })
  eq({ alive(pa), alive(pb), alive(pc) }, { false, false, true })
  -- a predicate: only B; No sends nothing
  vim.fn.delete(dir .. '/log')
  pa, pb = claude_proc(), claude_proc()
  world({
    { id = A, status = 'idle', pid = pa, pane = '%5', label = '2.1', tty = 'pts/5', victim = true },
    { id = B, status = 'idle', pid = pb, pane = '%6', label = '2.2', tty = 'pts/6', victim = true },
  })
  vim.fn.delete(dir .. '/sent-%5')
  vim.fn.delete(dir .. '/sent-%6')
  child.lua('_G.confirms = {}; _G.answers = { 2 }')
  child.cmd('AgentsCloseIdle')
  wait_for(function() return #confirms() == 1 end, 'confirm')
  vim.wait(100)
  eq(sent(), {})
  child.lua('_G.confirms = {}; _G.answers = { 1 }')
  child.lua('local only = ...; require("agent-ide.ui.tmux_close").close_idle(function(id) return id == only end)', { B })
  wait_for(function() return last_note() == 'Agent-IDE: closed 1 of 1' end, 'summary 2')
  eq(confirms()[1].msg, 'Close 1 idle Claude session(s) in tmux panes?')
  eq(sent(), { { 'send-keys', '-t', '%6', 'C-c' }, { 'send-keys', '-t', '%6', 'C-c' } })
  eq({ alive(pa), alive(pb) }, { true, false })
end

T[':AgentsCloseIdle: outside tmux, or nothing idle in a pane: a notice, no confirm'] = function()
  idle_world('busy')
  start({ in_tmux = false })
  child.cmd('AgentsCloseIdle')
  eq(last_note(), 'Agent-IDE: not in tmux; nothing to close')
  start()
  child.cmd('AgentsCloseIdle')
  wait_for(function() return #notes() > 0 end, 'notice')
  eq(last_note(), 'Agent-IDE: no idle Claude sessions in tmux panes')
  eq(confirms(), {})
  eq(sent(), {})
end

return T
