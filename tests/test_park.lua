-- Parking a session (<leader>ax in the chat, x on a drawer row): each case drives a child Neovim
-- with the fake Claude.
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local FIXTURE_ID = '11111111-1111-4111-8111-111111111111'
local FIXTURE = vim.fn.getcwd() .. '/tests/fixtures/projects/-home-u-git-alpha/' .. FIXTURE_ID .. '.jsonl'
local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }

local tmp, repo, projects, log

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
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
    vim.fn.writefile(lines, dir .. '/' .. FIXTURE_ID .. '.jsonl')
  end,
  post_case = function()
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
local function turn(p, a) return { { expect = p }, init(), say(a), result(a) } end
local function flat(...)
  local out = {}
  for _, part in ipairs({ ... }) do vim.list_extend(out, part) end
  return out
end

local function start(steps, live_json)
  local cmd
  cmd, log = fake.cmd(steps or {})
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local log, setup = ...
    vim.env.TMUX = nil
    vim.uv.os_setenv('FAKE_CLAUDE_LOG', log)
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    require('agent-ide').setup(setup)
  ]], { log, {
    projects_dir = projects,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', live_json or '[]' } },
    icons_style = 'plain', icons = ICONS,
    claude = { cmd = cmd },
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

local function transcript()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript), 0, -1, false)')
end
-- The transcript's winbar as text: highlight groups dropped, the right-align gap `%=` as two
-- spaces, `%%` as `%`.
local function winbar()
  local bar = child.lua_get('vim.wo[require("agent-ide.ui.chat")._windows().transcript].winbar')
  return (bar:gsub('%%#[^#]*#', ''):gsub('%%%*', ''):gsub('%%=', '  '):gsub('%%%%', '%%'))
end
local function sess()
  return child.lua_get('(function(id) local s = require("agent-ide.session").get(id); return { state = s.state, owned = s.owned, queue = #s.queue } end)(...)', { FIXTURE_ID })
end
local function notes() return child.lua_get('_G.notes') end
local function prompt_lines()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().prompt), 0, -1, false)')
end
local function argvs()
  local out = {}
  for _, l in ipairs(fake.log(log)) do
    if l.argv then out[#out + 1] = l.argv end
  end
  return out
end

local function open_fixture()
  child.lua('require("agent-ide").toggle()')
  wait_for(function() return has_line(drawer_lines(), ' repo  ') ~= nil end, 'project row')
  if has_line(drawer_lines(), '> repo  ') then
    drawer_cursor_to('> repo  ')
    child.type_keys('<CR>')
  end
  drawer_cursor_to('Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() return has_line(transcript(), '## You') ~= nil end, 'history loaded')
end

local function send(text)
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().prompt)')
  child.type_keys('i', text, '<Esc>', '\\<CR>')
end

-- Tests -------------------------------------------------------------------------------------

T['<leader>ax parks: process stopped, transcript stays, parked shown; the next send resumes'] = function()
  start(turn('role', 'Hello.')) -- every process answers its first prompt (each runs the scenario)
  open_fixture()
  send('Hi')
  wait_for(function() return has_line(transcript(), 'Hello.') ~= nil and sess().state == 'idle' end, 'turn end')
  local before = transcript()
  child.type_keys('\\ax')
  wait_for(function() return sess().state == 'parked' end, 'parked')
  eq(sess().owned, false)
  eq(transcript(), before)
  wait_for(function() return vim.startswith(winbar(), '. parked · ') ~= nil end, 'winbar parked')
  wait_for(function() return has_line(drawer_lines(), '. Alpha basics') ~= nil end, 'drawer parked')
  -- until the next poll the live list may still show the process we stopped: still parked
  eq(child.lua_get([[(function(id)
    local live, s = require('agent-ide.live'), require('agent-ide.session').get(id)
    local orig = live.get
    live.get = function() return { [id] = { pid = s.pid, status = 'idle' } } end
    local st = require('agent-ide.ui.drawer_model').state_of(id)
    live.get = function() return { [id] = { pid = s.pid + 1, status = 'busy' } } end
    local other = require('agent-ide.ui.drawer_model').state_of(id)
    live.get = orig
    return { st, other }
  end)(...)]], { FIXTURE_ID }), { 'parked', 'busy' })
  send('Again')
  wait_for(function()
    local n = 0
    for _, l in ipairs(transcript()) do if l == 'Hello.' then n = n + 1 end end
    return n == 2 and sess().state == 'idle'
  end, 'resumed answer')
  local a = argvs()
  eq(#a, 2)
  eq(vim.tbl_contains(a[2], '--resume'), true)
end

T['parking a working session asks; declined keeps it, accepted returns queued prompts'] = function()
  start(flat({ { expect = 'Hi' }, init(), { sleep_ms = 4000 }, say('x'), result('x') }))
  child.lua('_G.answers = { 2, 1 }; vim.fn.confirm = function() return table.remove(_G.answers, 1) end')
  open_fixture()
  send('Hi')
  wait_for(function() return sess().state == 'busy' end, 'busy')
  send('queued one')
  wait_for(function() return sess().queue == 1 end, 'queued')
  child.type_keys('\\ax')
  vim.wait(200)
  eq(sess().state, 'busy')
  eq(child.lua_get('#_G.answers'), 1)
  child.type_keys('\\ax')
  wait_for(function() return sess().state == 'parked' end, 'parked')
  eq(prompt_lines(), { 'queued one' })
  eq(has_line(notes(), '1 queued prompt(s) returned to the prompt buffer') ~= nil, true)
end

T['sP on a drawer row parks that session'] = function()
  start(turn('Hi', 'Hello.'))
  open_fixture()
  send('Hi')
  wait_for(function() return sess().state == 'idle' end, 'turn end')
  drawer_cursor_to('Alpha basics')
  child.type_keys('sP')
  wait_for(function() return sess().state == 'parked' end, 'parked')
  eq(sess().owned, false)
end

T['parking a session that does not run here, or runs in another Claude: a notice'] = function()
  start(nil, vim.json.encode({ { sessionId = FIXTURE_ID, pid = 4242, status = 'busy', cwd = '/x' } }))
  open_fixture()
  child.type_keys('\\ax')
  wait_for(function() return has_line(notes(), 'nothing to park; it runs in another Claude') ~= nil end, 'notice')
  start()
  open_fixture()
  drawer_cursor_to('Alpha basics')
  child.type_keys('sP')
  wait_for(function() return has_line(notes(), 'nothing to park; it is not running in this Neovim') ~= nil end, 'notice 2')
  eq(fake.log(log), {})
end

T['help floats list the park keys'] = function()
  start()
  open_fixture()
  child.lua('_G.rows = {}; require("agent-ide.ui.help").open = function(title, rows) _G.rows[title] = rows end')
  child.type_keys('g?')
  drawer_cursor_to('Alpha basics')
  child.type_keys('?')
  local rows = child.lua_get('_G.rows')
  local function desc(title, key)
    for _, r in ipairs(rows[title] or {}) do
      if r.key == key then return r.desc end
    end
  end
  eq(desc('Agent-IDE chat', '<leader>ax'), "park: stop this session's Claude process (asks when working); the next send resumes it")
  eq(desc('Agent-IDE drawer', 'sP'), 'park the session: stop its Claude process here')
end

return T
