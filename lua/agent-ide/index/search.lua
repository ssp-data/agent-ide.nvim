-- Search facade: the helper's index when the helper backend is in use, else the limited Lua
-- search (titles and prompts, exact matching). Both answer with the same hit shape:
-- { session, path, cwd, project, title, kind, event|nil, ts|nil, snippet, positions, match }.
-- Results carry `backend` ('helper' | 'lua') and `limited` (true for the Lua search).
local helper = require('agent-ide.index.helper')
local index = require('agent-ide.index')
local lua_scan = require('agent-ide.index.lua_scan')
local search_lua = require('agent-ide.index.search_lua')
local render = require('agent-ide.transcript.render')

local M = {}

local listeners = {}
local hooked = false

local function ready()
  for _, fn in ipairs(listeners) do pcall(fn) end
end

local function hook()
  if hooked then return end
  hooked = true
  helper.on('search_ready', ready)
  search_lua.on_ready(ready)
end

local function projects_dir() return require('agent-ide.config').get().projects_dir end

---@return 'helper'|'lua'
function M.backend() return index.backend() end

---@param params { query: string, scope?: string|table, kinds?: string[], limit?: integer, projects?: table, projects_dir?: string }
---@param cb fun(result: { hits: table[], indexing: boolean, backend: string, limited: boolean, sessions: integer })
function M.search(params, cb)
  hook()
  params = vim.tbl_extend('keep', params, { projects_dir = projects_dir() })
  local function fallback()
    search_lua.search(params, cb)
  end
  if M.backend() ~= 'helper' then return fallback() end
  helper.request('search', params, function(err, result)
    if err then return fallback() end
    result.backend, result.limited = 'helper', false
    result.hits = result.hits or {}
    cb(result)
  end)
end

---The turn of the event `event` (1-based) of a transcript, as `first` (index of its first event)
---and `events`; `nil` when the transcript does not have that event.
---@param path string
---@param event integer
---@param cb fun(first: integer|nil, events: table[]|nil)
function M.context(path, event, cb)
  local function from_history()
    lua_scan.history(path, function(events)
      if event < 1 or event > #events then return cb(nil, nil) end
      local first = 1
      for i = event, 1, -1 do
        if render.starts_turn(events[i]) then first = i; break end
      end
      local last = #events
      for i = event + 1, #events do
        if render.starts_turn(events[i]) then last = i - 1; break end
      end
      cb(first, vim.list_slice(events, first, last))
    end)
  end
  if M.backend() ~= 'helper' then return from_history() end
  helper.request('context', { path = path, event = event }, function(err, result)
    if err then
      if vim.uv.fs_stat(path) and err ~= 'stopped' and err ~= 'timeout' then return cb(nil, nil) end
      return from_history()
    end
    cb(result.first, result.events or {})
  end)
end

---Call `fn` when the index has grown or changed (search again to see it).
---@param fn fun()
---@return fun() unsubscribe
function M.on_ready(fn)
  hook()
  listeners[#listeners + 1] = fn
  return function()
    for i, f in ipairs(listeners) do
      if f == fn then table.remove(listeners, i); return end
    end
  end
end

---Test only.
function M._reset()
  listeners = {}
  hooked = false
  search_lua._reset()
end

return M
