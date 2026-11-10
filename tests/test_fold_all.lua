-- zM (collapse all) and zR (expand all; again: everything) in the drawer, in a child Neovim with
-- synthetic git projects.
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }

local tmp, projects_dir

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    projects_dir = tmp .. '/projects'
    vim.fn.delete(vim.fn.stdpath('data') .. '/agent-ide/hidden.json')
  end,
  post_case = function()
    child.stop()
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

-- `n` git projects `proj01..`, each with `per` sessions (newest project first).
local function make(n, per)
  for p = 1, n do
    local name = ('proj%02d'):format(p)
    local repo = tmp .. '/' .. name
    vim.fn.mkdir(repo, 'p')
    vim.fn.system({ 'git', 'init', '-q', repo })
    local dir = projects_dir .. '/-' .. name
    vim.fn.mkdir(dir, 'p')
    for s = 1, per do
      local ts = os.date('!%Y-%m-%dT%H:%M:%SZ', os.time() - (p * 10 + s) * 60)
      local rec = vim.json.encode({ type = 'user', uuid = 'u', cwd = repo, timestamp = ts,
        message = { role = 'user', content = ('Topic %d of %s'):format(s, name) } })
      vim.fn.writefile({ rec }, ('%s/%08d-0000-4000-8000-%012d.jsonl'):format(dir, p, s))
    end
  end
end

local function start()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    vim.env.TMUX = nil
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    require('agent-ide').setup(...)
    require('agent-ide').toggle()
  ]], { {
    projects_dir = projects_dir,
    helper = { enabled = false },
    live = { interval_ms = 600000, cmd = { 'echo', '[]' } },
    icons_style = 'plain', icons = ICONS,
    prompts = { command_dirs = {}, skill_dirs = {}, project_dirs = false },
  } })
end

local function wait_for(cond, what, ms)
  if not vim.wait(ms or 5000, cond, 20) then error('timed out waiting for ' .. what, 2) end
end

local function lines()
  return child.lua_get([[(function()
    local s = require('agent-ide.ui.drawer').state()
    return s.buf and vim.api.nvim_buf_get_lines(s.buf, 0, -1, false) or {}
  end)()]])
end

local function find(text)
  for i, l in ipairs(lines()) do
    if l:find(text, 1, true) then return i end
  end
end

local function count(pattern)
  local n = 0
  for _, l in ipairs(lines()) do
    if l:find(pattern) then n = n + 1 end
  end
  return n
end

local function cursor_to(text)
  wait_for(function() return find(text) ~= nil end, 'drawer line ' .. text)
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })', { find(text) })
end

local function current() return child.lua_get('vim.api.nvim_get_current_line()') end

T['zR opens every project with its sessions, not Changes or Commits; again: everything'] = function()
  make(3, 2)
  start()
  wait_for(function() return count('^> proj') == 3 end, 'projects')
  cursor_to('> proj02')
  child.type_keys('z9')
  wait_for(function() return count('^v proj') == 3 end, 'all open')
  eq(count('Sessions %(2%)'), 3)
  eq(count('Topic'), 6)
  eq(count('^  v Changes'), 0)
  eq(count('^  > Changes'), 3)
  eq(current():find('^v proj02') ~= nil, true) -- the cursor stays on its node
  -- a second zR with nothing changed in between: Changes and Commits open too
  child.type_keys('z9')
  wait_for(function() return count('^  v Changes') == 3 end, 'changes open')
  eq(count('^  v .*[Cc]ommits'), 3)
  -- something changed in between: one level only again
  child.type_keys('z0')
  child.type_keys('z9')
  eq(count('^v proj'), 3)
end

T['zM leaves only top-level rows; za on a project opens it as before; cursor on the nearest ancestor'] = function()
  make(3, 2)
  start()
  wait_for(function() return count('^> proj') == 3 end, 'projects')
  child.type_keys('z9')
  cursor_to('Topic 2 of proj02')
  child.type_keys('z0')
  eq(count('^v '), 0)
  eq(#lines(), 3 + (find('Prompts') and 1 or 0))
  eq(current():find('^> proj02') ~= nil, true)
  child.type_keys('za')
  wait_for(function() return find('Topic 1 of proj02') ~= nil end, 'project open')
  eq(find('v Sessions (2)') ~= nil, true)
  eq(find('Topic 1 of proj01'), nil)
end

T['zR with 60 git projects: fast, and git starts in a few of them at a time'] = function()
  make(60, 2)
  start()
  wait_for(function() return count('^> proj') == 60 end, 'projects', 20000)
  local r = child.lua_get([[(function()
    local spawned = 0
    local orig = vim.system
    vim.system = function(cmd, ...)
      if cmd[1] == 'git' then spawned = spawned + 1 end
      return orig(cmd, ...)
    end
    local s = require('agent-ide.ui.drawer').state()
    vim.api.nvim_set_current_win(s.win)
    collectgarbage('collect')
    local t0 = vim.uv.hrtime()
    vim.fn.maparg('z9', 'n', false, true).callback()
    local ms = (vim.uv.hrtime() - t0) / 1e6
    local counting = require('agent-ide.ui.git_sections')._counting()
    vim.system = orig
    return { ms = ms, spawned = spawned, counting = counting }
  end)()]])
  eq(count('^v proj'), 60)
  eq(r.counting <= 4, true)
  eq(r.spawned < 60, true)
  if r.ms >= 50 then error(('expand all: %.1f ms, budget < 50 ms'):format(r.ms)) end
  -- the rest load as earlier ones finish
  wait_for(function() return child.lua_get('require("agent-ide.ui.git_sections")._counting()') == 0 end, 'counts loaded', 60000)
  eq(count('^  > Changes.*%(%d+%)'), 60)
end

return T
