-- Keepers (lua/agent-ide/keeper): a Claude the plugin started outlives the Neovim that started
-- it; a new Neovim reattaches, with the transcript, state, open asks and queue as they were.
-- Child Neovims with the fake Claude; the keeper is the real one (a detached headless Neovim).
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()
local kstate = require('agent-ide.keeper.state')

local FIXTURE_ID = '11111111-1111-4111-8111-111111111111'
local FIXTURE = vim.fn.getcwd() .. '/tests/fixtures/projects/-home-u-git-alpha/' .. FIXTURE_ID .. '.jsonl'
local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }

local tmp, repo, projects, log, fixture_path

local function run_dir() return require('agent-ide.util.rundir').dir() end
local function kill_keepers()
  for _, f in ipairs(vim.fn.glob(run_dir() .. '/keeper-*.json', false, true)) do
    local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(f), '\n'))
    if ok and type(data) == 'table' then
      if type(data.keeper_pid) == 'number' then pcall(vim.uv.kill, data.keeper_pid, 15) end
      if type(data.claude_pid) == 'number' then pcall(vim.uv.kill, data.claude_pid, 15) end
    end
    vim.fn.delete(f)
  end
  for _, f in ipairs(vim.fn.glob(run_dir() .. '/keeper-*.sock', false, true)) do vim.fn.delete(f) end
end

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    kill_keepers()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    repo = tmp .. '/repo'
    projects = tmp .. '/projects'
    vim.fn.mkdir(repo, 'p')
    vim.fn.system({ 'git', 'init', '-q', repo })
    local dir = projects .. '/-repo'
    vim.fn.mkdir(dir, 'p')
    local lines = {}
    for i, l in ipairs(vim.fn.readfile(FIXTURE)) do lines[i] = l:gsub('/home/u/git/alpha', repo) end
    fixture_path = dir .. '/' .. FIXTURE_ID .. '.jsonl'
    vim.fn.writefile(lines, fixture_path)
  end,
  post_case = function()
    child.stop()
    kill_keepers()
    require('agent-ide.keeper')._reset()
    vim.uv.os_unsetenv('FAKE_CLAUDE_LOG')
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

-- Pure: the state machine ----------------------------------------------------------------

T['state: busy after a prompt, waiting while a permission is open, idle after a result'] = function()
  local st = kstate.new()
  eq(st.state, 'idle')
  eq(kstate.step(st, 'in', '{"type":"user","message":{"role":"user","content":"hi"}}'), true)
  eq(st.state, 'busy')
  eq(kstate.step(st, 'out', '{"type":"assistant","message":{}}'), false)
  eq(kstate.step(st, 'out', '{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool"}}'), true)
  eq(st.state, 'waiting')
  eq(kstate.step(st, 'out', '{"type":"control_request","request_id":"p2","request":{"subtype":"can_use_tool"}}'), false)
  eq(kstate.step(st, 'in', '{"type":"control_response","response":{"request_id":"p1","subtype":"success"}}'), false)
  eq(st.state, 'waiting')
  eq(kstate.step(st, 'in', '{"type":"control_response","response":{"request_id":"p2","subtype":"success"}}'), true)
  eq(st.state, 'busy')
  eq(kstate.step(st, 'out', '{"type":"result","subtype":"success"}'), true)
  eq(st.state, 'idle')
  eq(kstate.ends_turn('{"type":"result"}'), true)
  eq(kstate.ends_turn('not json'), false)
  eq(kstate.step(st, 'out', 'garbage'), false)
  -- a control request of another kind (the plugin's own answers echoing) does not wait
  eq(kstate.step(st, 'out', '{"type":"control_request","request_id":"x","request":{"subtype":"hook_callback"}}'), false)
end

-- Child helpers -----------------------------------------------------------------------------

local function init()
  return { emit = { type = 'system', subtype = 'init', session_id = 'x', model = 'claude-haiku-5-5-20261001',
    permissionMode = 'default', slash_commands = {}, claude_code_version = '2.1.306' } }
end
local function say(t)
  return { emit = { type = 'assistant', message = { id = 'm', type = 'message', role = 'assistant',
    content = { { type = 'text', text = t } } } } }
end
local function result(t) return { emit = { type = 'result', subtype = 'success', is_error = false, result = t } } end
local function ask(rid, name)
  return { emit = { type = 'control_request', request_id = rid, request = { subtype = 'can_use_tool', tool_name = name,
    display_name = name, input = { command = 'ls' }, tool_use_id = 't' } } }
end

local function start(cmd, opts)
  opts = opts or {}
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local log, opts = ...
    vim.env.TMUX = nil
    vim.uv.os_setenv('FAKE_CLAUDE_LOG', log)
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    require('agent-ide').setup(opts)
  ]], { log, {
    projects_dir = projects, helper = { enabled = false },
    live = { interval_ms = 100, cmd = { 'echo', '[]' } }, icons_style = 'plain', icons = ICONS, claude = { cmd = cmd },
    keeper = opts.keeper, sound = { waiting = false },
  } })
