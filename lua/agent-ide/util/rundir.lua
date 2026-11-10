-- The plugin's runtime folder: `$XDG_RUNTIME_DIR/agent-ide` (else `stdpath('run')/agent-ide`),
-- for files that live as long as the processes that write them (status files, keepers).
local M = {}

---@return string
function M.dir()
  local base = vim.uv.os_getenv('XDG_RUNTIME_DIR')
  if not base or base == '' then base = vim.fn.stdpath('run') end
  return base .. '/agent-ide'
end

---Create `dir` as 0700 when missing (the mode of an existing one is tightened by status.lua).
---@param dir string
---@return boolean
function M.ensure(dir)
  if vim.fn.isdirectory(dir) == 1 then return true end
  local ok = pcall(vim.fn.mkdir, dir, 'p', 448)
  return ok and vim.fn.isdirectory(dir) == 1
end

return M
