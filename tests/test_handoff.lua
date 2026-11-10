-- Hand-off to native Claude in a tmux pane (<leader>at): each case drives a child Neovim with the
-- fake Claude and a fake `tmux` on PATH that records its arguments. Its `wait-for <channel>`
-- writes its pid to `waiter.pid` and returns once a `release` file appears (`wait-for -S`
-- creates it); `split-window -P` prints pane `%9` and adds it to `panes`, which `list-panes`
-- prints.
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local FIXTURE_ID = '11111111-1111-4111-8111-111111111111'
local FIXTURE = vim.fn.getcwd() .. '/tests/fixtures/projects/-home-u-git-alpha/' .. FIXTURE_ID .. '.jsonl'
local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local AWAY = 'in native Claude (tmux pane)'

local tmp, repo, projects, log, tmux_dir, transcript_file

local FAKE_TMUX = [[#!/bin/sh
for a in "$@"; do printf '%s\037' "$a"; done >> "$FAKE_TMUX_DIR/log"
printf '\n' >> "$FAKE_TMUX_DIR/log"
if [ "$1" = "wait-for" ] && [ "$2" = "-S" ]; then touch "$FAKE_TMUX_DIR/release"; exit 0; fi
if [ "$1" = "wait-for" ]; then
  echo $$ > "$FAKE_TMUX_DIR/waiter.pid"
  n=0
  while [ ! -e "$FAKE_TMUX_DIR/release" ] && [ $n -lt 400 ]; do sleep 0.05; n=$((n+1)); done
  exit 0
fi
if [ "$1" = "split-window" ]; then
  [ "${FAKE_TMUX_SPLIT_CODE:-0}" = 0 ] || exit "$FAKE_TMUX_SPLIT_CODE"
  echo '%9' >> "$FAKE_TMUX_DIR/panes"; echo '%9'; exit 0
fi
if [ "$1" = "list-panes" ]; then cat "$FAKE_TMUX_DIR/panes"; exit 0; fi
exit 0
]]

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    repo = tmp .. '/repo'
    projects = tmp .. '/projects'
    tmux_dir = tmp .. '/tmux'
    vim.fn.mkdir(repo, 'p')
    vim.fn.mkdir(tmux_dir .. '/bin', 'p')
    vim.fn.system({ 'git', 'init', '-q', repo })
    vim.fn.writefile(vim.split(FAKE_TMUX, '\n'), tmux_dir .. '/bin/tmux')
    vim.fn.writefile({ '%1' }, tmux_dir .. '/panes')
    vim.fn.setfperm(tmux_dir .. '/bin/tmux', 'rwxr-xr-x')
    local dir = projects .. '/-repo'
    vim.fn.mkdir(dir, 'p')
    local lines = {}
    for i, l in ipairs(vim.fn.readfile(FIXTURE)) do lines[i] = l:gsub('/home/u/git/alpha', repo) end
    transcript_file = dir .. '/' .. FIXTURE_ID .. '.jsonl'
    vim.fn.writefile(lines, transcript_file)
  end,
  post_case = function()
    vim.fn.writefile({}, tmux_dir .. '/release') -- no fake waiter outlives the case
    child.stop()
    vim.uv.os_unsetenv('FAKE_CLAUDE_LOG')
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

local function init()
  return { emit = { type = 'system', subtype = 'init', session_id = 'x', model = 'claude-haiku-5-5-20261001',
    permissionMode = 'default', slash_commands = {}, claude_code_version = '2.1.306' } }
end
local function say(t)
  return { emit = { type = 'assistant', message = { id = 'm', type = 'message', role = 'assistant',
    content = { { type = 'text', text = t } } } } }
end
local function result(t) return { emit = { type = 'result', subtype = 'success', is_error = false, result = t } } end

