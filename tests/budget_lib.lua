-- Shared by tests/bench.lua and tests/test_budget.lua: synthetic data generator and the
-- four speed measurements of the spec (section 9.1). Synthetic data only.
local M = {}

M.ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.' }

local function jline(t) return vim.json.encode(t) end

-- One synthetic transcript of about `target` bytes. The first prompt carries `title`.
local function session_lines(cwd, title, target)
  local out, size, n = {}, 0, 0
  local blob = string.rep('x', 3000)
  local result = string.rep('line of synthetic tool output\n', 30)
  local function add(rec)
    local s = jline(rec)
    out[#out + 1] = s
    size = size + #s + 1
  end
  while size < target do
    n = n + 1
    local u = 'u' .. n
    add({ type = 'user', uuid = u .. 'a', cwd = cwd, gitBranch = 'main',
      message = { role = 'user', content = n == 1 and title or ('Synthetic prompt number ' .. n) } })
    add({ type = 'assistant', uuid = u .. 'b', cwd = cwd, message = { role = 'assistant',
      content = { { type = 'text', text = 'Synthetic answer ' .. n .. ' with some words in it.' } } } })
    add({ type = 'assistant', uuid = u .. 'c', cwd = cwd, message = { role = 'assistant',
      content = { { type = 'tool_use', id = 't' .. n, name = 'Bash', input = { command = 'ls -la' } } } } })
    add({ type = 'user', uuid = u .. 'd', cwd = cwd, message = { role = 'user',
      content = { { type = 'tool_result', tool_use_id = 't' .. n, content = result } } } })
    add({ type = 'api-request-blob', hash = 'h' .. n, message = { content = blob } })
  end
  return out
end

local function write(path, lines) vim.fn.writefile(lines, path) end

---Create `root/projects` with 60 projects x 5 sessions (~200 KB each) and one 1 MB session
---in project 1. Returns the projects dir.
---@param root string
---@return string
function M.generate(root)
  local projects = root .. '/projects'
  for p = 1, 60 do
    local name = string.format('proj%02d', p)
    local cwd = '/home/u/synthetic/' .. name
    local dir = projects .. '/-home-u-synthetic-' .. name
    vim.fn.mkdir(dir, 'p')
    for s = 1, 5 do
      write(string.format('%s/%08d-0000-4000-8000-%012d.jsonl', dir, p, s),
        session_lines(cwd, 'Synthetic session ' .. s, 200 * 1024))
    end
    if p == 1 then
      write(dir .. '/ffffffff-0000-4000-8000-000000000001.jsonl',
        session_lines(cwd, 'Synthetic big session', 1024 * 1024))
    end
  end
  return projects
end

-- Everything below runs inside a child Neovim (see M.start_child).

local function project_lines()
  local s = require('agent-ide.ui.drawer').state()
  local n = 0
  if s.buf then
    for _, l in ipairs(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)) do
      if l:find('^[v>] ') and not l:find('Prompts$') then n = n + 1 end
    end
  end
  return n
end

local function ms(t0) return (vim.uv.hrtime() - t0) / 1e6 end

-- 1 ms repeating timer recording the largest gap between ticks. stop() returns it in ms.
local function gap_probe()
  local timer, last, worst = vim.uv.new_timer(), vim.uv.hrtime(), 0
  timer:start(1, 1, function()
    local now = vim.uv.hrtime()
    worst = math.max(worst, now - last)
    last = now
  end)
  return function()
    local now = vim.uv.hrtime()
    worst = math.max(worst, now - last)
    timer:stop()
    timer:close()
    return worst / 1e6
  end
end

local function setup(dir, backend)
  vim.env.TMUX = nil
  require('agent-ide').setup({
    projects_dir = dir,
    helper = { enabled = backend == 'helper' },
    live = { interval_ms = 600000, cmd = { 'echo', '[]' } }, -- never runs `claude`
    icons = M.ICONS,
    keys = false,
  })
end

local function wait_projects(expected, what)
  if not vim.wait(120000, function() return project_lines() == expected end, 1) then
    error('timed out waiting for ' .. expected .. ' project lines (' .. what .. ', saw ' .. project_lines() .. ')')
  end
end

