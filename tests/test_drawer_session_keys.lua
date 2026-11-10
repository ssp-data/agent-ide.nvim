-- The chat's session keys on a drawer session row (ui/drawer_session_keys.lua): model, mode,
-- interrupt, native Claude and the raw view, for the row's session without opening its chat.
-- Each case drives a child Neovim with the fake Claude.
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local FIXTURE_ID = '11111111-1111-4111-8111-111111111111'
local FIXTURE = vim.fn.getcwd() .. '/tests/fixtures/projects/-home-u-git-alpha/' .. FIXTURE_ID .. '.jsonl'
local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local ELSEWHERE = 'Agent-IDE: session is running in another Claude; use gp in the drawer to jump to it'
local LATER = '; takes effect when the session starts'

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
local function result(t, err) return { emit = { type = 'result', subtype = 'success', is_error = err or false, result = t } } end

local function start(steps, opts)
  opts = opts or {}
  local cmd
  cmd, log = fake.cmd(steps or {})
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local log, setup = ...
    vim.env.TMUX = nil
    vim.uv.os_setenv('FAKE_CLAUDE_LOG', log)
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    _G.feeds = {}
    local feed = vim.api.nvim_feedkeys
    vim.api.nvim_feedkeys = function(keys, mode, esc)
      table.insert(_G.feeds, keys)
      return feed(keys, mode, esc)
    end
    vim.ui.select = function(items, _, cb) cb(_G.pick and items[_G.pick] or nil) end
    require('agent-ide').setup(setup)
  ]], { log, {
    projects_dir = projects,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', opts.live_json or '[]' } },
    icons_style = 'plain', icons = ICONS,
    claude = { cmd = cmd, models = { 'opus', 'sonnet' } },
    keys = opts.keys,
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
  wait_for(function() return has_line(drawer_lines(), ' repo  ') ~= nil end, 'project row')
  if has_line(drawer_lines(), '> repo  ') then
    drawer_cursor_to('> repo  ')
    child.type_keys('<CR>')
  end
end

local function transcript()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript), 0, -1, false)')
end

-- The fixture session alive here (one turn sent from its chat), the cursor back on its row.
local function alive(text)
  show_drawer()
  drawer_cursor_to('Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() return has_line(transcript(), '## You') ~= nil end, 'history loaded')
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().prompt)')
  child.type_keys('i', text or 'Hi', '<Esc>', '\\<CR>')
end

