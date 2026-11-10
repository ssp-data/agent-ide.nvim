-- Hidden sessions: the model rule (drawer_model.with_hidden), the tree's `Hidden (n)` group, and
-- `H` in a child Neovim with the hidden.json file (synthetic sessions only).
local eq = MiniTest.expect.equality
local model = require('agent-ide.ui.drawer_model')
local tree = require('agent-ide.ui.tree')
local child = MiniTest.new_child_neovim()

local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local ID = {
  a = 'aaaaaaaa-0000-4000-8000-000000000001',
  b = 'aaaaaaaa-0000-4000-8000-000000000002',
  c = 'aaaaaaaa-0000-4000-8000-000000000003',
  d = 'aaaaaaaa-0000-4000-8000-000000000004',
}

local tmp, repo, projects_dir

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    repo = tmp .. '/repo'
    projects_dir = tmp .. '/projects'
    vim.fn.mkdir(repo, 'p')
    vim.fn.system({ 'git', 'init', '-q', repo })
    vim.fn.delete(vim.fn.stdpath('data') .. '/agent-ide/hidden.json') -- the runner's temporary data folder
  end,
  post_case = function()
    child.stop()
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

-- Pure model and tree ---------------------------------------------------------------------------

local function sample()
  return {
    { key = '/r/alpha', name = 'alpha', is_git = true, missing = false, activity = 1000, sessions = {
      { id = 's1', title = 'Fix login', activity = 1000 },
      { id = 's2', title = 'Try once', activity = 900 },
      { id = 's3', title = 'Docs', activity = 400 } } },
    { key = '/r/beta', name = 'beta', is_git = true, missing = false, activity = 800, sessions = {
      { id = 's4', title = 'Beta work', activity = 800 } } },
  }
end

local function states(map) return function(id) return map[id] or 'parked' end end
local function set(...)
  local out = {}
  for _, id in ipairs({ ... }) do out[id] = true end
  return function(id) return out[id] == true end
end

T['model: nothing hidden returns the projects unchanged'] = function()
  local p = sample()
  eq(model.with_hidden(p, set(), states({})) == p, true)
end

T['model: hidden sessions move to `hidden`; activity and order follow the visible ones'] = function()
  local out = model.with_hidden(sample(), set('s1', 's2'), states({}))
  -- alpha's newest visible session is 400: beta (800) comes first now
  eq(vim.tbl_map(function(p) return p.name end, out), { 'beta', 'alpha' })
  local alpha = out[2]
  eq(vim.tbl_map(function(s) return s.id end, alpha.sessions), { 's3' })
  eq(vim.tbl_map(function(s) return s.id end, alpha.hidden), { 's1', 's2' })
  eq(alpha.activity, 400)
  eq(alpha.key, '/r/alpha')
end

