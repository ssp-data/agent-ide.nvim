-- The part of two lines that differs: the common prefix and suffix are left out, on character
-- boundaries. Used to mark the changed text inside a modified line (an `Edit` fold, the full
-- diff without delta).
local M = {}

local function continuation(byte) return byte ~= nil and byte >= 0x80 and byte < 0xC0 end

---The common prefix and suffix lengths (bytes) of `a` and `b`; nil when the lines have nothing
---in common or nothing different (nothing worth singling out).
---@param a string
---@param b string
---@return integer|nil prefix, integer|nil suffix
function M.changed(a, b)
  local la, lb = #a, #b
  local p = 0
  while p < la and p < lb and a:byte(p + 1) == b:byte(p + 1) do p = p + 1 end
  while p > 0 and continuation(a:byte(p + 1)) do p = p - 1 end
  local s = 0
  while s < la - p and s < lb - p and a:byte(la - s) == b:byte(lb - s) do s = s + 1 end
  while s > 0 and continuation(a:byte(la - s + 1)) do s = s - 1 end
  if p + s == 0 or (p + s >= la and p + s >= lb) then return nil end
  return p, s
end

return M