local function sess()
  return child.lua_get([[(function(id)
    local s = require('agent-ide.session').get(id)
    return s and { state = s.state, mode = s.mode, mode_requested = s.mode_requested or vim.NIL,
      model_requested = s.model_requested or vim.NIL, alive = s:_alive(), deferred = #s.deferred } or vim.NIL
  end)(...)]], { FIXTURE_ID })
end

local function notes() return child.lua_get('_G.notes') end
local function last_note() local n = notes(); return n[#n] end

-- Control requests the fake Claude received.
local function requests()
  local out = {}
  for _, l in ipairs(fake.log(log)) do
    if l['in'] then
      local o = vim.json.decode(l['in'])
      if o.type == 'control_request' then out[#out + 1] = o.request end
    end
  end
  return out
end

local function argvs()
  local out = {}
  for _, l in ipairs(fake.log(log)) do
    if l.argv then out[#out + 1] = l.argv end
  end
  return out
end

-- Tests -------------------------------------------------------------------------------------

T['alive session: <S-Tab> and <leader>aM on its row ask its Claude; <C-c> only while it works'] = function()
  start({ { expect = 'Hi' }, init(), say('Hello.'), result('Hello.'),
    { expect = 'Second' }, { expect = 'interrupt' }, result('stopped', true) })
  alive()
  wait_for(function() return sess().state == 'idle' end, 'turn end')
  drawer_cursor_to('Alpha basics')
  child.type_keys('<S-Tab>')
  wait_for(function() return #requests() == 1 end, 'mode request')
  eq(requests()[1], { subtype = 'set_permission_mode', mode = 'acceptEdits' })
  eq(last_note(), 'Agent-IDE: mode acceptEdits')
  child.lua('_G.pick = 2')
  child.type_keys('\\aM')
  wait_for(function() return #requests() == 2 end, 'model request')
  eq(requests()[2], { subtype = 'set_model', model = 'sonnet' })
  eq(last_note(), 'Agent-IDE: model sonnet')
  -- idle: <C-c> does nothing
  child.type_keys('<C-c>')
  vim.wait(150)
  eq(#requests(), 2)
  -- working: <C-c> interrupts it
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().prompt)')
  child.type_keys('i', 'Second', '<Esc>', '\\<CR>')
  wait_for(function() return sess().state == 'busy' end, 'busy')
  drawer_cursor_to('Alpha basics')
  child.type_keys('<C-c>')
  wait_for(function() return #requests() == 3 end, 'interrupt request')
  eq(requests()[3].subtype, 'interrupt')
  wait_for(function() return sess().state ~= 'busy' end, 'turn ended')
end

T['parked session without a process: mode and model wait for the start; <C-c> does nothing'] = function()
  start()
  show_drawer()
  drawer_cursor_to('Alpha basics')
  child.type_keys('<S-Tab>')
  eq(sess().mode_requested, 'acceptEdits')
  eq(last_note(), 'Agent-IDE: mode acceptEdits' .. LATER)
  child.lua('_G.pick = 1')
  child.type_keys('\\aM')
  eq(sess().model_requested, 'opus')
  eq(last_note(), 'Agent-IDE: model opus' .. LATER)
  eq(sess().deferred, 2)
  local n = #notes()
  child.type_keys('<C-c>')
  vim.wait(100)
  eq(#notes(), n)
  eq(argvs(), {}) -- nothing started
  eq(sess().alive, false)
end

T['session running elsewhere: refused with the usual notice; the raw view still opens'] = function()
  start(nil, { live_json = vim.json.encode({ { sessionId = FIXTURE_ID, pid = 4242, status = 'busy', cwd = '/x' } }) })
  show_drawer()
  wait_for(function() return has_line(drawer_lines(), 'elsewhere') ~= nil end, 'elsewhere row')
  for _, k in ipairs({ '<S-Tab>', '\\aM', '<C-c>', '\\at' }) do
    drawer_cursor_to('Alpha basics')
    child.lua('_G.notes = {}')
    child.type_keys(k)
    eq({ k, notes() }, { k, { ELSEWHERE } })
  end
  local s = sess()
  eq(s == vim.NIL or (s.mode_requested == vim.NIL and s.model_requested == vim.NIL), true)
  eq(argvs(), {})
  drawer_cursor_to('Alpha basics')
  child.type_keys('gr')
  wait_for(function() return child.lua_get('vim.api.nvim_buf_get_name(0)'):find('agent-ide://raw/', 1, true) ~= nil end, 'raw view')
end

T['gr opens the raw view in the main window; <leader>at hands an alive session to native Claude'] = function()
  start({ { expect = 'Hi' }, init(), say('Hello.'), result('Hello.') })
  alive()
  wait_for(function() return sess().state == 'idle' end, 'turn end')
  drawer_cursor_to('Alpha basics')
  local drawer_win = child.lua_get('require("agent-ide.ui.drawer").state().win')
  child.type_keys('gr')
  wait_for(function() return child.lua_get('vim.api.nvim_buf_get_name(0)'):find('agent-ide://raw/', 1, true) ~= nil end, 'raw view')
  eq(child.lua_get('vim.api.nvim_get_current_win()') ~= drawer_win, true)
  eq(has_line(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), '>> ') ~= nil, true)
  -- not in tmux: native parks it and says how to continue by hand
  drawer_cursor_to('Alpha basics')
  child.type_keys('\\at')
  wait_for(function() return sess().state == 'parked' end, 'parked for native')
  eq(last_note():find('parked; not in tmux, so continue it by hand: ', 1, true) ~= nil, true)
end

T['on other rows the keys do nothing; <S-Tab> and <C-c> keep their Vim meaning'] = function()
  start()
  show_drawer()
  drawer_cursor_to('> Prompts')
  local before = child.lua_get('{ win = vim.api.nvim_get_current_win(), wins = #vim.api.nvim_list_wins() }')
  child.lua('_G.feeds = {}')
  for _, k in ipairs({ '\\aM', 'gr', '\\at' }) do child.type_keys(k) end
  vim.wait(100)
  eq(child.lua_get('{ win = vim.api.nvim_get_current_win(), wins = #vim.api.nvim_list_wins() }'), before)
  eq(child.lua_get('_G.feeds'), {})
  child.type_keys('<S-Tab>')
  child.type_keys('<C-c>')
  eq(child.lua_get('_G.feeds'), { child.lua_get('vim.keycode("<S-Tab>")'), child.lua_get('vim.keycode("<C-c>")') })
  eq(notes(), {})
  eq(sess(), vim.NIL)
end

T['a remapped chat key applies in the drawer too; the help lists them under a heading'] = function()
  start(nil, { keys = { chat = { mode = 'gm', raw = false } } })
  show_drawer()
  drawer_cursor_to('Alpha basics')
  eq(child.lua_get('vim.fn.maparg("<S-Tab>", "n")'), '')
  child.type_keys('gm')
  eq(sess().mode_requested, 'acceptEdits')
  child.lua('_G.rows = {}; require("agent-ide.ui.help").open = function(_, rows) _G.rows = rows end')
  child.type_keys('?')
  local rows = child.lua_get('_G.rows')
  local at
  for i, r in ipairs(rows) do if r.heading == 'On a session row' then at = i end end
  eq(at ~= nil, true)
  local after = vim.tbl_map(function(r) return r.key end, vim.list_slice(rows, at + 1))
  eq(after, { '<leader>aM', 'gm', '<C-c>', '<leader>at' })
end

return T