T['model: a hidden session that needs attention stays visible (waiting, busy, done, failed)'] = function()
  for _, st in ipairs({ 'waiting', 'busy', 'done', 'failed' }) do
    local out = model.with_hidden(sample(), set('s1', 's2'), states({ s1 = st }))
    local alpha = out[1]
    eq(alpha.name, 'alpha')
    eq(vim.tbl_map(function(s) return s.id end, alpha.sessions), { 's1', 's3' })
    eq(vim.tbl_map(function(s) return s.id end, alpha.hidden), { 's2' })
    eq(alpha.activity, 1000)
    -- counted in the project's roll-up
    local t = tree.build(out, states({ s1 = st }), {}, 1060, ICONS)
    eq(t.lines[1]:find(ICONS[st], 1, true) ~= nil, true)
  end
  -- idle and parked: hidden
  local out = model.with_hidden(sample(), set('s1'), states({ s1 = 'idle' }))
  eq(#out[1].hidden, 1)
end

T['model: a project with only hidden sessions shows them in its group, sorted last'] = function()
  local out = model.with_hidden(sample(), set('s1', 's2', 's3'), states({}))
  eq(vim.tbl_map(function(p) return p.name end, out), { 'beta', 'alpha' })
  eq(#out[2].sessions, 0)
  eq(#out[2].hidden, 3)
  eq(out[2].activity, 1000) -- the age shown: its newest session
  local t = tree.build(out, states({}), { ['/r/alpha'] = true }, 1060, ICONS)
  eq(t.lines, { '> beta  . 4m', 'v alpha  . now', '    + New session', '  v Sessions (0)', '    > Hidden (3)' })
end

T['tree: Hidden (n) is the last row of Sessions, collapsed, dimmed; expanding lists the sessions'] = function()
  local out = model.with_hidden(sample(), set('s2'), states({}))
  local t = tree.build(out, states({ s1 = 'idle' }), { ['/r/alpha'] = true }, 1060, ICONS, nil, nil, nil, { width = 40 })
  eq(t.lines, {
    'v alpha                            I now',
    '    + New session',
    '  v Sessions (2)',
    '      I Fix login                    now',
    '      . Docs                         11m',
    '    > Hidden (1)',
    '> beta                              . 4m',
  })
  eq({ t.nodes[6].type, t.nodes[6].key }, { 'hidden', '/r/alpha/hidden' })
  local dim
  for _, h in ipairs(t.hl) do
    if h.line == 6 and h.group == 'AgentIdeParked' then dim = h end
  end
  eq(dim ~= nil, true)
  t = tree.build(out, states({}), { ['/r/alpha'] = true, ['/r/alpha/hidden'] = true }, 1060, ICONS, nil, nil, nil, { width = 40 })
  eq(t.lines[6], '    v Hidden (1)')
  eq(t.lines[7], '        . Try once                    2m')
  eq({ t.nodes[7].type, t.nodes[7].session.id, t.nodes[7].hidden }, { 'session', 's2', true })
  -- the closed section hides the group too
  t = tree.build(out, states({}), { ['/r/alpha'] = true, ['/r/alpha/sessions'] = false }, 1060, ICONS)
  eq(#t.lines, 4)
end

-- Child Neovim -----------------------------------------------------------------------------------

local function write_session(id, prompt, hours_ago)
  local dir = projects_dir .. '/-repo'
  vim.fn.mkdir(dir, 'p')
  local ts = os.date('!%Y-%m-%dT%H:%M:%SZ', os.time() - hours_ago * 3600)
  local rec = vim.json.encode({ type = 'user', uuid = 'u-' .. id, cwd = repo, timestamp = ts,
    message = { role = 'user', content = prompt } })
  vim.fn.writefile({ rec }, dir .. '/' .. id .. '.jsonl')
end

local function sessions()
  write_session(ID.a, 'First topic', 1)
  write_session(ID.b, 'Second topic', 2)
  write_session(ID.c, 'Third topic', 3)
end

local function start(live_json)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    vim.env.TMUX = nil
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    require('agent-ide').setup(...)
  ]], { {
    projects_dir = projects_dir,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', live_json or '[]' } },
    icons_style = 'plain', icons = ICONS,
    prompts = { command_dirs = {}, skill_dirs = {}, project_dirs = false },
  } })
end

local function wait_for(cond, what, ms)
  if not vim.wait(ms or 5000, cond, 20) then error('timed out waiting for ' .. what, 2) end
end

local function drawer_lines()
  return child.lua_get([[(function()
    local s = require('agent-ide.ui.drawer').state()
    return s.buf and vim.api.nvim_buf_get_lines(s.buf, 0, -1, false) or {}
  end)()]])
end

local function has_line(lines, text)
  for i, l in ipairs(lines) do
    if l:find(text, 1, true) then return i end
  end
end

local function cursor_to(text)
  wait_for(function() return has_line(drawer_lines(), text) ~= nil end, 'drawer line ' .. text)
  local row = has_line(drawer_lines(), text)
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })', { row })
  return row
end

local function cursor_row() return child.lua_get('vim.api.nvim_win_get_cursor(0)[1]') end
local function current_line() return child.lua_get('vim.api.nvim_get_current_line()') end

local function open_project()
  child.lua('require("agent-ide").toggle()')
  cursor_to('> repo')
  child.type_keys('<CR>')
  cursor_to('Sessions (')
end

