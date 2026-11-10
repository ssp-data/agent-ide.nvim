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

-- `sessions`: { { id, status, pid, pane = '%5', label = '2.1', tty = 'pts/5', victim = true,
-- fg = false, cwd } }: the live list, the process list (`ps -A`: pid, parent shell 500+n, its group,
-- the terminal's foreground group, tty, `claude`), the ttys (`ps -p`), the panes and their labels.
local function world(sessions)
  local live, ps_all, ps_tty, panes, labels = {}, {}, {}, {}, {}
  for n, s in ipairs(sessions) do
    live[#live + 1] = { sessionId = s.id, status = s.status, pid = s.pid, cwd = s.cwd or '/x/repo' }
    if s.pane then
      local shell = 500 + n
      ps_all[#ps_all + 1] = ('%d %d %d %d %s claude'):format(s.pid, shell, s.pid, s.fg == false and 999 or s.pid, s.tty)
      ps_all[#ps_all + 1] = ('%d 1 %d %d %s zsh'):format(shell, shell, s.fg == false and 999 or s.pid, s.tty)
      ps_tty[#ps_tty + 1] = s.pid .. ' ' .. s.tty
      panes[#panes + 1] = ('%s %d /dev/%s 0 0 %s'):format(s.pane, shell, s.tty, s.label)
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

-- A drawer line holding every one of `texts` (a row's mark, title and its pane label).
local function row_with(...)
  local texts = { ... }
  for _, l in ipairs(drawer_lines()) do
    local all = true
    for _, t in ipairs(texts) do all = all and l:find(t, 1, true) ~= nil end
    if all then return true end
  end
  return false
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

local V = require('agent-ide.ui.tmux_verify')

T['verify: the Claude must be the foreground program of a pane\'s terminal, the pane in no mode'] = function()
  local procs = V.parse_ps(table.concat({
    '  42   7  42  42 pts/5    claude',
    '  43   7  43  99 pts/5    claude', -- suspended or a background job: another group in front
    '  44   8  44  44 pts/9    claude', -- on a terminal no pane has (a Neovim :terminal)
    '  45   7  45  45 pts/6    vim',
    '  46   1  46  -1 ?        claude', -- no terminal (started by another program without one)
    '  47   7  47  47 pts/7    /usr/local/bin/node',
    '  48   7  48  48 pts/8    claude',
    '  49   7  49  49 pts/10   claude',
  }, '\n'))
  eq(procs[42], { pgid = 42, tpgid = 42, tty = 'pts/5', comm = 'claude' })
  local panes = V.parse_panes(table.concat({
    '%5 7 /dev/pts/5 0 0 2.1', '%6 7 /dev/pts/6 0 0 2.2', '%7 7 /dev/pts/7 0 0 2.3',
    '%8 7 /dev/pts/8 1 0 2.4', '%10 7 /dev/pts/10 0 1 3.0', 'not a pane',
  }, '\n'))
  eq(panes[1], { id = '%5', pid = 7, tty = 'pts/5', in_mode = false, sync = false, label = '2.1' })
  eq(V.verify(42, procs, panes).id, '%5')
  eq(V.verify(47, procs, panes).id, '%7') -- node (an npm install)
  local function why(pid) return select(2, V.verify(pid, procs, panes)) end
  eq(why(43), 'it is not in the foreground of its pane')
  eq(why(44), 'no tmux pane shows it')
  eq(why(45), 'that process is not Claude')
  eq(why(46), 'it has no terminal')
  eq(why(48), 'its pane is in copy mode')
  eq(why(49), 'its window synchronizes panes')
  eq(why(50), 'it no longer runs')
end

T['a process of another user counts as running (EPERM), only ESRCH as gone'] = function()
  eq(close._exists(1), true) -- init: not ours to signal, but it runs
  eq(close._exists(vim.uv.os_getpid()), true)
  eq(close._exists(4194303 + 1000), false)
end

-- X on a drawer row ------------------------------------------------------------------------

local function idle_world(status, victim, extra)
  local pid = claude_proc()
  world({ vim.tbl_extend('force', { id = A, status = status or 'idle', pid = pid, pane = '%5', label = '2.1', tty = 'pts/5',
    victim = victim ~= false }, extra or {}) })
  return pid
end

local LOST = ' Text typed in its input box is lost.'

-- The drawer's live map has caught up with Claude `pid` of session A.
local function wait_pid(pid)
  wait_for(function() return child.lua_get('(require("agent-ide.live").get()[...] or {}).pid', { A }) == pid end, 'live pid')
end

T['X on an idle session in a pane: confirm (default No), fresh check, Ctrl-C twice into its pane id, closed'] = function()
  local pid = idle_world()
  start()
  show_drawer()
  wait_for(function() return has_line(drawer_lines(), 'tmux 2.1') ~= nil end, 'pane label')
  drawer_cursor_to('Alpha task')
  child.lua('_G.answers = { 1 }')
  child.type_keys('X')
  -- the confirm comes at once, on the key
  eq(#confirms(), 1)
  wait_for(function() return last_note() == 'Agent-IDE: closed "Alpha task"' end, 'closed notice')
  local c = confirms()
  eq(#c, 1)
  eq(c[1], { msg = 'Close Claude "Alpha task" in tmux pane 2.1 (idle)?' .. LOST, choices = '&Close\n&Cancel', default = 2 })
  eq(sent(), { { 'send-keys', '-t', '%5', 'C-c' }, { 'send-keys', '-t', '%5', 'C-c' } })
  eq(alive(pid), false)
  -- the verification right before acting: the panes with their ttys, modes and sync
  local i = 0
  for n, call in ipairs(calls()) do if call[1] == 'send-keys' and i == 0 then i = n end end
  eq(calls()[i - 1], V.PANES and vim.list_slice(V.PANES, 2))
end

T['X: No sends nothing; a working or waiting session asks again'] = function()
  local pid = idle_world()
  start()
  show_drawer()
  wait_for(function() return has_line(drawer_lines(), 'tmux 2.1') ~= nil end, 'pane label')
  drawer_cursor_to('Alpha task')
  child.lua('_G.answers = { 2 }')
  child.type_keys('X')
  eq(#confirms(), 1)
  vim.wait(100)
  eq(sent(), {})
  eq(alive(pid), true)
  -- busy there (a new process): a second confirm, No. Ready once the row shows the new state
  -- and the new pid's pane label, which the drawer learns a poll later.
  child.lua('_G.confirms = {}; _G.answers = { 1, 2 }')
  idle_world('busy')
  wait_for(function() return row_with('B Alpha task', 'tmux 2.1') end, 'busy row with its pane')
  drawer_cursor_to('Alpha task')
  child.type_keys('X')
  local c = confirms()
  eq(#c, 2)
  eq(c[1].msg, 'Close Claude "Alpha task" in tmux pane 2.1 (working)?' .. LOST)
  eq(c[2], { msg = 'It is working; close anyway?', choices = '&Close anyway\n&Cancel', default = 2 })
  vim.wait(100)
  eq(sent(), {})
  -- waiting for input, both Yes: closed
  child.lua('_G.confirms = {}; _G.answers = { 1, 1 }')
  local p2 = idle_world('waiting')
  wait_for(function() return row_with('W Alpha task') end, 'waiting row')
  drawer_cursor_to('Alpha task')
  child.type_keys('X')
  wait_for(function() return #sent() == 2 end, 'keys sent')
  eq(confirms()[2].msg, 'It is waiting for input; close anyway?')
  wait_for(function() return not alive(p2) end, 'ended')
end

T['X while the pane label is not known yet (a new pid, between polls): asks, then checks'] = function()
  idle_world()
  start()
  show_drawer()
  wait_for(function() return has_line(drawer_lines(), 'elsewhere') ~= nil or has_line(drawer_lines(), 'tmux 2.1') ~= nil end, 'row')
  -- the drawer's label cache knows nothing about this pid at the moment X is pressed
  child.lua('require("agent-ide.tmux").pane_label = function() return nil end')
  drawer_cursor_to('Alpha task')
  child.lua('_G.answers = { 1 }')
  child.type_keys('X')
  eq(confirms()[1].msg, 'Close Claude "Alpha task" in its tmux pane (idle)?' .. LOST)
  wait_for(function() return last_note() == 'Agent-IDE: closed "Alpha task"' end, 'closed')
  -- the check finds no pane: it says so (never silently nothing)
  wait_pid(idle_world())
  vim.fn.writefile({}, dir .. '/panes')
  child.lua('_G.notes = {}; _G.confirms = {}; _G.answers = { 1 }')
  child.type_keys('X')
  wait_for(function() return #notes() > 0 end, 'notice')
  eq(last_note(), 'Agent-IDE: "Alpha task": nothing sent; no tmux pane shows it')
  eq(#confirms(), 1)
end

T['X: refused when, after the confirm, the pane or the Claude is no longer fit for keys'] = function()
  start()
  show_drawer()
  -- each change runs inside the confirm (in the child): files of the fake world, `D` its folder
  local cases = {
    { 'the pane closes', [[vim.fn.writefile({}, D .. '/panes')]], 'no tmux pane shows it' },
    { 'suspended behind another program', [[local l = vim.fn.readfile(D .. '/ps_all')
      l[1] = l[1]:gsub('^(%d+ %d+ %d+) %d+', '%1 999'); vim.fn.writefile(l, D .. '/ps_all')]],
      'it is not in the foreground of its pane' },
    { 'copy mode', [[vim.fn.writefile({ (vim.fn.readfile(D .. '/panes')[1]:gsub(' 0 0 ', ' 1 0 ')) }, D .. '/panes')]],
      'its pane is in copy mode' },
    { 'synchronized', [[vim.fn.writefile({ (vim.fn.readfile(D .. '/panes')[1]:gsub(' 0 0 ', ' 0 1 ')) }, D .. '/panes')]],
      'its window synchronizes panes' },
    { 'not Claude', [[local l = vim.fn.readfile(D .. '/ps_all'); l[1] = l[1]:gsub('claude$', 'nvim')
      vim.fn.writefile(l, D .. '/ps_all')]], 'that process is not Claude' },
    { 'a :terminal inside the pane', [[local l = vim.fn.readfile(D .. '/ps_all'); l[1] = l[1]:gsub('pts/5', 'pts/44')
      vim.fn.writefile(l, D .. '/ps_all')]], 'no tmux pane shows it' },
    { 'another process now', [[local e = vim.json.decode(vim.fn.readfile(D .. '/live.json')[1])
      e[1].pid = e[1].pid + 100000; vim.fn.writefile({ vim.json.encode(e) }, D .. '/live.json')]], 'it no longer runs' },
    { 'it started working', [[local e = vim.json.decode(vim.fn.readfile(D .. '/live.json')[1])
      e[1].status = 'busy'; vim.fn.writefile({ vim.json.encode(e) }, D .. '/live.json')]], 'it started working' },
  }
  for _, c in ipairs(cases) do
    local pid = idle_world()
    vim.fn.delete(dir .. '/log')
    wait_pid(pid)
    wait_for(function() return row_with('I Alpha task', 'tmux 2.1') end, 'idle row with its pane: ' .. c[1])
    drawer_cursor_to('Alpha task')
    child.lua([[_G.notes = {}; _G.confirms = {}; _G.answers = { 1 }
      local code = ...
      _G.hook = function() _G.hook = nil; local D = vim.env.FAKE_DIR; assert(loadstring('local D = ...; ' .. code))(D) end]], { c[2] })
    child.type_keys('X')
    wait_for(function() return #notes() > 0 end, 'notice: ' .. c[1])
    eq({ c[1], last_note() }, { c[1], 'Agent-IDE: "Alpha task": nothing sent; ' .. c[3] })
    eq(sent(), {})
    eq(alive(pid), true)
  end
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

T['X: outside tmux, owned here, not running: a notice, nothing sent'] = function()
  idle_world()
  start({ in_tmux = false })
  show_drawer()
  wait_for(function() return has_line(drawer_lines(), 'elsewhere') ~= nil end, 'elsewhere row')
  drawer_cursor_to('Alpha task')
  child.type_keys('X')
  eq(last_note(), 'Agent-IDE: cannot reach that session (not in tmux); gp jumps to it')
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

local LOSTS = ' Text typed in their input boxes is lost.'

-- :AgentsCloseIdle ---------------------------------------------------------------------------

local function three()
  local pa, pb, pc = claude_proc(), claude_proc(), claude_proc()
  world({
    { id = A, status = 'idle', pid = pa, pane = '%5', label = '2.1', tty = 'pts/5', victim = true },
    { id = B, status = 'idle', pid = pb, pane = '%6', label = '2.2', tty = 'pts/6', victim = true },
    { id = C, status = 'busy', pid = pc, pane = '%7', label = '3.0', tty = 'pts/7', victim = true },
  })
  return pa, pb, pc
end

T[':AgentsCloseIdle: one confirm first (count when known), Ctrl-C twice into each idle pane; a predicate limits it'] = function()
  local pa, pb, pc = three()
  start()
  child.lua('_G.answers = { 1 }')
  child.cmd('AgentsCloseIdle')
  -- no current live map (nothing polls): asked without a number, at once
  eq(confirms(), { { msg = 'Close the idle Claude sessions in tmux panes?' .. LOSTS, choices = '&Close\n&Cancel', default = 2 } })
  wait_for(function() return last_note():find('closed', 1, true) ~= nil end, 'summary')
  eq(last_note(), 'Agent-IDE: closed 2 of 2')
  local keys = vim.tbl_map(function(c) return table.concat(c, ' ') end, sent())
  table.sort(keys)
  eq(keys, { 'send-keys -t %5 C-c', 'send-keys -t %5 C-c', 'send-keys -t %6 C-c', 'send-keys -t %6 C-c' })
  eq({ alive(pa), alive(pb), alive(pc) }, { false, false, true })
  -- with the drawer polling, the count; a predicate: only B; No sends nothing
  vim.fn.delete(dir .. '/log')
  pa, pb = claude_proc(), claude_proc()
  world({
    { id = A, status = 'idle', pid = pa, pane = '%5', label = '2.1', tty = 'pts/5', victim = true },
    { id = B, status = 'idle', pid = pb, pane = '%6', label = '2.2', tty = 'pts/6', victim = true },
  })
  vim.fn.delete(dir .. '/sent-%5')
  vim.fn.delete(dir .. '/sent-%6')
  show_drawer()
  wait_for(function() return row_with('I Alpha task', 'tmux 2.1') and row_with('I Beta task', 'tmux 2.2') end, 'rows')
  child.lua('_G.confirms = {}; _G.answers = { 2 }')
  child.cmd('AgentsCloseIdle')
  eq(confirms()[1].msg, 'Close 2 idle Claude session(s) in tmux panes?' .. LOSTS)
  vim.wait(100)
  eq(sent(), {})
  child.lua('_G.confirms = {}; _G.answers = { 1 }')
  child.lua('local only = ...; require("agent-ide.ui.tmux_close").close_idle(function(id) return id == only end)', { B })
  eq(confirms()[1].msg, 'Close 1 idle Claude session(s) in tmux panes?' .. LOSTS)
  wait_for(function() return last_note() == 'Agent-IDE: closed 1 of 1' end, 'summary 2')
  eq(sent(), { { 'send-keys', '-t', '%6', 'C-c' }, { 'send-keys', '-t', '%6', 'C-c' } })
  eq({ alive(pa), alive(pb) }, { true, false })
end

T[':AgentsCloseIdle: a session that started working after the confirm, or failed checks, is skipped and counted'] = function()
  local pa, pb = claude_proc(), claude_proc()
  world({
    { id = A, status = 'idle', pid = pa, pane = '%5', label = '2.1', tty = 'pts/5', victim = true },
    { id = B, status = 'idle', pid = pb, pane = '%6', label = '2.2', tty = 'pts/6', victim = true },
    { id = C, status = 'idle', pid = claude_proc(), pane = '%7', label = '3.0', tty = 'pts/7', victim = true, fg = false },
  })
  start()
  show_drawer()
  wait_for(function() return row_with('I Gamma task', 'tmux 3.0') end, 'rows')
  -- A starts working while the confirm is open
  child.lua([[local id = ...; _G.answers = { 1 }; _G.hook = function()
    _G.hook = nil
    local f = vim.env.FAKE_DIR .. '/live.json'
    local e = vim.json.decode(vim.fn.readfile(f)[1])
    for _, x in ipairs(e) do if x.sessionId == id then x.status = 'busy' end end
    vim.fn.writefile({ vim.json.encode(e) }, f)
  end]], { A })
  child.cmd('AgentsCloseIdle')
  eq(confirms()[1].msg, 'Close 3 idle Claude session(s) in tmux panes?' .. LOSTS)
  wait_for(function() return last_note():find('closed', 1, true) ~= nil end, 'summary')
  eq(last_note(), 'Agent-IDE: closed 1 of 3; 1 skipped (it is not in the foreground of its pane); 1 skipped (no longer idle)')
  eq(sent(), { { 'send-keys', '-t', '%6', 'C-c' }, { 'send-keys', '-t', '%6', 'C-c' } })
  eq({ alive(pa), alive(pb) }, { true, false })
end

T[':AgentsCloseIdle in project scope: only that project\'s idle sessions, said in the confirm; ! means all'] = function()
  local pa, pb = claude_proc(), claude_proc()
  world({
    { id = A, status = 'idle', pid = pa, pane = '%5', label = '2.1', tty = 'pts/5', victim = true },
    { id = B, status = 'idle', pid = pb, pane = '%6', label = '2.2', tty = 'pts/6', victim = true, cwd = '/x/other' },
  })
  start()
  child.lua('require("agent-ide.scope").set("project", { key = "/x/repo", name = "repo" })')
  child.lua('_G.answers = { 1 }')
  child.cmd('AgentsCloseIdle')
  eq(confirms()[1].msg, 'Close the idle Claude sessions of repo in tmux panes?' .. LOSTS)
  wait_for(function() return last_note():find('closed', 1, true) ~= nil end, 'summary')
  eq(last_note(), 'Agent-IDE: closed 1 of 1')
  eq(sent(), { { 'send-keys', '-t', '%5', 'C-c' }, { 'send-keys', '-t', '%5', 'C-c' } })
  eq({ alive(pa), alive(pb) }, { false, true })
  -- nothing idle left in the project: the notice names it
  world({ { id = B, status = 'idle', pid = pb, pane = '%6', label = '2.2', tty = 'pts/6', victim = true, cwd = '/x/other' } })
  vim.wait(300) -- the map of the last query is no longer current
  child.lua('_G.notes = {}; _G.confirms = {}; _G.answers = { 1 }')
  child.cmd('AgentsCloseIdle')
  wait_for(function() return #notes() > 0 end, 'notice')
  eq(last_note(), 'Agent-IDE: no idle Claude sessions of repo in tmux panes')
  -- the bang: every project
  child.lua('_G.notes = {}; _G.confirms = {}; _G.answers = { 1 }')
  child.cmd('AgentsCloseIdle!')
  eq(confirms()[1].msg, 'Close 1 idle Claude session(s) in tmux panes?' .. LOSTS)
  wait_for(function() return last_note():find('closed', 1, true) ~= nil end, 'summary 2')
  eq(alive(pb), false)
end

T[':AgentsCloseIdle: outside tmux, or nothing idle known: a notice, no confirm'] = function()
  idle_world('busy')
  start({ in_tmux = false })
  child.cmd('AgentsCloseIdle')
  eq(last_note(), 'Agent-IDE: not in tmux; nothing to close')
  start()
  show_drawer()
  wait_for(function() return row_with('B Alpha task') end, 'busy row')
  child.cmd('AgentsCloseIdle')
  eq(last_note(), 'Agent-IDE: no idle Claude sessions in tmux panes')
  eq(confirms(), {})
  eq(sent(), {})
end

return T
