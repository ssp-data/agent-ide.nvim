-- Headless test runner: always exits (0 = all passed, 1 = failure or load error).
local ok, err = pcall(MiniTest.run)
if not ok then
  io.stderr:write(tostring(err) .. '\n')
  vim.cmd('cquit 1')
end
local failed = false
for _, case in ipairs(MiniTest.current.all_cases or {}) do
  local s = case.exec and case.exec.state or ''
  if s:find('Fail') then failed = true end
end
vim.cmd(failed and 'cquit 1' or 'qall!')