local function hidden_file() return child.lua_get("vim.fn.stdpath('data') .. '/agent-ide/hidden.json'") end
local function read_json(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local t = f:read('a')
  f:close()
  return vim.json.decode(t)
end

T['H hides a session into Hidden (n) and back; cursor stays on its screen line; survives a restart'] = function()
  sessions()
  start()
  open_project()
  eq(has_line(drawer_lines(), 'Sessions (3)') ~= nil, true)
  local row = cursor_to('Second topic')
  child.type_keys('H')
  wait_for(function() return has_line(drawer_lines(), 'Hidden (1)') ~= nil end, 'hidden group')
  local lines = drawer_lines()
  eq(has_line(lines, 'Sessions (2)') ~= nil, true)
  eq(has_line(lines, 'Second topic'), nil) -- collapsed group
  eq(has_line(lines, 'Hidden (1)'), has_line(lines, 'Third topic') + 1) -- last row of the section
  eq(cursor_row(), row)
  eq(current_line():find('Third topic', 1, true) ~= nil, true)
  local file = hidden_file()
  eq(read_json(file), { version = 1, ids = { [ID.b] = true } })
  eq(vim.uv.fs_stat(file).mode % 512, 384)
  eq(vim.uv.fs_stat(vim.fs.dirname(file)).mode % 512, 448)
  -- H on a non-session row: nothing
  cursor_to('Sessions (2)')
  child.type_keys('H')
  eq(read_json(file), { version = 1, ids = { [ID.b] = true } })
  -- expand the group: an ordinary session row
  cursor_to('Hidden (1)')
  child.type_keys('<CR>')
  wait_for(function() return has_line(drawer_lines(), 'Second topic') ~= nil end, 'group expanded')
  eq(has_line(drawer_lines(), 'v Hidden (1)') ~= nil, true)

  -- restart: still hidden
  start()
  open_project()
  wait_for(function() return has_line(drawer_lines(), 'Hidden (1)') ~= nil end, 'hidden after restart')
  cursor_to('Hidden (1)')
  child.type_keys('za')
  row = cursor_to('Second topic')
  child.type_keys('H') -- un-hide
  wait_for(function() return has_line(drawer_lines(), 'Sessions (3)') ~= nil end, 'shown again')
  eq(has_line(drawer_lines(), 'Hidden ('), nil)
  eq(cursor_row(), row)
  eq(read_json(file), { version = 1, ids = {} })
end

T['a hidden session waiting for input is listed among the visible rows'] = function()
  sessions()
  start('[{"sessionId":"' .. ID.b .. '","status":"waiting","pid":1,"cwd":"' .. repo .. '"}]')
  child.lua('require("agent-ide.hidden").set(...)', { ID.b, true })
  open_project()
  wait_for(function() return has_line(drawer_lines(), 'W Second topic') ~= nil end, 'waiting row')
  local lines = drawer_lines()
  eq(has_line(lines, 'Sessions (3)') ~= nil, true)
  eq(has_line(lines, 'Hidden ('), nil)
  eq(lines[has_line(lines, 'repo')]:find('input (1)', 1, true) ~= nil, true)
end

T['a project whose sessions are all hidden still shows'] = function()
  sessions()
  start()
  for _, id in ipairs({ ID.a, ID.b, ID.c }) do child.lua('require("agent-ide.hidden").set(...)', { id, true }) end
  open_project()
  wait_for(function() return has_line(drawer_lines(), 'Hidden (3)') ~= nil end, 'group')
  eq(has_line(drawer_lines(), 'Sessions (0)') ~= nil, true)
end

T['two Neovims: each change is applied onto the other one\'s'] = function()
  sessions()
  start()
  child.lua('require("agent-ide.hidden").set(...)', { ID.a, true })
  local file = hidden_file()
  -- another instance hid b meanwhile (written behind this one's back)
  vim.uv.sleep(20)
  local f = io.open(file, 'w')
  f:write(vim.json.encode({ version = 1, ids = { [ID.a] = true, [ID.b] = true } }))
  f:close()
  child.lua('require("agent-ide.hidden").set(...)', { ID.c, true })
  eq(read_json(file).ids, { [ID.a] = true, [ID.b] = true, [ID.c] = true })
  child.lua('require("agent-ide.hidden").set(...)', { ID.a, false })
  eq(read_json(file).ids, { [ID.b] = true, [ID.c] = true })
  eq(child.lua_get('require("agent-ide.hidden").is(...)', { ID.b }), true)
end

T['a corrupt or foreign hidden.json means nothing hidden'] = function()
  sessions()
  start()
  local file = hidden_file()
  vim.fn.mkdir(vim.fs.dirname(file), 'p')
  for _, text in ipairs({ '{not json', '[1,2]', '{"version":2,"ids":{"x":true}}', '{"version":1,"ids":[1]}' }) do
    local f = io.open(file, 'w')
    f:write(text)
    f:close()
    child.lua('require("agent-ide.hidden")._reset(); require("agent-ide.hidden").load()')
    eq(child.lua_get('require("agent-ide.hidden").any()'), false)
  end
  eq(child.lua_get('#_G.notes'), 0)
  -- and it is replaced on the next change
  child.lua('require("agent-ide.hidden").set(...)', { ID.a, true })
  eq(read_json(file), { version = 1, ids = { [ID.a] = true } })
end

return T
