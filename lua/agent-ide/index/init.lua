-- Index facade. Uses the Rust helper when it is built and enabled, otherwise the Lua backend.
-- A helper failure switches to Lua for the rest of the session, so callers never see the difference.
local lua_scan = require('agent-ide.index.lua_scan')
local helper = require('agent-ide.index.helper')
local M = {}

M._tick_ms = 5000 -- Lua backend change interval; tests shorten it

local on_change_cb
local failed = false -- helper failed: Lua for the rest of the session
local notified = false
local visible = false
local watching = false -- `watch` sent to the current helper process
local watch_active = false -- ... and confirmed by it
local handler_set = false
local watch_dir
local timer

local function projects_dir() return require('agent-ide.config').get().projects_dir end

---@return 'lua'|'helper'
function M.backend()
  if not failed and require('agent-ide.config').get().helper.enabled and helper.available() then return 'helper' end
  return 'lua'
end

-- The timer detects changes for the Lua backend, and for the helper while it has no confirmed
-- watch (e.g. the projects directory does not exist yet); each tick's rescan retries the watch.
local function sync_timer()
  local want = on_change_cb ~= nil and visible and (M.backend() == 'lua' or not watch_active)
  if want and not timer then
    timer = vim.uv.new_timer()
    timer:start(M._tick_ms, M._tick_ms, vim.schedule_wrap(function()
      if on_change_cb then on_change_cb() end
    end))
  elseif not want and timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function fail(reason)
  if not failed then
    failed = true
    watching, watch_active = false, false
  end
  if not notified then
    notified = true
    vim.notify('Agent-IDE: helper failed (' .. tostring(reason) .. '), using Lua fallback', vim.log.levels.WARN)
  end
  helper.stop()
  sync_timer()
end

local function ensure_watch(dir)
  if watching or M.backend() ~= 'helper' then return end
  watch_dir = dir
  -- a projects directory that does not exist yet is not an error: try again on the next rearm
  if not vim.uv.fs_stat(dir) then return end
  watching = true
  if not handler_set then
    handler_set = true
    helper.on_exit(function(reason) fail(reason) end)
    helper.on('changed', function() if on_change_cb then on_change_cb() end end)
  end
  helper.request('watch', { projects_dir = dir }, function(err)
    -- a watch error is not a helper failure: the timer covers until a rearm succeeds
    watching = err == nil
    watch_active = err == nil
    sync_timer()
  end)
end

-- A stopped helper restarts lazily on the next request without its watch: re-arm it first.
local function rearm()
  if watching and not helper.running() then watching, watch_active = false, false end
  if on_change_cb and not watching then ensure_watch(watch_dir or projects_dir()) end
end

---@param cb fun(sessions: table[])
---@param projects_dir? string defaults to the `projects_dir` setting
function M.scan(cb, dir)
  dir = dir or projects_dir()
  if M.backend() ~= 'helper' then return lua_scan.scan(dir, cb) end
  rearm()
  helper.request('scan', { projects_dir = dir }, function(err, result)
    if err then
      if err ~= 'stopped' then fail(err) end
      return lua_scan.scan(dir, cb)
    end
    cb(result.sessions or {})
  end)
end

---@param path string
---@param cb fun(events: table[])
function M.history(path, cb)
  if M.backend() ~= 'helper' then return lua_scan.history(path, cb) end
  rearm()
  helper.request('history', { path = path }, function(err, result)
    if err then
      -- a file that does not exist is not a helper failure; Lua yields the same empty result
      if err == 'stopped' or not vim.uv.fs_stat(path) then return lua_scan.history(path, cb) end
      fail(err)
      return lua_scan.history(path, cb)
    end
    cb(result.events or {})
  end)
end

---Call `fn` when transcripts change; `nil` clears it.
---@param fn? fun()
---@param dir? string defaults to the `projects_dir` setting
function M.on_change(fn, dir)
  on_change_cb = fn
  if fn then ensure_watch(dir or projects_dir()) end
  sync_timer()
end

---The drawer reports whether it is showing; the change timer runs only while it is.
---@param v boolean
function M.set_visible(v)
  visible = v and true or false
  sync_timer()
end

---Test-only: forget failure, notice, callbacks and the helper process.
function M._reset()
  helper._reset()
  failed, notified, visible, watching, watch_active, handler_set, watch_dir = false, false, false, false, false, false, nil
  on_change_cb = nil
  M._tick_ms = 5000
  sync_timer()
end

return M