end

local function wait_for(cond, what, ms)
  local ok = vim.wait(ms or 8000, cond, 20)
  if not ok then error('timed out waiting for ' .. what, 2) end
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
  child.lua('local d = require("agent-ide.ui.drawer"); if not d.state().win then require("agent-ide").toggle() end')
  if has_line(drawer_lines(), '> repo') then
    drawer_cursor_to('> repo')
    child.type_keys('<CR>')
  end
end

local function current()
  return child.lua_get([[(function()
    local s = require('agent-ide.ui.chat').current()
    return s and { id = s.id, state = s.state, queue = #s.queue, events = #s.events, alive = s:_alive(), pid = s.pid or false,
      pending = #s.pending_permissions, streaming = s.streaming, keeper = s.proc ~= nil and s.proc.keeper == true }
  end)()]])
end

local function open_fixture()
  expand()
  drawer_cursor_to('Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() local c = current(); return c ~= vim.NIL and c.id == FIXTURE_ID end, 'fixture open')
end

local function transcript()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript), 0, -1, false)')
end

local function send(text)
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().prompt)')
  child.type_keys('i', text, '<Esc>', '\\<CR>')
end

local function keeper_json(id)
  local f = run_dir() .. '/keeper-' .. id .. '.json'
  if vim.fn.filereadable(f) == 0 then return nil end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(f), '\n'))
  return ok and data or nil
end

local function alive(pid) return type(pid) == 'number' and vim.uv.kill(pid, 0) == 0 end

local function quit_child()
  pcall(child.cmd, 'qall!')
  wait_for(function() return not pcall(child.lua_get, '1') end, 'Neovim to exit', 5000)
end

