-- Session names: a label of your own for a session (`r` on its drawer row), shown instead of
-- Claude's title in the drawer, the chat's winbar, the buffer names, search and the footer.
-- Claude's files are never touched: the mapping lives in stdpath('data')/agent-ide/names.json:
-- { "version": 1, "names": { "<session id>": "<name>" } }. Several Neovims share it.
local jsonfile = require('agent-ide.util.jsonfile')

local M = {}

local names = {} -- session id -> name
local stamp -- of the file as last read or written; nil until loaded

local function file() return vim.fn.stdpath('data') .. '/agent-ide/names.json' end

local function take(data)
  names = {}
  local list = type(data) == 'table' and data.names
  if type(list) ~= 'table' then return end
  for id, v in pairs(list) do
    if type(id) == 'string' and type(v) == 'string' and v ~= '' then names[id] = v end
  end
end

---Read the file (a missing or corrupt one: no names).
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
---@return string|nil
function M.get(id)
  if stamp == nil then M.load() end
  return names[id]
end

---@return boolean some session has a name
function M.any()
  if stamp == nil then M.load() end
  return next(names) ~= nil
end

---Name session `id` (`nil` or empty: Claude's title again). Another Neovim's changes since the
---last read are kept: only this one change is applied to what the file holds now.
---@param id string
---@param name string|nil
---@return boolean ok, string|nil err
function M.set(id, name)
  M.refresh()
  names[id] = (name and name ~= '') and name or nil
  local out = next(names) and vim.deepcopy(names) or vim.empty_dict()
  local new, err = jsonfile.write(file(), { version = 1, names = out })
  if not new then
    vim.notify('Agent-IDE: cannot save session names: ' .. tostring(err), vim.log.levels.WARN)
    return false, err
  end
  stamp = new
  return true
end

---The projects with every named session's `title` replaced by its name (`raw_title` keeps
---Claude's). Unchanged tables come back as they are; a project with a named session is a
---shallow copy with copied session entries.
---@param projects table[]
---@return table[]
function M.with(projects)
  if not M.any() then return projects end
  local out = projects
  for i, p in ipairs(projects) do
    local sessions
    for j, m in ipairs(p.sessions or {}) do
      local name = names[m.id]
      if name then
        sessions = sessions or vim.list_slice(p.sessions)
        local copy = {}
        for k, v in pairs(m) do copy[k] = v end
        copy.title, copy.raw_title = name, m.title
        sessions[j] = copy
      end
    end
    if sessions then
      if out == projects then out = vim.list_slice(projects) end
      out[i] = setmetatable({ sessions = sessions }, { __index = p })
    end
  end
  return out
end

---Test only: forget what was read.
function M._reset() names, stamp = {}, nil end

return M