local function start(steps, opts)
  opts = opts or {}
  local cmd
  cmd, log = fake.cmd(steps or {})
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local log, tmux_dir, in_tmux, split_code, setup, poll_ms = ...
    require('agent-ide.ui.handoff')._poll_ms = poll_ms
    vim.uv.os_setenv('FAKE_CLAUDE_LOG', log)
    vim.env.FAKE_TMUX_DIR = tmux_dir
    vim.env.FAKE_TMUX_SPLIT_CODE = split_code
    vim.env.PATH = tmux_dir .. '/bin:' .. vim.env.PATH
    vim.env.TMUX = in_tmux and '/tmp/fake-tmux,1,0' or nil
    _G.notes = {}
    vim.notify = function(msg, level) table.insert(_G.notes, { msg = msg, level = level }) end
    require('agent-ide').setup(setup)
  ]], { log, tmux_dir, opts.in_tmux ~= false, tostring(opts.split_code or 0), {
    projects_dir = projects,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = opts.live_cmd or { 'echo', '[]' } },
    icons_style = 'plain', icons = ICONS,
    claude = { cmd = cmd },
  }, opts.poll_ms or 60000 })
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

local function expand()
  child.lua('require("agent-ide").toggle()')
  wait_for(function() return has_line(drawer_lines(), ' P repo  ') ~= nil end, 'project row')
  if has_line(drawer_lines(), '> P repo  ') then
    drawer_cursor_to('> P repo  ')
    child.type_keys('<CR>')
  end
end

local function transcript()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript), 0, -1, false)')
end
local function winbar() return child.lua_get('vim.wo[require("agent-ide.ui.chat")._windows().transcript].winbar') end
local function current()
  return child.lua_get('(function() local s = require("agent-ide.ui.chat").current(); return s and { id = s.id, state = s.state, owned = s.owned } end)()')
end
local function notes() return child.lua_get('vim.tbl_map(function(n) return n.msg end, _G.notes)') end

