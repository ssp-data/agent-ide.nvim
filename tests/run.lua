-- Headless test runner: always terminates; exit 0 only if every collected case passed.
-- Verified against mini.nvim f9ac12d (deps/mini.nvim).
-- The stock stdout reporter quits on `exec.fails` alone, which misses cases whose
-- error handler itself fails (e.g. a Lua stack overflow). So we do not let it quit
-- and judge each case ourselves: it must have run and ended in a pass state.
-- Isolation: every test Neovim (this one and its children) gets temporary data, cache, state and
-- runtime folders, so the plugin's own files (saved prompts, the default library, the index cache,
-- quota.json, the per-Neovim status files a desktop bar reads) are never the user's.
local xdg_root = vim.fn.tempname() .. '-xdg'
local data_home = xdg_root .. '/data'
for name, sub in pairs({ XDG_DATA_HOME = 'data', XDG_CACHE_HOME = 'cache', XDG_STATE_HOME = 'state', XDG_RUNTIME_DIR = 'run' }) do
  local d = xdg_root .. '/' .. sub
  vim.fn.mkdir(d, 'p', tonumber('700', 8))
  vim.uv.os_setenv(name, d)
end

-- Keepers (lua/agent-ide/keeper) outlive the Neovim that started them on purpose; between cases
-- and at the end the ones of this run are ended with their fake Claudes.
local function kill_keepers()
  local dir = xdg_root .. '/run/agent-ide'
  for _, f in ipairs(vim.fn.glob(dir .. '/keeper-*.json', false, true)) do
    local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(f), '\n'))
    if ok and type(data) == 'table' and type(data.keeper_pid) == 'number' then
      pcall(vim.uv.kill, data.keeper_pid, 15)
      if type(data.claude_pid) == 'number' then pcall(vim.uv.kill, data.claude_pid, 15) end
    end
    vim.fn.delete(f)
  end
  for _, f in ipairs(vim.fn.glob(dir .. '/keeper-*.sock', false, true)) do vim.fn.delete(f) end
  if package.loaded['agent-ide.keeper'] then package.loaded['agent-ide.keeper']._reset() end
end

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
  kill_keepers()
  vim.fn.delete(xdg_root, 'rf')
  vim.cmd(ok and 'qall!' or 'cquit 1')
end

-- mini.test silently passes a case that dies with a Lua stack overflow (its error
-- handler overflows too, so no fail is recorded). Catch errors at the case boundary,
-- where the stack is shallow, and re-raise them so they are recorded normally.
local function filter_cases(case)
  local test = case.test
  case.test = function(...)
    -- prefs.json (the model last used, the legend toggle) is kept across restarts on purpose;
    -- between cases it would leak one case's choices into the next
    vim.fn.delete(xdg_root .. '/state/nvim/agent-ide/prefs.json')
    if package.loaded['agent-ide.prefs'] then package.loaded['agent-ide.prefs']._reset() end
    kill_keepers()
    local ok, e = pcall(test, ...)
    if not ok then error(tostring(e), 0) end
  end
  return true
end

-- TEST_FILE=tests/test_x.lua (optional) runs one file; TEST_CASE=<text> only cases whose name has it.
local only_file, only_case = vim.env.TEST_FILE, vim.env.TEST_CASE
local collect = { filter_cases = function(case)
  if only_case and not table.concat(case.desc, ' '):find(only_case, 1, true) then return false end
  return filter_cases(case)
end }
if only_file and only_file ~= '' then collect.find_files = function() return { only_file } end end
local ok, err = pcall(MiniTest.run, { collect = collect, execute = { reporter = reporter } })
if not ok then
  io.stderr:write(tostring(err) .. '\n')
  vim.cmd('cquit 1')
end
