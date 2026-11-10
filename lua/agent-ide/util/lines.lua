-- Linear line splitting of a chunked byte stream. Only the new chunk is searched for
-- newlines and the pieces of a long line are joined once, when its newline arrives.
local M = {}

local Splitter = {}
Splitter.__index = Splitter

---@return table splitter
function M.splitter() return setmetatable({ parts = {} }, Splitter) end

---Feed a chunk; `fn(line)` is called for each complete line (without its newline).
---`fn` returning true stops the processing of this chunk (the rest is dropped, buffer cleared).
---@param data string
---@param fn fun(line: string): boolean|nil
function Splitter:push(data, fn)
  local parts = self.parts
  local s = 1
  while true do
    local nl = data:find('\n', s, true)
    if not nl then break end
    local line = data:sub(s, nl - 1)
    if #parts > 0 then
      parts[#parts + 1] = line
      line = table.concat(parts)
      parts = {}
      self.parts = parts
    end
    if fn(line) then
      self.parts = {}
      return
    end
    s = nl + 1
  end
  if s <= #data then parts[#parts + 1] = data:sub(s) end
end

---The incomplete last line, if any; clears the buffer.
---@return string|nil
function Splitter:take_rest()
  local rest = #self.parts > 0 and table.concat(self.parts) or nil
  self.parts = {}
  return rest
end

function Splitter:reset() self.parts = {} end

return M
