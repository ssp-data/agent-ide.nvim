-- Test helper for the scriptable fake Claude (see tests/fake_claude.lua).
local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

---Write the scenario (list of JSON strings or tables) and return the value for
---`config.claude.cmd` plus the path of the log file the fake appends to.
---The log path is exported to the fake through env FAKE_CLAUDE_LOG (set on this Neovim).
---@param scenario_lines (string|table)[]
---@return string[] cmd, string log_path
function M.cmd(scenario_lines)
  local path, log = vim.fn.tempname() .. '.jsonl', vim.fn.tempname() .. '.log'
  local out = {}
  for i, l in ipairs(scenario_lines) do out[i] = type(l) == 'string' and l or vim.json.encode(l) end
  vim.fn.writefile(out, path)
  vim.uv.os_setenv('FAKE_CLAUDE_LOG', log)
  return { 'nvim', '-l', root .. '/tests/fake_claude.lua', path }, log
end

---@param log_path string
---@return table[] decoded log lines (empty when the file does not exist yet)
function M.log(log_path)
  if vim.fn.filereadable(log_path) == 0 then return {} end
  local out = {}
  for _, l in ipairs(vim.fn.readfile(log_path, 'b')) do
    if l ~= '' then out[#out + 1] = vim.json.decode(l) end
  end
  return out
end

return M
