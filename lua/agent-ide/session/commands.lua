-- Claude's command list for the `/` menu of a session that has not had a turn yet (Claude sends
-- the list with each turn's `init` event): the last list seen for the same project, else the most
-- recent one of any project. Kept across restarts in stdpath('state')/agent-ide/commands.json:
-- { "version": 1, "projects": { "<project key>": { "at": <epoch>, "commands": [ ... ] } } }.
-- A project key is a short hash of the project's git root (else its folder), not the path.
-- Read once at setup (asynchronously); nothing here reads a file on a keystroke.
local jsonfile = require('agent-ide.util.jsonfile')

local M = {}

M.MAX_PROJECTS = 50

local projects = {} -- key -> { at, commands }
local stamp -- of the file as last read or written; nil until read
local keys = {} -- cwd -> project key
local newest -- key of the most recent entry (nil: compute)

local function file() return vim.fn.stdpath('state') .. '/agent-ide/commands.json' end

-- Valid entries of a decoded file.
local function take(data)
  local out = {}
  local list = type(data) == 'table' and data.projects
  if type(list) ~= 'table' then return out end
  for k, e in pairs(list) do
    if type(k) == 'string' and type(e) == 'table' and type(e.commands) == 'table' and tonumber(e.at) then
      local cmds = vim.tbl_filter(function(c) return type(c) == 'string' end, e.commands)
      out[k] = { at = tonumber(e.at), commands = cmds }
    end
  end
  return out
end

---Project key of folder `cwd`: a hash of its git root, else of the folder (cached per folder).
---@param cwd string
---@return string
function M.key_of(cwd)
  local k = keys[cwd]
  if k then return k end
  local root = require('agent-ide.project').git_root(cwd, vim.uv.os_homedir() or '')
  k = vim.fn.sha256(root or cwd):sub(1, 16)
  keys[cwd] = k
  return k
end

---Read the file, asynchronously (setup). Lists recorded meanwhile win over the file's.
---@param cb? fun()
function M.load(cb)
  jsonfile.read_async(file(), function(data, st)
    local mine = projects
    projects = take(data)
    for k, e in pairs(mine) do
      if not projects[k] or projects[k].at <= e.at then projects[k] = e end
    end
    stamp, newest = st, nil
    if cb then cb() end
  end)
end

-- Drop the oldest entries beyond MAX_PROJECTS.
local function cap(list)
  local all = {}
  for k, e in pairs(list) do all[#all + 1] = { k = k, at = e.at } end
  if #all <= M.MAX_PROJECTS then return end
  table.sort(all, function(a, b)
    if a.at ~= b.at then return a.at > b.at end
    return a.k < b.k
  end)
  for i = M.MAX_PROJECTS + 1, #all do list[all[i].k] = nil end
end

local function write(key, entry)
  -- another Neovim wrote since: apply only this change onto what the file holds now
  if stamp == nil or jsonfile.stamp(file()) ~= stamp then
    local fresh = take((jsonfile.read(file())))
    for k, e in pairs(projects) do
      if not fresh[k] or fresh[k].at < e.at then fresh[k] = e end
    end
    projects = fresh
  end
  projects[key] = entry
  cap(projects)
  newest = nil
  local new, err = jsonfile.write(file(), { version = 1, projects = next(projects) and projects or vim.empty_dict() })
  if not new then
    return vim.notify('Agent-IDE: cannot save the command list: ' .. tostring(err), vim.log.levels.WARN)
  end
  stamp = new
end

---Claude reported `list` for a session in `cwd` (an `init` event). Written (soon) only when the
---project's list changed.
---@param cwd string
---@param list string[]
function M.record(cwd, list)
  if type(list) ~= 'table' or #list == 0 then return end
  local key = M.key_of(cwd)
  local old = projects[key]
  local entry = { at = os.time(), commands = vim.deepcopy(list) }
  if old and vim.deep_equal(old.commands, entry.commands) then
    old.at = entry.at -- the most recent one in memory; the file is not rewritten for this
    newest = nil
    return
  end
  projects[key] = entry
  newest = nil
  vim.schedule(function() write(key, entry) end)
end

---The list to offer a session in `cwd` that has none of its own: its project's, else the most
---recently seen of any project; nil when none is known.
---@param cwd string|nil
---@return string[]|nil
function M.fallback(cwd)
  local e = cwd and projects[M.key_of(cwd)]
  if e then return e.commands end
  if newest == nil then
    local best
    for k, x in pairs(projects) do
      if not best or x.at > projects[best].at or (x.at == projects[best].at and k < best) then best = k end
    end
    newest = best or false
  end
  return newest and projects[newest].commands or nil
end

---Test only: forget everything read or recorded (the file stays).
function M._reset() projects, stamp, keys, newest = {}, nil, {}, nil end

return M
