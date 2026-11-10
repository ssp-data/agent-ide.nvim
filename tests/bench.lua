-- `make bench`: speed budgets of the spec (section 9.1), one row per measurement and backend.
-- Synthetic data by default. `make bench DIR=~/.claude/projects` measures a real directory and
-- prints timings and counts only (no titles, paths or content).
local lib = dofile(vim.fn.getcwd() .. '/tests/budget_lib.lua')

local real = vim.env.BENCH_DIR
local root, dir
if real and real ~= '' then
  dir = vim.fn.fnamemodify(real, ':p'):gsub('/$', '')
else
  root = vim.fn.tempname()
  dir = lib.generate(root)
end

local ok, err = pcall(function()
  local child = MiniTest.new_child_neovim()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua('_G.BL = dofile(...)', { vim.fn.getcwd() .. '/tests/budget_lib.lua' })
  local expected = child.lua_get('BL.count_projects(...)', { dir })
  child.stop()

  local runs = root and 5 or 3
  local rows = {}
  for _, backend in ipairs(lib.backends()) do
    local r = lib.measure(dir, backend, expected, runs)
    local function row(name, value, budget)
      rows[#rows + 1] = { name, backend, value, budget }
    end
    row('(a) warm drawer open', r.warm, 50)
    row('(b) cold drawer open', r.cold, nil)
    row('(c) history open, ' .. math.floor(r.big_size / 1024) .. ' KB', r.history, 150)
    row('(d) longest cold-scan block', r.block, 16)
    row('(d2) longest block, history open', r.history_block, nil)
  end
  print(string.format('projects: %d, runs per row: %d (best)', expected, runs))
  print(string.format('%-36s %-7s %10s %10s', 'measurement', 'backend', 'ms', 'budget'))
  for _, r in ipairs(rows) do
    print(string.format('%-36s %-7s %10.1f %10s', r[1], r[2], r[3], r[4] and ('< ' .. r[4]) or '-'))
  end
end)
if root then vim.fn.delete(root, 'rf') end
if not ok then
  io.stderr:write(tostring(err) .. '\n')
  vim.cmd('cquit 1')
end
