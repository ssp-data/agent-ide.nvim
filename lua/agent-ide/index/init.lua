-- Index facade. Only the Lua backend exists so far; a Rust helper joins later behind this API.
local lua_scan = require('agent-ide.index.lua_scan')
local M = {}

local on_change_cb

---@param cb fun(sessions: table[])
---@param projects_dir? string defaults to the `projects_dir` setting
function M.scan(cb, projects_dir)
  lua_scan.scan(projects_dir or require('agent-ide.config').get().projects_dir, cb)
end

---@param path string
---@param cb fun(events: table[])
function M.history(path, cb) lua_scan.history(path, cb) end

---@param fn fun()
function M.on_change(fn) on_change_cb = fn end

---@return 'lua'|'helper'
function M.backend() return 'lua' end

return M
