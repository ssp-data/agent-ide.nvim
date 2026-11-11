-- Small preferences the plugin remembers across restarts, in stdpath('state')/agent-ide/prefs.json:
-- { "version": 1, "model": <the model last used>, "legend": <true|false, the gL toggle> }.
-- Read once at setup; written atomically (util/jsonfile.lua) when a value changes.
local jsonfile = require('agent-ide.util.jsonfile')

local M = {}

local KEYS = { model = 'string', legend = 'boolean' }

local values = {} ---@type table<string, any>
local loaded = false

local function file() return vim.fn.stdpath('state') .. '/agent-ide/prefs.json' end

local function take(data)
  local out = {}
  if type(data) == 'table' then
    for k, t in pairs(KEYS) do
      if type(data[k]) == t and (t ~= 'string' or data[k] ~= '') then out[k] = data[k] end
    end
  end
  return out
end

---Read prefs.json (setup); a missing or corrupt file leaves every value unset.
function M.load()
  values = take((jsonfile.read(file())))
  loaded = true
end

---@param name 'model'|'legend'
---@return any
function M.get(name)
  if not loaded then M.load() end
  return values[name]
end

---Remember `value` for `name` (nil forgets it); written only when it changed.
---@param name 'model'|'legend'
---@param value any
function M.set(name, value)
  if not loaded then M.load() end
  if value ~= nil and (type(value) ~= KEYS[name] or value == '') then return end
  if values[name] == value then return end
  values[name] = value
  local data = { version = 1 }
  for k, v in pairs(values) do data[k] = v end
  local ok, err = jsonfile.write(file(), data)
  if not ok then vim.notify('Agent-IDE: cannot save prefs.json: ' .. tostring(err), vim.log.levels.WARN) end
end

---The model session `s` starts with, nil for Claude's own default: the one asked for or picked
---for it, else `claude.model` when set, else the model last used here (picked, or reported by
---a Claude this plugin started).
---@param s table Session
---@return string|nil
function M.start_model(s)
  -- `claude.model` and the remembered model are Claude's names: another agent's session starts
  -- with what was asked for or picked for it only
  if s.agent ~= nil and s.agent ~= 'claude' then return s.model_requested or s.model_chosen end
  local cfg = require('agent-ide.config').get().claude
  local fixed = type(cfg) == 'table' and type(cfg.model) == 'string' and cfg.model ~= '' and cfg.model or nil
  return s.model_requested or s.model_chosen or fixed or M.get('model')
end

---Test only: forget the values (the file stays).
function M._reset()
  values, loaded = {}, false
end

M._file = file

return M
