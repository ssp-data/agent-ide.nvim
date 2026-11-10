-- Speed budgets of the spec (section 9.1). Synthetic data, best of 5 runs per measurement.
local lib = dofile(vim.fn.getcwd() .. '/tests/budget_lib.lua')
local RUNS = 5

local root, dir
local results = {}

local T = MiniTest.new_set({ hooks = {
  pre_once = function()
    root = vim.fn.tempname()
    dir = lib.generate(root)
  end,
  -- also runs after failed assertions
  post_once = function() if root then vim.fn.delete(root, 'rf') end end,
} })

local function measure(backend)
  results[backend] = results[backend] or lib.measure(dir, backend, 60, RUNS)
  return results[backend]
end

local function check(name, value, budget)
  if value >= budget then
    error(string.format('%s: %.1f ms, budget < %d ms', name, value, budget), 0)
  end
end

for _, backend in ipairs(lib.backends()) do
  T['warm drawer open under 50 ms (' .. backend .. ')'] = function()
    check('warm drawer open', measure(backend).warm, 50)
  end
end

-- Project scope (scope.lua) with 60 projects on disk: the warm open stays in budget and a
-- re-render is not slower than in all scope (0.2 ms of slack for timer noise).
for _, backend in ipairs(lib.backends()) do
  T['project scope: warm drawer open under 50 ms, render not slower than all (' .. backend .. ')'] = function()
    local best
    for _ = 1, RUNS do
      local child = MiniTest.new_child_neovim()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua('_G.BL = dofile(...)', { vim.fn.getcwd() .. '/tests/budget_lib.lua' })
      local ok, r = pcall(child.lua, 'local d, b, e = ...; return BL.run_scoped(d, b, e)', { dir, backend, 60 })
      child.stop()
      if not ok then error(r, 0) end
      if not best then best = r else
        for k, v in pairs(r) do best[k] = math.min(best[k], v) end
      end
    end
    check('project scope warm drawer open', best.warm, 50)
    if best.project_render > best.all_render + 0.2 then
      error(string.format('project scope render %.2f ms, all scope %.2f ms', best.project_render, best.all_render), 0)
    end
  end
end

T['1 MB history under 150 ms with helper'] = function()
  if not vim.tbl_contains(lib.backends(), 'helper') then
    return MiniTest.skip('helper not built (make helper)')
  end
  local r = measure('helper')
  assert(r.big_size >= 1024 * 1024, 'history session should be at least 1 MB')
  check('1 MB history', r.history, 150)
end

-- A transcript with huge single lines (pasted screenshots, long tool inputs) opens as fast as
-- any other, and the buffer holds no line that could choke wrapping or highlighting.
local function long_line_session(root)
  local dir = root .. '/projects/-home-u-synthetic-longlines'
  vim.fn.mkdir(dir, 'p')
  local cwd = '/home/u/synthetic/longlines'
  local lines = {}
  local function add(rec) lines[#lines + 1] = vim.json.encode(rec) end
  add({ type = 'user', uuid = 'u0', cwd = cwd, message = { role = 'user', content = 'Synthetic long lines' } })
  for n = 1, 3 do
    add({ type = 'user', uuid = 'i' .. n, cwd = cwd, message = { role = 'user', content = {
      { type = 'image', source = { type = 'base64', media_type = 'image/png', data = string.rep('QUJD', 125000) } } } } })
  end
  for n = 1, 10 do
    add({ type = 'assistant', uuid = 'a' .. n, cwd = cwd, message = { role = 'assistant', content = {
      { type = 'tool_use', id = 't' .. n, name = 'Write',
        input = { file_path = '/x/' .. n, content = string.rep('w', 40000) } } } } })
    add({ type = 'user', uuid = 'r' .. n, cwd = cwd, message = { role = 'user', content = {
      { type = 'tool_result', tool_use_id = 't' .. n, content = 'ok' } } } })
  end
  local id = 'eeeeeeee-0000-4000-8000-000000000001'
  vim.fn.writefile(lines, dir .. '/' .. id .. '.jsonl')
  return root .. '/projects', id
end

-- Runs in a fresh child: milliseconds until the session's chat buffer shows, and its longest line.
local function open_long_session(dir, id)
  vim.env.TMUX = nil
  require('agent-ide').setup({
    projects_dir = dir,
    helper = { enabled = true },
    live = { interval_ms = 600000, cmd = { 'echo', '[]' } },
    icons_style = 'plain', icons = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.' },
    keys = false,
  })
  if require('agent-ide.index').backend() ~= 'helper' then error('helper unavailable') end
  local drawer = require('agent-ide.ui.drawer')
  require('agent-ide').toggle()
  if not vim.wait(60000, function() return #(drawer.state().projects or {}) == 1 end, 1) then error('no project') end
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
  press_enter(row_of(function(n) return n.type == 'project' end))
  local srow = row_of(function(n) return n.type == 'session' and n.session.id == id end)
  local t0 = vim.uv.hrtime()
  press_enter(srow)
  local buf
  local ok = vim.wait(120000, function()
    local w = require('agent-ide.ui.chat')._windows().transcript
    buf = w and vim.api.nvim_win_get_buf(w)
    return buf ~= nil and vim.api.nvim_buf_get_name(buf) == 'agent-ide://chat/' .. id
      and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= 'Loading…'
  end, 1)
  local elapsed = (vim.uv.hrtime() - t0) / 1e6
  if not ok then error('history never loaded') end
  local longest = 0
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do longest = math.max(longest, #l) end
  return { ms = elapsed, longest = longest }
end

T['history with huge single lines under 150 ms with helper, no line over 20100 bytes'] = function()
  if not vim.tbl_contains(lib.backends(), 'helper') then
    return MiniTest.skip('helper not built (make helper)')
  end
  local lroot = vim.fn.tempname()
  local dir2, id = long_line_session(lroot)
  local best, longest = math.huge, 0
  for _ = 1, RUNS do
    local child = MiniTest.new_child_neovim()
    child.restart({ '-u', 'tests/minimal_init.lua' })
    child.lua('_G.OPEN = loadstring(...)', { string.dump(open_long_session) })
    local ok, r = pcall(child.lua, 'return OPEN(...)', { dir2, id })
    child.stop()
    if not ok then
      vim.fn.delete(lroot, 'rf')
      error(r, 0)
    end
    best, longest = math.min(best, r.ms), math.max(longest, r.longest)
  end
  vim.fn.delete(lroot, 'rf')
  assert(longest <= 20100, 'longest buffer line: ' .. longest .. ' bytes')
  check('history with huge single lines', best, 150)
end

T['cold Lua scan never blocks the UI longer than 16 ms'] = function()
  check('cold Lua scan block', measure('lua').block, 16)
end

return T
