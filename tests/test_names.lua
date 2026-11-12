-- Session names: the mapping file (names.lua) and `r` on a drawer session row in a child
-- Neovim. Synthetic sessions only; Claude's transcript files are never changed.
local eq = MiniTest.expect.equality
local names = require('agent-ide.names')
local child = MiniTest.new_child_neovim()

local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local ID = {
  a = 'bbbbbbbb-0000-4000-8000-000000000001',
  b = 'bbbbbbbb-0000-4000-8000-000000000002',
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
    vim.fn.delete(vim.fn.stdpath('data') .. '/agent-ide/names.json') -- the runner's temporary data folder
    names._reset()
  end,
  post_case = function()
    child.stop()
    names._reset()
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

-- The mapping ------------------------------------------------------------------------------------

T['with: named sessions get the name, Claude\'s title kept in raw_title; the rest untouched'] = function()
  eq(names.set('s2', 'Long runner'), true)
  local projects = {
    { key = '/r/alpha', name = 'alpha', sessions = { { id = 's1', title = 'Fix login' }, { id = 's2', title = 'Try once', cwd = '/x' } } },
    { key = '/r/beta', name = 'beta', sessions = { { id = 's3', title = 'Beta work' } } },
  }
  local out = names.with(projects)
  eq(out ~= projects, true)
  eq(out[2] == projects[2], true) -- nothing named there: the same table
  eq(out[1].name, 'alpha') -- the project's other fields reach through
  eq(out[1].sessions[1] == projects[1].sessions[1], true)
  eq({ out[1].sessions[2].title, out[1].sessions[2].raw_title, out[1].sessions[2].cwd }, { 'Long runner', 'Try once', '/x' })
  eq(projects[1].sessions[2].title, 'Try once') -- the input is not changed
  eq(names.set('s2', nil), true)
  eq(names.with(projects) == projects, true)
end

T['set: empty removes; a corrupt or foreign file means no names'] = function()
  local file = vim.fn.stdpath('data') .. '/agent-ide/names.json'
  eq(names.set('a', 'one'), true)
  eq(names.get('a'), 'one')
  eq(names.set('a', ''), true)
  eq(names.get('a'), nil)
  eq(vim.json.decode(table.concat(vim.fn.readfile(file), '\n')), { version = 1, names = {} })
  vim.fn.writefile({ '{"version":1,"names":{"a":1,"b":"","c":"kept"}}' }, file)
  names._reset()
  eq({ names.get('a'), names.get('b'), names.get('c') }, { nil, nil, 'kept' })
  vim.fn.writefile({ 'not json' }, file)
  names._reset()
  eq(names.any(), false)
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

local function start()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    vim.env.TMUX = nil
    vim.o.columns = 160 -- room for the whole title in the winbar
    _G.notes, _G.inputs, _G.answer = {}, {}, nil
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    vim.ui.input = function(opts, cb)
      table.insert(_G.inputs, opts)
      cb(_G.answer)
    end
    require('agent-ide').setup(...)
  ]], { {
    projects_dir = projects_dir,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', '[]' } },
    icons_style = 'plain', icons = ICONS,
    claude = { cmd = { 'false' } },
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

local function open_project()
  child.lua('require("agent-ide").toggle()')
  cursor_to('> repo')
  child.type_keys('<CR>')
  cursor_to('Sessions (')
end

local function winbar()
  local bar = child.lua_get('vim.wo[require("agent-ide.ui.chat")._windows().transcript].winbar')
  return (bar:gsub('%%#[^#]*#', ''):gsub('%%%*', ''):gsub('%%=', '  '):gsub('%%%%', '%%'))
end
local function bufnames()
  return child.lua_get([[vim.tbl_map(function(b) return vim.api.nvim_buf_get_name(b) end,
    vim.tbl_filter(function(b) return vim.api.nvim_buf_get_name(b):find('^agents://repo/') ~= nil end, vim.api.nvim_list_bufs()))]])
end
local function names_file() return child.lua_get("vim.fn.stdpath('data') .. '/agent-ide/names.json'") end
local function read_json(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local t = f:read('a')
  f:close()
  return vim.json.decode(t)
end
local function transcript_bytes(id)
  return table.concat(vim.fn.readfile(projects_dir .. '/-repo/' .. id .. '.jsonl', 'b'), '\n')
end

T['r names a session: drawer, winbar and buffer names show it; Claude\'s file is untouched; survives a restart'] = function()
  write_session(ID.a, 'First topic', 1)
  write_session(ID.b, 'Second topic', 2)
  local before = transcript_bytes(ID.b)
  start()
  open_project()
  local row = cursor_to('Second topic')
  child.lua('_G.answer = "Long runner"')
  child.type_keys('r')
  wait_for(function() return has_line(drawer_lines(), 'Long runner') ~= nil end, 'named row')
  eq(has_line(drawer_lines(), 'Second topic'), nil)
  eq(has_line(drawer_lines(), 'Long runner'), row)
  eq(child.lua_get('_G.inputs[1].default'), 'Second topic')
  eq(read_json(names_file()), { version = 1, names = { [ID.b] = 'Long runner' } })
  eq(vim.uv.fs_stat(names_file()).mode % 512, 384)
  eq(transcript_bytes(ID.b), before)
  eq(has_line(child.lua_get('_G.notes'), 'named "Long runner"') ~= nil, true)
  -- the chat of a named session
  cursor_to('Long runner')
  child.type_keys('<CR>')
  wait_for(function() return winbar():find('Long runner', 1, true) ~= nil end, 'winbar name')
  eq(has_line(bufnames(), 'agents://repo/Long runner') ~= nil, true)
  -- an open session renamed again: the winbar and the buffer names follow
  cursor_to('Long runner')
  child.lua('_G.answer = "Longer runner"')
  child.type_keys('r')
  wait_for(function() return winbar():find('Longer runner', 1, true) ~= nil end, 'winbar renamed')
  eq(has_line(bufnames(), 'agents://repo/Longer runner') ~= nil, true)
  -- r on a non-session row: nothing asked
  cursor_to('Sessions (')
  child.type_keys('r')
  eq(child.lua_get('#_G.inputs'), 2)
  -- cancelled (nil) and unchanged answers change nothing
  cursor_to('Longer runner')
  child.lua('_G.answer = nil')
  child.type_keys('r')
  child.lua('_G.answer = "Longer runner"')
  child.type_keys('r')
  eq(read_json(names_file()), { version = 1, names = { [ID.b] = 'Longer runner' } })

  -- restart: still named; the empty answer brings Claude's title back
  start()
  open_project()
  cursor_to('Longer runner')
  child.lua('_G.answer = ""')
  child.type_keys('r')
  wait_for(function() return has_line(drawer_lines(), 'Second topic') ~= nil end, 'title again')
  eq(read_json(names_file()), { version = 1, names = {} })
  -- typing the title itself names nothing
  cursor_to('Second topic')
  child.lua('_G.answer = "Second topic"')
  child.type_keys('r')
  eq(read_json(names_file()), { version = 1, names = {} })
end

T['search shows the name and opens the session with it'] = function()
  write_session(ID.a, 'First topic', 1)
  write_session(ID.b, 'Second topic', 2)
  start()
  child.lua(('require("agent-ide.names").set(%q, "Long runner")'):format(ID.b))
  child.lua('require("agent-ide").search({ query = "Second" })')
  wait_for(function()
    local st = child.lua_get('require("agent-ide.ui.search")._state and require("agent-ide.ui.search")._state() or {}')
    return st.hits and #st.hits > 0
  end, 'hits')
  local st = child.lua_get('require("agent-ide.ui.search")._state()')
  eq(st.hits[1].title, 'Long runner')
  eq(st.hits[1].raw_title, 'Second topic')
end

return T
