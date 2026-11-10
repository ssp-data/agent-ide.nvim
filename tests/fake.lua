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
  return { vim.v.progpath, '-l', root .. '/tests/fake_claude.lua', path }, log
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

---A synthetic `initialize` answer: models in Claude's shape (made-up names) and two commands.
---@return table
function M.init_answer()
  return {
    claude_code_version = '2.1.306',
    models = {
      { value = 'default', resolvedModel = 'claude-alpha-2', displayName = 'Default (recommended)',
        description = 'Alpha 2 for most work', supportsEffort = true },
      { value = 'alpha', resolvedModel = 'claude-alpha-2', displayName = 'Alpha 2', description = 'For hard problems' },
      { value = 'claude-alpha-3', resolvedModel = 'claude-alpha-3', displayName = 'Alpha 3', description = 'Newest and largest' },
      { value = 'beta', resolvedModel = 'claude-beta-1', displayName = 'Beta 1', description = 'Fast answers' },
      { value = 'claude-gamma-1-20250101', resolvedModel = 'claude-gamma-1-20250101', displayName = 'Gamma 1', description = 'Older' },
    },
    commands = { { name = 'compact', description = 'Compact', argumentHint = '' }, { name = 'review', description = 'Review' } },
    account = { email = 'someone@example.invalid' },
  }
end

---The plugin's `initialize` request (the first line of every process it starts)?
---@param line string raw input line
---@return boolean
function M.is_init(line) return line:find('"subtype":"initialize"', 1, true) ~= nil end

---Input lines the fake received, in order, without the `initialize` requests (decoded unless
---`raw`); the tests that care about `initialize` read `M.log` themselves.
---@param log_path string
---@param raw? boolean
---@return (table|string)[]
function M.ins(log_path, raw)
  local out = {}
  for _, l in ipairs(M.log(log_path)) do
    if l['in'] and not M.is_init(l['in']) then out[#out + 1] = raw and l['in'] or vim.json.decode(l['in']) end
  end
  return out
end

return M