---Fresh child: (b) cold open, then (a) warm reopen, then (c) history of the largest session.
---@return { cold: number, warm: number, history: number, history_block: number, backend: string, big_size: number }
function M.run_open(dir, backend, expected)
  setup(dir, backend)
  if require('agent-ide.index').backend() ~= backend then error('backend ' .. backend .. ' unavailable') end
  local drawer = require('agent-ide.ui.drawer')
  local r = { backend = backend }

  local t0 = vim.uv.hrtime()
  require('agent-ide').toggle()
  wait_projects(expected, 'cold')
  r.cold = ms(t0)

  require('agent-ide').toggle() -- close the drawer
  assert(drawer.state().win == nil, 'drawer should be closed')
  t0 = vim.uv.hrtime()
  require('agent-ide').toggle()
  wait_projects(expected, 'warm')
  r.warm = ms(t0)

  -- largest session
  local best
  for _, p in ipairs(drawer.state().projects) do
    for _, s in ipairs(p.sessions) do
      if not best or s.size > best.size then best = s end
    end
  end
  r.big_size = best.size
  local function row_of(pred)
    for i, node in ipairs(drawer.state().nodes) do
      if pred(node) then return i end
    end
  end
  local function press_enter(row)
    local s = drawer.state()
    vim.api.nvim_set_current_win(s.win)
    vim.api.nvim_win_set_cursor(s.win, { row, 0 })
    vim.fn.maparg('<CR>', 'n', false, true).callback()
  end
  press_enter(row_of(function(n)
    return n.type == 'project' and vim.iter(n.project.sessions):any(function(x) return x.id == best.id end)
  end))
  local srow = row_of(function(n) return n.type == 'session' and n.session.id == best.id end)
  local stop = gap_probe()
  t0 = vim.uv.hrtime()
  press_enter(srow)
  local ok = vim.wait(120000, function()
    local w = require('agent-ide.ui.chat')._windows().transcript
    local buf = w and vim.api.nvim_win_get_buf(w)
    return buf ~= nil and vim.api.nvim_buf_get_name(buf) == 'agent-ide://chat/' .. best.id
      and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= 'Loading…'
  end, 1)
  r.history = ms(t0)
  r.history_block = stop()
  if not ok then error('history never loaded') end
  return r
end

---Fresh child: the longest blocking stretch on the UI thread during a cold open.
---@return number milliseconds
function M.run_block(dir, backend, expected)
  setup(dir, backend)
  if require('agent-ide.index').backend() ~= backend then error('backend ' .. backend .. ' unavailable') end
  local stop = gap_probe()
  require('agent-ide').toggle()
  wait_projects(expected, 'cold block')
  return stop()
end

---Number of project rows the drawer should show for `dir` (Lua scan, run in a child).
function M.count_projects(dir)
  local done, n
  require('agent-ide.index.lua_scan').scan(dir, function(sessions)
    n = #require('agent-ide.project').group(sessions)
    done = true
  end)
  vim.wait(300000, function() return done end, 5)
  return n
end

-- Parent side ---------------------------------------------------------------------------

local function fresh_child()
  local child = MiniTest.new_child_neovim()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua('_G.BL = dofile(...)', { vim.fn.getcwd() .. '/tests/budget_lib.lua' })
  return child
end

local function best_of(runs, one, keys)
  local best
  for _ = 1, runs do
    local r = one()
    if not best then
      best = r
    else
      for _, k in ipairs(keys) do best[k] = math.min(best[k], r[k]) end
    end
  end
  return best
end

---Best of `runs` for each measurement (each run uses a fresh child Neovim).
---@return { cold: number, warm: number, history: number, history_block: number, block: number, backend: string, big_size: number }
function M.measure(dir, backend, expected, runs)
  local r = best_of(runs, function()
    local child = fresh_child()
    local ok, res = pcall(child.lua, 'local d, b, e = ...; return BL.run_open(d, b, e)', { dir, backend, expected })
    child.stop()
    if not ok then error(res, 0) end
    return res
  end, { 'cold', 'warm', 'history', 'history_block' })
  local b = best_of(runs, function()
    local child = fresh_child()
    local ok, res = pcall(child.lua, 'local d, b, e = ...; return { block = BL.run_block(d, b, e) }', { dir, backend, expected })
    child.stop()
    if not ok then error(res, 0) end
    return res
  end, { 'block' })
  r.block = b.block
  return r
end

---Backends usable here: 'lua' always, 'helper' when the binary is built.
---@return string[]
function M.backends()
  local list = { 'lua' }
  local helper = vim.fn.getcwd() .. '/helper/target/release/agent-ide-helper'
  if vim.uv.fs_stat(helper) then list[#list + 1] = 'helper' end
  return list
end

return M
