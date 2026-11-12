-- Session registry: every Session of this Neovim, change listeners, the latest quota.
-- The Session object itself is in session/object.lua.
local object = require('agent-ide.session.object')

local M = {}

local by_id, order = {}, {}
local forgotten = {} -- id -> Session dropped by `forget` (reused when the id is opened again)
local listeners, broken = {}, {} -- broken: listeners that raised (reported once)
local last_quota

---Random UUID v4.
---@return string
local function uuid()
  local ok, bytes = pcall(vim.uv.random, 16)
  if not ok or type(bytes) ~= 'string' or #bytes ~= 16 then
    local f = assert(io.open('/dev/urandom', 'rb'))
    bytes = f:read(16)
    f:close()
  end
  local b = { bytes:byte(1, 16) }
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  local hex = {}
  for i = 1, 16 do hex[i] = string.format('%02x', b[i]) end
  local h = table.concat(hex)
  return ('%s-%s-%s-%s-%s'):format(h:sub(1, 8), h:sub(9, 12), h:sub(13, 16), h:sub(17, 20), h:sub(21, 32))
end

---Internal: tell the listeners. Sessions dropped by `_reset` (late callbacks of an old
---process) tell no one.
function M._emit(s, what)
  if by_id[s.id] ~= s then return end
  for _, fn in ipairs(vim.list_slice(listeners)) do
    local ok, err = pcall(fn, s, what)
    if not ok and not broken[fn] then
      broken[fn] = true
      vim.notify('agent-ide: error in session listener: ' .. tostring(err), vim.log.levels.WARN)
    end
  end
end

---Internal: store the latest quota windows.
function M._set_quota(windows) last_quota = windows end

---@param opts { id?: string, cwd: string, path?: string, title?: string }
---@return table session
function M.open(opts)
  local s = opts.id and by_id[opts.id]
  if s then
    s.path = s.path or opts.path
    s.title = s.title or opts.title
    return s
  end
  s = opts.id and forgotten[opts.id]
  if s then
    -- a deleted session restored from the trash: the same object (a chat may still refer to
    -- it), its history read again
    forgotten[opts.id] = nil
    local fresh = object.new(opts, opts.id)
    for k in pairs(s) do s[k] = nil end
    for k, v in pairs(fresh) do s[k] = v end
  else
    s = object.new(opts, opts.id or uuid())
  end
  by_id[s.id] = s
  order[#order + 1] = s
  return s
end

---Drop session `id`, which has no process here (its files were deleted).
---@param id string
function M.forget(id)
  local s = by_id[id]
  if not s or s:_alive() then return end
  by_id[id] = nil
  for i, x in ipairs(order) do
    if x == s then table.remove(order, i); break end
  end
  forgotten[id] = s
end

---@param id string
---@return table|nil
function M.get(id) return by_id[id] end

---@return table[] sessions in creation order
function M.all() return vim.list_slice(order) end

---`control_error`: Claude refused a mode or model change; `session.control_error` holds
---`{ what = 'mode'|'model', value, error }`.
---@param fn fun(session: table, what: 'state'|'events'|'delta'|'meta'|'permission'|'quota'|'control_error'|'activity')
function M.on_change(fn) listeners[#listeners + 1] = fn end

---@param fn function
function M.off_change(fn)
  for i, f in ipairs(listeners) do
    if f == fn then table.remove(listeners, i); return end
  end
end

---@return table|nil windows latest quota: name -> { utilization, resets_at }
function M.quota() return last_quota end

---Test only: stop every process, forget all sessions and listeners.
function M._reset()
  for _, s in ipairs(order) do
    if s.proc then s.proc:stop(nil, true) end
  end
  by_id, order, listeners, broken, forgotten = {}, {}, {}, {}, {}
  last_quota = nil
  require('agent-ide.session.commands')._reset()
  require('agent-ide.claude.models')._reset()
  require('agent-ide.ui.mode')._reset()
  object._reset_ids()
end

return M
