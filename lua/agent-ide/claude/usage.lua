-- Token counts of Claude's `usage` objects, and how the plugin prints them. Pure.
local M = {}

---The input of one request to the model: what the conversation weighed when that message
---was produced, cached or not. nil without a usable `usage`.
---@param u table|nil `message.usage` of an assistant message
---@return integer|nil
function M.context(u)
  if type(u) ~= 'table' then return nil end
  local n = 0
  for _, k in ipairs({ 'input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens' }) do
    if type(u[k]) == 'number' then n = n + u[k] end
  end
  return n > 0 and n or nil
end

---`850`, `1.2k`, `12k`, `123k`, `1.2M`.
---@param n number
---@return string
function M.fmt(n)
  local function unit(v, u)
    if v < 9.95 then return (('%.1f'):format(v):gsub('%.0$', '') .. u) end
    return ('%d%s'):format(math.floor(v + 0.5), u)
  end
  if n >= 1e6 then return unit(n / 1e6, 'M') end
  if n >= 1e3 then return unit(n / 1e3, 'k') end
  return tostring(math.floor(n))
end

return M
