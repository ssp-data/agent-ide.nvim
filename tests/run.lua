-- Headless test runner: always terminates; exit 0 only if every collected case passed.
-- Verified against mini.nvim f9ac12d (deps/mini.nvim).
-- The stock stdout reporter quits on `exec.fails` alone, which misses cases whose
-- error handler itself fails (e.g. a Lua stack overflow). So we do not let it quit
-- and judge each case ourselves: it must have run and ended in a pass state.
-- Isolation: every test Neovim (this one and its children) gets a temporary data folder, so the
-- plugin's own data (saved prompts, the default library) is never the user's.
vim.env.XDG_DATA_HOME = vim.fn.tempname() .. '-data'

local reporter = MiniTest.gen_reporter.stdout({ quit_on_finish = false })
local finish = reporter.finish
reporter.finish = function()
  finish()
  local cases = MiniTest.current.all_cases or {}
  local ok = #cases > 0
  for _, case in ipairs(cases) do
    local exec = case.exec
    local state = exec and exec.state
    if not exec or #exec.fails > 0 or (state ~= 'Pass' and state ~= 'Pass with notes') then
      io.stdout:write('NOT PASSED: ' .. vim.inspect(case.desc) .. ' state=' .. tostring(state) .. '\n')
      ok = false
    end
  end
  vim.cmd(ok and 'qall!' or 'cquit 1')
end

-- mini.test silently passes a case that dies with a Lua stack overflow (its error
-- handler overflows too, so no fail is recorded). Catch errors at the case boundary,
-- where the stack is shallow, and re-raise them so they are recorded normally.
local function filter_cases(case)
  local test = case.test
  case.test = function(...)
    local ok, e = pcall(test, ...)
    if not ok then error(tostring(e), 0) end
  end
  return true
end

local ok, err = pcall(MiniTest.run, { collect = { filter_cases = filter_cases }, execute = { reporter = reporter } })
if not ok then
  io.stderr:write(tostring(err) .. '\n')
  vim.cmd('cquit 1')
end
