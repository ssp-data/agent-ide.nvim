-- Hidden sessions: ids the user moved out of a project's main rows into its `Hidden (n)` group
-- (`H` in the drawer). Nothing is deleted; search still finds them. Kept in
-- stdpath('data')/agent-ide/hidden.json: { "version": 1, "ids": { "<session id>": true } }.
local jsonfile = require('agent-ide.util.jsonfile')

local M = {}

local ids = {} -- session id -> true
local stamp -- of the file as last read or written; nil until loaded

local function file() return vim.fn.stdpath('data') .. '/agent-ide/hidden.json' end

local function take(data)
  ids = {}
  local list = type(data) == 'table' and data.ids
  if type(list) ~= 'table' then return end
  for id, v in pairs(list) do
    if type(id) == 'string' and v == true then ids[id] = true end
  end
end

---Read the file (a missing or corrupt one: nothing hidden).
function M.load()
  local data
  data, stamp = jsonfile.read(file())
  take(data)
end

---Read the file again when another Neovim changed it since.
---@return boolean changed
function M.refresh()
  if stamp == nil then
    M.load()
    return true
  end
  if jsonfile.stamp(file()) == stamp then return false end
  M.load()
  return true
end

---@param id string
---@return boolean
function M.is(id)
  if stamp == nil then M.load() end
  return ids[id] == true
end

---@return boolean some session is hidden
function M.any()
  if stamp == nil then M.load() end
  return next(ids) ~= nil
end

---Hide (`true`) or show again (`false`) session `id`. Another Neovim's changes since the last
---read are kept: only this one change is applied to what the file holds now.
---@param id string
---@param hide boolean
---@return boolean ok, string|nil err
function M.set(id, hide)
  M.refresh()
  ids[id] = hide and true or nil
  local out = next(ids) and vim.deepcopy(ids) or vim.empty_dict()
  local new, err = jsonfile.write(file(), { version = 1, ids = out })
  if not new then
    vim.notify('Agent-IDE: cannot save hidden sessions: ' .. tostring(err), vim.log.levels.WARN)
    return false, err
  end
  stamp = new
  return true
end

---Test only: forget what was read.
function M._reset() ids, stamp = {}, nil end

return M