local function fake_ins()
  local out = {}
  for _, l in ipairs(fake.log(log)) do
    if l['in'] and not fake.is_init(l['in']) then out[#out + 1] = vim.json.decode(l['in']) end
  end
  return out
end

-- Tests -------------------------------------------------------------------------------------

T['quitting keeps Claude running under a keeper; a new Neovim reattaches with the replay, then live'] = function()
  local cmd
  cmd, log = fake.cmd({ { expect = 'Hi' }, init(), say('Hello.'), { sleep_ms = 3000 }, result('Hello.'),
    { expect = 'Next' }, say('Again.'), result('Again.') })
  start(cmd)
  open_fixture()
  send('Hi')
  wait_for(function() local c = current(); return c.state == 'busy' and c.keeper and c.pid end, 'busy under a keeper')
  wait_for(function() return has_line(transcript(), 'Hello.') ~= nil end, 'streamed answer')
  local k = keeper_json(FIXTURE_ID)
  eq(k ~= nil, true)
  eq({ k.session_id, k.cwd, k.path, k.state, k.attached, k.version }, { FIXTURE_ID, repo, fixture_path, 'busy', true, 1 })
  eq(k.offset, vim.uv.fs_stat(fixture_path).size)
  eq(alive(k.keeper_pid) and alive(k.claude_pid), true)
  eq(bit.band(vim.uv.fs_stat(run_dir() .. '/keeper-' .. FIXTURE_ID .. '.sock').mode, 511), 384)
  -- a second prompt queued here, then the quit: no question, the queue goes to the keeper
  send('Next')
  wait_for(function() return current().queue == 1 end, 'queued')
  quit_child()
  eq(alive(k.claude_pid), true)
  wait_for(function() local j = keeper_json(FIXTURE_ID); return j ~= nil and j.attached == false and j.queued == 1 end, 'detached with the queue')
  -- the keeper sends the queued prompt when the turn ends with nobody attached
  wait_for(function() return #fake_ins() >= 2 end, 'keeper sent Next')
  eq(fake_ins()[2].message.content, 'Next')
  -- a new Neovim: the drawer shows the session as held in the background; opening it attaches
  start(cmd)
  expand()
  wait_for(function() return has_line(drawer_lines(), 'background') ~= nil end, 'background row')
  open_fixture()
  wait_for(function() local c = current(); return c.keeper and c.alive and c.events >= 6 end, 'attached with the replay')
  local lines = transcript()
  -- the fixture's own history first, then both turns from the replay
  eq(has_line(lines, 'Please add a greeting to main.') < has_line(lines, 'Hi'), true)
  eq(has_line(lines, 'Hi') < has_line(lines, 'Hello.'), true)
  eq(has_line(lines, 'Hello.') < has_line(lines, 'Next'), true)
  eq(has_line(lines, 'Next') < has_line(lines, 'Again.'), true)
  wait_for(function() return current().state == 'idle' end, 'idle after the replayed results')
  eq(current().queue, 0)
  -- the same keeper, the same Claude: nothing was started again
  eq(#vim.tbl_filter(function(l) return l.argv ~= nil end, fake.log(log)), 1)
  eq(keeper_json(FIXTURE_ID).claude_pid, k.claude_pid)
  -- the chat works on: a parked session resumes with a new process once this one is stopped
  child.type_keys('\\ax')
  wait_for(function() return current().state == 'parked' and not current().alive end, 'parked')
  wait_for(function() return keeper_json(FIXTURE_ID) == nil end, 'keeper file gone')
  wait_for(function() return not alive(k.claude_pid) end, 'Claude gone')
end

T['a permission asked while no Neovim was attached shows on reattach and is answered there'] = function()
  local cmd
  cmd, log = fake.cmd({ { expect = 'Hi' }, init(), { sleep_ms = 1500 }, ask('p1', 'Bash'), { expect = '"behavior":"allow"' },
    say('Ran it.'), result('Ran it.') })
  start(cmd)
  open_fixture()
  send('Hi')
  wait_for(function() return current().state == 'busy' end, 'busy')
  quit_child()
  wait_for(function() local j = keeper_json(FIXTURE_ID); return j ~= nil and j.state == 'waiting' end, 'waiting in the keeper')
  start(cmd)
  expand()
  wait_for(function() return has_line(drawer_lines(), 'input') ~= nil end, 'input row')
  open_fixture()
  wait_for(function() local c = current(); return c.keeper and c.state == 'waiting' and c.pending == 1 end, 'ask on reattach')
  eq(child.lua_get('require("agent-ide.ui.chat").current().pending_permissions[1].tool_name'), 'Bash')
  child.lua('local s = require("agent-ide.ui.chat").current(); s:answer("p1", true)')
  wait_for(function() return current().state == 'idle' and has_line(transcript(), 'Ran it.') ~= nil end, 'answered and done')
end

T['keeper = { enabled = false }: Claude is a child of Neovim and ends with it; the quit guard asks'] = function()
  local cmd
  cmd, log = fake.cmd({ { expect = 'Hi' }, init(), { sleep_ms = 5000 }, result('late') })
  start(cmd, { keeper = { enabled = false } })
  open_fixture()
  send('Hi')
  wait_for(function() local c = current(); return c.state == 'busy' and c.pid end, 'busy')
  local c = current()
  eq(c.keeper, false)
  eq(keeper_json(FIXTURE_ID), nil)
  eq(child.lua_get('require("agent-ide.ui.quit_guard").working()'), 1)
  quit_child()
  wait_for(function() return not alive(c.pid) end, 'Claude ended with Neovim')
end

T['with a keeper the quit guard has nothing to ask; a second Neovim is refused; stale files go'] = function()
  local cmd
  cmd, log = fake.cmd({ { expect = 'Hi' }, init(), { sleep_ms = 4000 }, result('late') })
  start(cmd)
  open_fixture()
  send('Hi')
  wait_for(function() local c = current(); return c.state == 'busy' and c.keeper and c.pid end, 'attached (pid known)')
  eq(child.lua_get('require("agent-ide.ui.quit_guard").working()'), 0)
  -- this process plays the second Neovim: refused
  local busy = false
  require('agent-ide.keeper').attach(FIXTURE_ID, { on_busy = function() busy = true end })
  wait_for(function() return busy end, 'busy answer')
  -- a stale file of a keeper that is gone is removed on refresh
  local stale = run_dir() .. '/keeper-stale-id.json'
  vim.fn.writefile({ vim.json.encode({ version = 1, session_id = 'stale-id', keeper_pid = 999999999, state = 'busy' }) }, stale)
  local done = false
  require('agent-ide.keeper').refresh(function(all)
    done = true
    eq(all['stale-id'], nil)
    eq(all[FIXTURE_ID] ~= nil, true)
  end)
  wait_for(function() return done end, 'refresh')
  eq(vim.fn.filereadable(stale), 0)
end

T['an idle Claude with no Neovim attached is closed after the idle time'] = function()
  local cmd
  cmd, log = fake.cmd({ { expect = 'Hi' }, init(), result('ok') })
  start(cmd, { keeper = { idle_minutes = 0.03 } }) -- about 2 s
  open_fixture()
  send('Hi')
  wait_for(function() local c = current(); return c.state == 'idle' and c.keeper and c.alive end, 'idle under a keeper')
  local k = keeper_json(FIXTURE_ID)
  quit_child()
  eq(alive(k.claude_pid), true)
  wait_for(function() return not alive(k.claude_pid) end, 'closed after the idle time', 8000)
  wait_for(function() return keeper_json(FIXTURE_ID) == nil end, 'keeper file gone')
end

return T
