-- Key options: every configurable lhs is a key, a list of keys, or false/nil (none).
local M = {}

---@param v string|string[]|false|nil
---@return string[] the keys (empty strings and non-strings left out)
function M.list(v)
  if type(v) == 'string' then return v ~= '' and { v } or {} end
  if type(v) == 'table' then return vim.tbl_filter(function(k) return type(k) == 'string' and k ~= '' end, v) end
  return {}
end

---The keys joined for a help line (`a / b`), nil when there are none.
---@param v string|string[]|false|nil
---@return string|nil
function M.label(v)
  local l = M.list(v)
  return #l > 0 and table.concat(l, ' / ') or nil
end

return M
