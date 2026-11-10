-- Project scope (scope.lua): the setting, `:Agents project|all`, `S`, the drawer in project
-- scope, search, <leader>an and the footer. Synthetic repositories and sessions only.
local eq = MiniTest.expect.equality
local tree = require('agent-ide.ui.tree')
local model = require('agent-ide.ui.drawer_model')
local G = dofile(vim.fn.getcwd() .. '/tests/git_repo.lua')
local S = dofile(vim.fn.getcwd() .. '/tests/search_synth.lua')
local child = MiniTest.new_child_neovim()

local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+', worktree = 'T', prompts = '', changes = '', commits = '' }

local tmp, w, projects_dir

local function session(dir_name, id, prompt, n, cwd)
  S.write(projects_dir, dir_name, id, { S.user(prompt, n, cwd) })
end

-- alpha: a git repository with sessions in its root, a sub-folder and a linked worktree;
-- beta: another repository; plain: a folder without git; fresh: a repository without sessions.
local function fixtures()
  w = tmp .. '/w'
  G.init(w .. '/alpha')
  G.write(w .. '/alpha', 'README', 'alpha')
  G.commit(w .. '/alpha', 'first')
  vim.fn.mkdir(w .. '/alpha/sub', 'p')
  G.git(w .. '/alpha', { 'worktree', 'add', '-q', '-b', 'feat', w .. '/alpha-wt' })
  G.init(w .. '/beta')
  vim.fn.mkdir(w .. '/plain', 'p')
  G.init(w .. '/fresh')
  session('-w-alpha', 'a1', 'alpha release root', 50, w .. '/alpha')
  session('-w-alpha-sub', 'a2', 'alpha release sub', 40, w .. '/alpha/sub')
  session('-w-alpha-wt', 'a3', 'alpha release worktree', 30, w .. '/alpha-wt')
  session('-w-beta', 'b1', 'beta release', 60, w .. '/beta')
  session('-w-plain', 'p1', 'plain release', 20, w .. '/plain')
end

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = G.tmp()
    projects_dir = tmp .. '/projects'
    fixtures()
  end,
  post_case = function()
    child.stop()
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

local function start(opts, cwd)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local opts, cwd = ...
    vim.env.TMUX = nil
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    vim.g.mapleader = ' '
    vim.cmd.cd(cwd)
    require('agent-ide').setup(opts)
    vim.cmd('runtime plugin/agent-ide.lua')
  ]], { vim.tbl_deep_extend('force', {
    projects_dir = projects_dir,
    helper = { enabled = false },
    live = { interval_ms = 600000, cmd = { 'echo', '[]' } },
    claude = { cmd = { 'false' }, version_check = false },
    drawer = { width = 52 },
    icons_style = 'plain', icons = ICONS, tcd = false,
    prompts = { command_dirs = {}, skill_dirs = {}, project_dirs = false },
  }, opts or {}), cwd or (w .. '/alpha/sub') })
end

local function wait_for(cond, what, ms)
  if not vim.wait(ms or 8000, cond, 20) then error('timed out waiting for ' .. what, 2) end
end

local function lines()
  return child.lua_get([[(function()
    local s = require('agent-ide.ui.drawer').state()
    return s.buf and vim.api.nvim_buf_get_lines(s.buf, 0, -1, false) or {}
  end)()]])
end

local function find(text, plain)
  for i, l in ipairs(lines()) do
    if l:find(text, 1, plain ~= false) then return i end
  end
end

local function cursor_to(text)
  wait_for(function() return find(text) ~= nil end, 'drawer line ' .. text)
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })', { find(text) })
end

local function current_line() return child.lua_get('vim.api.nvim_get_current_line()') end
-- `eq(cond, true)` with the drawer's lines in the message
local function ok(cond, what)
  if not cond then error((what or 'failed') .. '\n' .. table.concat(lines(), '\n') .. '\ncursor: ' .. current_line(), 2) end
end
local function scope_key()
  return child.lua_get('(function() local p = require("agent-ide.scope").project(); return p and p.key or "all" end)()')
end
local function open_drawer()
  child.lua('require("agent-ide").toggle()')
  wait_for(function() return find('Sessions (', true) ~= nil or find('^> ', false) ~= nil end, 'drawer rows')
end

-- Pure ----------------------------------------------------------------------------------------

