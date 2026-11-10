-- The coarse state of a Claude process read off its wire lines, for the keeper's json file and
-- the drawer of a Neovim that is not attached: `busy` after a prompt went in, `waiting` while a
-- control request of Claude's (a permission, a question) is open, `idle` after a result. Pure;
-- shared by the keeper (lua/agent-ide/keeper/main.lua) and its tests.
local M = {}

---@return { state: string, pending: table<string, boolean> }
function M.new() return { state = 'idle', pending = {} } end

local function decode(line)
  local ok, obj = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  return ok and type(obj) == 'table' and obj or nil
end

---One line went in (`dir` 'in': Neovim to Claude) or came out ('out': Claude to Neovim).
---@param st table from `new`
---@param dir 'in'|'out'
---@param line string
---@return boolean changed the state word changed
function M.step(st, dir, line)
  local obj = decode(line)
  if not obj then return false end
  local before = st.state
  if dir == 'in' then
    if obj.type == 'user' then
      st.state = 'busy'
    elseif obj.type == 'control_response' then
      local r = type(obj.response) == 'table' and obj.response or {}
      if r.request_id ~= nil then st.pending[r.request_id] = nil end
      if next(st.pending) == nil and st.state == 'waiting' then st.state = 'busy' end
    end
  else
    if obj.type == 'control_request' and obj.request_id ~= nil then
      local sub = type(obj.request) == 'table' and obj.request.subtype or nil
      if sub == 'can_use_tool' then
        st.pending[obj.request_id] = true
        st.state = 'waiting'
      end
    elseif obj.type == 'result' then
      st.pending = {}
      st.state = 'idle'
    end
  end
  return st.state ~= before
end

---True when `line` (an 'out' line) ends a turn.
---@param line string
---@return boolean
function M.ends_turn(line)
  local obj = decode(line)
  return obj ~= nil and obj.type == 'result'
end

return M
