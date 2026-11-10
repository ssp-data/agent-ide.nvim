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

T['1 MB history under 150 ms with helper'] = function()
  if not vim.tbl_contains(lib.backends(), 'helper') then
    return MiniTest.skip('helper not built (make helper)')
  end
  local r = measure('helper')
  assert(r.big_size >= 1024 * 1024, 'history session should be at least 1 MB')
  check('1 MB history', r.history, 150)
end

T['cold Lua scan never blocks the UI longer than 16 ms'] = function()
  check('cold Lua scan block', measure('lua').block, 16)
end

return T