local function open_fixture()
  expand()
  drawer_cursor_to('Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() return has_line(transcript(), '## You') ~= nil end, 'history loaded')
end

-- Each tmux call: its argument list.
local function tmux_calls()
  local f = tmux_dir .. '/log'
  if vim.fn.filereadable(f) == 0 then return {} end
  local out = {}
  for _, l in ipairs(vim.fn.readfile(f)) do
    if l ~= '' then out[#out + 1] = vim.split(l:gsub('\031$', ''), '\031', { plain = true }) end
  end
  return out
end

local function append_native_turn()
  local function rec(t)
    t.cwd = repo
    return vim.json.encode(t)
  end
  vim.fn.writefile({
    rec({ type = 'user', uuid = 'n1', message = { role = 'user', content = 'From native' } }),
    rec({ type = 'assistant', uuid = 'n2', message = { role = 'assistant', content = { { type = 'text', text = 'Native answer' } } } }),
  }, transcript_file, 'a')
end

-- Tests -------------------------------------------------------------------------------------

T['in tmux: parks, opens a pane with claude --resume, refuses sends, reloads when it exits'] = function()
  start()
  open_fixture()
  child.type_keys('\\at')
  wait_for(function() return #tmux_calls() == 2 end, 'tmux calls')
  local calls = tmux_calls()
  local chan = calls[1][2]
  -- listening before the pane can signal, on a channel of this hand-off only
  eq(calls[1][1], 'wait-for')
  eq(chan:match('^agent%-ide%-' .. FIXTURE_ID:gsub('%-', '%%-') .. '%-1%-%d+$') ~= nil, true)
  eq(vim.list_slice(calls[2], 1, 7), { 'split-window', '-h', '-P', '-F', '#{pane_id}', '-c', repo })
  -- `sh -c` with a script without single quotes (any default-shell passes it on unchanged) that
  -- signals the channel on every exit, also when the pane is killed
  local cmd = calls[2][8]
  local script = cmd:match("^sh %-c '(.*)'$")
  eq(script ~= nil and not script:find("'", 1, true), true)
  eq(vim.startswith(script, 'trap "tmux wait-for -S ' .. chan .. '" EXIT; trap "exit 129" HUP TERM INT; env -u ANTHROPIC_API_KEY "'), true)
  eq(vim.endswith(script, '"--resume" "' .. FIXTURE_ID .. '"'), true)
  wait_for(function() return winbar():find(AWAY, 1, true) ~= nil end, 'winbar away')
  -- sending is refused while native Claude has the session
  child.type_keys('i', 'hello', '<Esc>', '\\<CR>')
  wait_for(function() return has_line(notes(), 'open in native Claude') ~= nil end, 'refusal notice')
  eq(fake.log(log), {})
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), { 'hello' })
  -- native Claude answers and exits
  append_native_turn()
  vim.fn.writefile({}, tmux_dir .. '/release')
  wait_for(function() return has_line(transcript(), 'Native answer') ~= nil end, 'reloaded transcript')
  eq(winbar():find(AWAY, 1, true), nil)
  eq(transcript(), child.lua_get('require("agent-ide.transcript.render").render(require("agent-ide.ui.chat").current().events).lines'))
  eq(child.lua_get('vim.api.nvim_get_mode().mode'), 'n')
end

T['native Claude ends while the user reads another session: a notice, no focus or chat change'] = function()
  start()
  open_fixture()
  child.type_keys('\\at')
  wait_for(function() return #tmux_calls() == 2 end, 'tmux calls')
  child.lua('vim.cmd("tabnew"); _G.work = { tab = vim.api.nvim_get_current_tabpage(), win = vim.api.nvim_get_current_win() }')
  vim.fn.writefile({}, tmux_dir .. '/release')
  wait_for(function() return has_line(notes(), 'Agent-IDE: Alpha basics is back from native Claude') ~= nil end, 'notice')
  eq(child.lua_get('vim.api.nvim_get_current_tabpage() == _G.work.tab and vim.api.nvim_get_current_win() == _G.work.win'), true)
end

T['a running session is parked (its process stopped) before the pane opens'] = function()
  start({ { expect = 'Hi' }, init(), say('Hello.'), result('Hello.') })
  open_fixture()
  child.type_keys('i', 'Hi', '<Esc>', '\\<CR>')
  wait_for(function() return has_line(transcript(), 'Hello.') ~= nil and current().state == 'idle' end, 'turn end')
  eq(current().owned, true)
  child.type_keys('\\at')
  wait_for(function() return #tmux_calls() == 2 end, 'tmux calls')
  eq(current().owned, false)
  eq(current().state, 'parked')
end

T['a working session asks first; declining hands nothing over'] = function()
  start({ { expect = 'Hi' }, init(), { sleep_ms = 3000 }, result('x') })
  child.lua('vim.fn.confirm = function() _G.confirmed = (_G.confirmed or 0) + 1; return 2 end')
  open_fixture()
  child.type_keys('i', 'Hi', '<Esc>', '\\<CR>')
  wait_for(function() return current().state == 'busy' end, 'busy')
  child.type_keys('\\at')
  wait_for(function() return child.lua_get('_G.confirmed') == 1 end, 'confirm')
  vim.wait(200)
  eq(tmux_calls(), {})
  eq(current().state, 'busy')
  eq(winbar():find(AWAY, 1, true), nil)
end

T['outside tmux: parks and tells the command to run by hand'] = function()
  start(nil, { in_tmux = false })
  open_fixture()
  child.type_keys('\\at')
  local want = "claude --resume " .. FIXTURE_ID
  wait_for(function() return has_line(notes(), want) ~= nil end, 'notice')
  eq(notes()[has_line(notes(), want)], "Agent-IDE: parked; not in tmux, so continue it by hand: cd '" .. repo
    .. "' && claude --resume " .. FIXTURE_ID)
  eq(tmux_calls(), {})
  eq(winbar():find(AWAY, 1, true), nil)
end

local function waiter_dead()
  local f = tmux_dir .. '/waiter.pid'
  if vim.fn.filereadable(f) == 0 then return false end
  return not vim.uv.kill(tonumber(vim.fn.readfile(f)[1]), 0)
end

T['a pane that cannot open: warning, the waiter is stopped, the session is back'] = function()
  start(nil, { split_code = 1 })
  open_fixture()
  child.type_keys('\\at')
  wait_for(function() return has_line(notes(), 'cannot open a tmux pane') ~= nil end, 'warning')
  wait_for(function() return winbar():find(AWAY, 1, true) == nil end, 'back')
  wait_for(waiter_dead, 'waiter stopped')
end

T['the pane dies without a signal: found by polling, the session is back'] = function()
  start(nil, { poll_ms = 100 })
  open_fixture()
  child.type_keys('\\at')
  wait_for(function() return winbar():find(AWAY, 1, true) ~= nil end, 'away')
  vim.wait(300)
  eq(winbar():find(AWAY, 1, true) ~= nil, true) -- pane %9 still listed
  vim.fn.writefile({ '%1' }, tmux_dir .. '/panes') -- killed: gone, and no release
  wait_for(function() return winbar():find(AWAY, 1, true) == nil end, 'back', 3000)
  wait_for(waiter_dead, 'waiter stopped')
  eq(vim.fn.filereadable(tmux_dir .. '/release'), 0)
end

T['<leader>at while away offers to take the session back; refused while native Claude runs it'] = function()
  local live_file = tmp .. '/live.json'
  vim.fn.writefile({ vim.json.encode({ { sessionId = FIXTURE_ID, pid = 4242, status = 'idle', cwd = '/x' } }) }, live_file)
  start(nil, { live_cmd = { 'cat', live_file } })
  child.lua('_G.asked = 0; vim.fn.confirm = function() _G.asked = _G.asked + 1; return 1 end')
  open_fixture()
  child.type_keys('\\at')
  wait_for(function() return winbar():find(AWAY, 1, true) ~= nil end, 'away')
  child.type_keys('\\at')
  wait_for(function() return has_line(notes(), 'native Claude still runs this session; quit it there first') ~= nil end, 'refusal')
  eq(winbar():find(AWAY, 1, true) ~= nil, true)
  vim.fn.writefile({ '[]' }, live_file)
  child.type_keys('\\at')
  wait_for(function() return winbar():find(AWAY, 1, true) == nil end, 'taken back')
  eq(child.lua_get('_G.asked'), 2)
  wait_for(waiter_dead, 'waiter stopped')
  -- the next hand-off waits on a new channel
  child.type_keys('\\at')
  wait_for(function() return #vim.tbl_filter(function(c) return c[1] == 'wait-for' end, tmux_calls()) == 2 end, 'second waiter')
  local waits = vim.tbl_filter(function(c) return c[1] == 'wait-for' end, tmux_calls())
  eq(waits[1][2] ~= waits[2][2], true)
end

T['quitting Neovim stops the waiter'] = function()
  start()
  open_fixture()
  child.type_keys('\\at')
  wait_for(function() return vim.fn.filereadable(tmux_dir .. '/waiter.pid') == 1 end, 'waiter')
  child.stop()
  wait_for(waiter_dead, 'waiter stopped', 3000)
end

T['a session without a folder cannot be handed off'] = function()
  start()
  child.lua([[require('agent-ide.ui.handoff').start(require('agent-ide.session').open({ cwd = '' }),
    { away = function() end, back = function() end })]])
  wait_for(function() return has_line(notes(), 'cannot continue in native Claude: the session has no folder') ~= nil end, 'notice')
  eq(tmux_calls(), {})
end

T['help lists the hand-off key'] = function()
  start()
  open_fixture()
  child.lua('_G.help_rows = nil; require("agent-ide.ui.help").open = function(_, rows) _G.help_rows = rows end')
  child.type_keys('?')
  local rows = child.lua_get('_G.help_rows')
  local found
  for _, r in ipairs(rows) do
    if r.key == '<leader>at' then found = r.desc end
  end
  eq(found, 'continue in native Claude in a tmux pane (parks here; reloads when it exits)')
  eq(child.lua_get('vim.fn.maparg("<leader>at", "n") ~= ""'), true)
end

return T
