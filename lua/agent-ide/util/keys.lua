-- Key options: every configurable lhs is a key, a list of keys, or false/nil (none).
local M = {}

---@param v string|string[]|false|nil
---@return string[] the keys (empty strings and non-strings left out)
function M.list(v)
  if type(v) == 'string' then return v ~= '' and { v } or {} end
  if type(v) == 'table' then return vim.tbl_filter(function(k) return type(k) == 'string' and k ~= '' end, v) end
  return {}
end

---The keys of option `name` in `config.keys[group]` (`group` nil: a global key), as `M.list`.
---@param group string|nil
---@param name string
---@return string[]
function M.get(group, name)
  local keys = require('agent-ide.config').get().keys
  if type(keys) ~= 'table' then return {} end
  local g = group and keys[group] or keys
  return type(g) == 'table' and M.list(g[name]) or {}
end

---The first key of option `name` in `config.keys[group]` for a hint in a message, or `none`.
---@param group string|nil
---@param name string
---@param none? string default '(no key)'
---@return string
function M.first(group, name, none) return M.get(group, name)[1] or none or '(no key)' end

---The keys joined for a help line (`a / b`), nil when there are none.
---@param v string|string[]|false|nil
---@return string|nil
function M.label(v)
  local l = M.list(v)
  return #l > 0 and table.concat(l, ' / ') or nil
end

return M