local function sample()
  return {
    { key = '/r/alpha', name = 'alpha', root = '/r/alpha', is_git = true, missing = false, activity = 1000, sessions = {
      { id = 's1', title = 'Fix login', activity = 1000 },
      { id = 's2', title = 'Docs', activity = 400, subpath = 'docs' } } },
    { key = '/r/beta', name = 'beta', root = '/r/beta', is_git = true, missing = false, activity = 900, sessions = {
      { id = 's3', title = 'Beta work', activity = 900 } } },
  }
end

local function states(map) return function(id) return map[id] or 'parked' end end

T['model: in_scope keeps the one project, or makes an empty one for a fresh repository'] = function()
  local p = sample()
  eq(model.in_scope(p, nil) == p, true)
  local out = model.in_scope(p, { key = '/r/beta', name = 'other name' })
  eq(#out, 1)
  eq(out[1] == p[2], true)
  out = model.in_scope(p, { key = '/r/fresh', name = 'fresh', root = '/r/fresh', is_git = true })
  eq({ out[1].key, out[1].name, out[1].root, out[1].is_git, #out[1].sessions, out[1].activity },
    { '/r/fresh', 'fresh', '/r/fresh', true, 0, 0 })
end

T['tree: project scope has a scope line, no project row, its rows one level up; others counted last'] = function()
  local p = model.in_scope(sample(), { key = '/r/alpha' })
  local function extra(_, ctx)
    if not ctx.open then return nil end
    return { { pieces = { { '  > Changes (2)', 'AgentIdeSection' } }, node = { type = 'git', id = 'c' } } }
  end
  local top = function() return { { pieces = { { '> Prompts' } }, node = { type = 'prompts', id = 'pr' } } } end
  local t = tree.build(p, states({ s1 = 'busy' }), {}, 1060, ICONS, nil, nil, extra,
    { top = top, width = 52, scope = { branch = 'main', others = 1, key = 'S' } })
  eq(t.lines, {
    'alpha  main' .. (' '):rep(52 - 11 - 16) .. 'project · S: all',
    '> Prompts',
    '  + New session',
    'v Sessions (2)',
    '    B Fix login                                  now',
    '    . docs/ · Docs                               11m',
    '> Changes (2)',
    '1 session in other projects needs you · S',
  })
  eq({ t.nodes[1].type, t.nodes[1].project == p[1] }, { 'scope', true })
  eq(t.nodes[3].type, 'new')
  eq(t.nodes[8].type, 'others')
  for _, h in ipairs(t.hl) do
    if h.line == 1 or h.line == 8 then eq(h.group, 'AgentIdeAge') end
  end
  t = tree.build(p, states({}), {}, 1060, ICONS, nil, nil, nil, { width = 52, scope = { others = 3, key = 'S' } })
  eq(t.lines[1], 'alpha' .. (' '):rep(52 - 5 - 16) .. 'project · S: all')
  eq(t.lines[#t.lines], '3 sessions in other projects need you · S')
  -- the Sessions section closes as in all scope
  t = tree.build(p, states({}), { ['/r/alpha/sessions'] = false }, 1060, ICONS, nil, nil, nil, { width = 52, scope = { key = 'S' } })
  eq(t.lines, { 'alpha' .. (' '):rep(52 - 5 - 16) .. 'project · S: all', '  + New session', '> Sessions (2)' })
  -- all scope: unchanged, no scope line
  t = tree.build(sample(), states({}), {}, 1060, ICONS, nil, nil, nil, { width = 52 })
  eq(t.lines, { '> alpha' .. (' '):rep(52 - 7 - 5) .. '. now', '> beta' .. (' '):rep(52 - 6 - 4) .. '. 2m' })
end

-- Child Neovim ----------------------------------------------------------------------------------

T['config: the scope starts as all; scope = project starts on the repository of the cwd'] = function()
  start()
  eq(child.lua_get('require("agent-ide.scope").get()'), 'all')
  open_drawer()
  wait_for(function() return find('> beta') ~= nil end, 'all projects')
  eq(find('project · S'), nil)
  start({ scope = 'project' }) -- cwd: alpha/sub
  eq(child.lua_get('require("agent-ide.scope").get()'), 'project')
  eq(scope_key(), w .. '/alpha')
  open_drawer()
  wait_for(function() return find('Sessions (3)') ~= nil end, 'project rows')
  eq(lines()[1]:match('^alpha') ~= nil, true)
  eq(lines()[1]:find('project · S: all', 1, true) ~= nil, true)
  eq(find('beta'), nil)
  eq(find('plain'), nil)
end

T['project scope rows: sub-folder and worktree sessions in one project, Sessions open, no project row'] = function()
  start({ scope = 'project' })
  open_drawer()
  wait_for(function() return find('alpha release worktree') ~= nil end, 'sessions')
  local l = lines()
  ok(l[1]:match('^alpha  main%s+project · S: all$') ~= nil or l[1]:match('^alpha%s+project · S: all$') ~= nil, 'scope line')
  wait_for(function() return lines()[1]:find('alpha  main', 1, true) ~= nil end, 'branch on the scope line')
  ok(find('^> Prompts', false) ~= nil, 'prompts')
  ok(find('^  %+ New session', false) ~= nil, 'new')
  ok(find('^v Sessions %(3%)', false) ~= nil, 'sessions')
  ok(find('^    . sub/ · alpha release sub', false) ~= nil, 'sub-folder session')
  for _, line in ipairs(lines()) do ok(line:find('^[>v] alpha') == nil, 'no project row') end
  -- the worktree's tree row (Changes and Commits inside) is at top level as well
  ok(find('^> T feat · alpha%-wt', false) ~= nil, 'worktree row')
end

T['project scope: a folder without git is its own project; a fresh repository shows Sessions (0)'] = function()
  start({ scope = 'project' }, w .. '/plain')
  open_drawer()
  wait_for(function() return find('plain release') ~= nil end, 'plain session')
  eq(lines()[1]:match('^plain%s+project · S: all$') ~= nil, true)
  eq(find('Sessions (1)') ~= nil, true)
  eq(find('alpha'), nil)

  start({ scope = 'project' }, w .. '/fresh')
  open_drawer()
  wait_for(function() return find('Sessions (0)') ~= nil end, 'empty project')
  eq(lines()[1]:match('^fresh') ~= nil, true)
  eq(find('release'), nil)
  cursor_to('+ New session')
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('#require("agent-ide.session").all()') == 1 end, 'new session')
  eq(child.lua_get('require("agent-ide.session").all()[1].cwd'), w .. '/fresh')
end

T[':Agents project / :Agents all switch and complete; S on a row of another project anchors there'] = function()
  start()
  eq(child.lua_get('vim.fn.getcompletion("Agents ", "cmdline")'), { 'project', 'all' })
  eq(child.lua_get('vim.fn.getcompletion("Agents p", "cmdline")'), { 'project' })
  child.cmd('Agents project') -- opens the drawer
  wait_for(function() return find('Sessions (3)') ~= nil end, 'project scope')
  eq(scope_key(), w .. '/alpha')
  child.cmd('Agents all')
  wait_for(function() return find('> beta') ~= nil end, 'all scope')
  eq(find('project · S'), nil)
  -- S on beta's row: scoped to beta, not to the cwd's alpha
  cursor_to('> beta')
  child.type_keys('S')
  eq(scope_key(), w .. '/beta')
  wait_for(function() return find('beta release') ~= nil end, 'beta scope')
  eq(find('alpha'), nil)
  -- S again: all, the cursor back on beta's project row
  child.type_keys('S')
  wait_for(function() return find('> alpha') ~= nil end, 'all again')
  eq(current_line():find('^> beta') ~= nil, true)
  -- :Agents project re-resolves from the cwd every time
  child.cmd('Agents project')
  eq(scope_key(), w .. '/alpha')
  child.cmd('cd ' .. w .. '/plain')
  child.cmd('Agents project')
  eq(scope_key(), w .. '/plain')
  -- <CR> on the scope line: all
  cursor_to('project · S: all')
  child.type_keys('<CR>')
  eq(child.lua_get('require("agent-ide.scope").get()'), 'all')
  -- help lists S
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win)')
  child.type_keys('?')
  local help = child.lua_get("vim.api.nvim_buf_get_lines(require('agent-ide.ui.help')._state().lbuf, 0, -1, false)")
  eq(vim.iter(help):any(function(l) return l:match('^S%s+scope') ~= nil end), true)
end

T['the other-projects line appears while one of them needs you, and goes away'] = function()
  start({ scope = 'project' })
  open_drawer()
  wait_for(function() return find('Sessions (3)') ~= nil end, 'project rows')
  eq(find('other projects'), nil)
  child.lua([[
    local session = require('agent-ide.session')
    _G.b = session.open({ id = 'b1', cwd = ... })
    _G.b:_set_state('waiting')
    require('agent-ide.ui.drawer').refresh()
  ]], { w .. '/beta' })
  wait_for(function() return find('1 session in other projects needs you · S') ~= nil end, 'others line')
  eq(find('1 session in other projects') == #lines(), true)
  eq(find('beta release'), nil) -- still not listed
  child.lua([[
    local s = require('agent-ide.session').open({ id = 'p1', cwd = ... })
    s:_set_state('done')
    require('agent-ide.ui.drawer').refresh()
  ]], { w .. '/plain' })
  wait_for(function() return find('2 sessions in other projects need you · S') ~= nil end, 'two')
  -- a session of this project does not count
  child.lua([[
    local s = require('agent-ide.session').open({ id = 'a1', cwd = ... })
    s:_set_state('waiting')
    require('agent-ide.session').get('p1'):_set_state('idle')
    _G.b:_set_state('busy')
    require('agent-ide.ui.drawer').refresh()
  ]], { w .. '/alpha' })
  wait_for(function() return find('other projects') == nil end, 'line gone')
end

T['search opens on this project and <Tab> widens; prompt history too'] = function()
  start({ scope = 'project' })
  local function state() return child.lua_get('require("agent-ide.ui.search")._state()') end
  -- the sessions of the hits, once the picker has a backend
  local function sessions()
    local s = state()
    if s == vim.NIL or s.backend == nil then return nil end
    local set = {}
    for _, h in ipairs(s.hits) do set[h.session] = true end
    local ids = vim.tbl_keys(set)
    table.sort(ids)
    return table.concat(ids, ' ')
  end
  child.lua('require("agent-ide").search({ query = "release" })')
  wait_for(function() return sessions() == 'a1 a2 a3' end, 'scoped hits')
  eq(state().scope, 'project')
  child.type_keys('<Tab>')
  wait_for(function() return state().scope == 'all' and sessions() == 'a1 a2 a3 b1 p1' end, 'all hits')
  child.type_keys('<Esc>', 'q')
  child.lua('require("agent-ide").prompt_history({ query = "release" })')
  wait_for(function() return sessions() == 'a1 a2 a3' end, 'scoped history')
  eq(state().scope, 'project')
  eq(state().kinds, { 'prompt' })
  child.type_keys('<Esc>', 'q')
  -- all scope: as before
  child.cmd('Agents all')
  child.lua('require("agent-ide").search({ query = "release" })')
  wait_for(function() return sessions() == 'a1 a2 a3 b1 p1' end, 'all scope hits')
  eq(state().scope, 'all')
end

T['<leader>an and the statusline ignore other projects; the status file still lists them'] = function()
  start({ scope = 'project', live = { interval_ms = 600000, cmd = { 'echo', '[]' } } })
  child.lua([[
    local session = require('agent-ide.session')
    local b = session.open({ id = 'b1', cwd = ... })
    b:_set_state('waiting')
    require('agent-ide.status').refresh()
  ]], { w .. '/beta' })
  eq(child.lua_get('#require("agent-ide.ui.waiting").needing()'), 0)
  eq(child.lua_get('require("agent-ide").statusline()'):match('^agents ok') ~= nil, true)
  eq(child.lua_get('require("agent-ide").statusline_hl()'), 'AgentIdeLevel1')
  child.lua('require("agent-ide").next_waiting()')
  eq(child.lua_get('_G.notes[#_G.notes]'), 'Agent-IDE: nothing in this project; 1 in other projects (S)')
  local snap = child.lua_get('require("agent-ide.status").snapshot()')
  eq({ snap.level, snap.waiting, snap.sessions[1].id, snap.sessions[1].state }, { 4, 1, 'b1', 'waiting' })
  local file = child.lua_get('require("agent-ide.status").file()')
  wait_for(function()
    local f = io.open(file, 'rb')
    if not f then return false end
    local ok, j = pcall(vim.json.decode, f:read('a'))
    f:close()
    return ok and j.level == 4 and j.sessions[1] and j.sessions[1].id == 'b1'
  end, 'status file lists b1')
  -- a session of this project counts
  child.lua([[
    require('agent-ide.session').open({ id = 'a2', cwd = ... }):_set_state('waiting')
  ]], { w .. '/alpha/sub' })
  local list = child.lua_get('vim.tbl_map(function(x) return x.id end, require("agent-ide.ui.waiting").needing())')
  eq(list, { 'a2' })
  eq(child.lua_get('require("agent-ide").statusline()'):match('^input required %(1%)') ~= nil, true)
  -- all scope: both
  child.lua('require("agent-ide.scope").set("all")')
  eq(child.lua_get('#require("agent-ide.ui.waiting").needing()'), 2)
  eq(child.lua_get('require("agent-ide").statusline()'):match('^input required %(2%)') ~= nil, true)
end

T['live entries of other projects are not counted in project scope'] = function()
  local json = vim.json.encode({ { sessionId = 'b1', status = 'waiting', pid = 1, cwd = w .. '/beta' } })
  start({ scope = 'project', live = { interval_ms = 50, cmd = { 'echo', json } } })
  open_drawer()
  wait_for(function() return child.lua_get('require("agent-ide.live").get().b1 ~= nil') end, 'live map')
  eq(child.lua_get('#require("agent-ide.ui.waiting").needing()'), 0)
  eq(child.lua_get('require("agent-ide.status").level(nil, nil, require("agent-ide.scope").matches).waiting'), 0)
  eq(child.lua_get('require("agent-ide.status").level().waiting'), 1)
  -- but they are not hidden without a hint: the drawer's last line and <leader>an say so
  wait_for(function() return find('1 session in other projects needs you · S') ~= nil end, 'others line')
  child.lua('require("agent-ide").next_waiting()')
  eq(child.lua_get('_G.notes[#_G.notes]'), 'Agent-IDE: nothing in this project; 1 in other projects (S)')
  -- in all scope it is simply the next one
  child.lua('require("agent-ide.scope").set("all")')
  eq(child.lua_get('#require("agent-ide.ui.waiting").needing()'), 1)
end

T['each scope keeps its own open folds; the cursor stays on its node; focus does not move'] = function()
  start()
  open_drawer()
  cursor_to('> alpha')
  child.type_keys('<CR>')
  wait_for(function() return find('alpha release sub') ~= nil end, 'alpha open')
  cursor_to('> beta')
  child.type_keys('<CR>')
  wait_for(function() return find('beta release') ~= nil end, 'beta open')
  -- cursor on a session of alpha: still on it after the flip
  cursor_to('alpha release sub')
  child.cmd('Agents project')
  wait_for(function() return find('project · S: all') ~= nil end, 'project scope')
  ok(current_line():find('alpha release sub', 1, true) ~= nil, 'cursor kept')
  -- close Sessions in project scope
  cursor_to('v Sessions (3)')
  child.type_keys('za')
  wait_for(function() return find('> Sessions (3)') ~= nil end, 'closed')
  child.type_keys('S')
  wait_for(function() return find('beta release') ~= nil end, 'all: beta still open')
  ok(find('alpha release sub') ~= nil, 'alpha open') -- alpha's Sessions still open in all scope
  ok(current_line():find('^  v Sessions %(3%)') ~= nil, 'cursor on the same section')
  child.type_keys('S')
  wait_for(function() return find('> Sessions (3)') ~= nil end, 'project: Sessions still closed')
  -- from the main window: the scope changes, focus stays where it is
  child.lua([[
    local d = require('agent-ide.ui.drawer')
    vim.api.nvim_set_current_win(d.main_win())
    _G.win = vim.api.nvim_get_current_win()
  ]])
  child.cmd('Agents all')
  eq(child.lua_get('vim.api.nvim_get_current_win() == _G.win'), true)
  wait_for(function() return find('> beta') ~= nil or find('v beta') ~= nil end, 'all scope')
end

T['zM and zR in project scope work on the rows shown'] = function()
  start({ scope = 'project' })
  open_drawer()
  wait_for(function() return find('alpha release sub') ~= nil end, 'rows')
  cursor_to('alpha release sub')
  child.type_keys('z0')
  wait_for(function() return find('> Sessions (3)') ~= nil end, 'collapsed')
  eq(find('alpha release'), nil)
  child.type_keys('z9')
  wait_for(function() return find('v Sessions (3)') ~= nil end, 'expanded')
  eq(find('alpha release sub') ~= nil, true)
end

return T
