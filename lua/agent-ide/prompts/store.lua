-- Library and saved-prompt files: origins of prompt buffers, naming rules, atomic writes that
-- never clobber another prompt, rename and delete. Never writes under a `.claude` folder.
local uv = vim.uv

local M = {}

-- Origins ------------------------------------------------------------------------------------

---Change stamp of a file (mtime and size); nil when it is gone.
---@param path string
---@return string|nil
function M.stamp(path)
  local st = uv.fs_stat(path)
  return st and (st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.size) or nil
end

---Where the text of prompt buffer `buf` came from: nil for a fresh prompt.
---@param buf integer
---@return { kind: string, path: string, stamp: string }|nil
function M.origin(buf)
  local o = vim.b[buf].agent_ide_origin
  return type(o) == 'table' and o or nil
end

---Remember (or forget, `e` nil) the file the text of `buf` came from.
---@param buf integer
---@param e table|nil PromptEntry or { kind, path }
function M.set_origin(buf, e)
  vim.b[buf].agent_ide_origin = e and { kind = e.kind, path = e.path, stamp = M.stamp(e.path) or '' } or nil
end

return M
