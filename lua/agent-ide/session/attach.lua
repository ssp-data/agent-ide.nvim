-- Reattaching a Session to a keeper (lua/agent-ide/keeper): what the transcript held before the
-- keeper's Claude started comes from disk (the first `offset` bytes, through the Lua parser),
-- then the keeper's replay, every line sent to and received from Claude since, goes through the
-- same decoder and handlers the live path uses, so the events, the streaming text, the open
-- asks, model, mode, commands and state come back as the first Neovim had them; then live lines
-- follow. While the replay runs `s.replaying` is set: nothing pops up, nothing chimes.
local M = {}

local DECODE_OPTS = require('agent-ide.transcript.parse').DECODE_OPTS

local function notify(msg, level) vim.notify('Agent-IDE: ' .. msg, level or vim.log.levels.INFO) end

---The events of the first `offset` bytes of transcript `path` (none without a file or offset).
---@param path string|nil
---@param offset integer|nil
---@param cb fun(events: table[])
function M.history_before(path, offset, cb)
  if not path or not offset or offset <= 0 or not vim.uv.fs_stat(path) then return vim.schedule(function() cb({}) end) end
  require('agent-ide.index.lua_scan').history(path, cb, offset)
end

-- A line this plugin sent in an earlier Neovim: the same bookkeeping the send did.
local function sent(s, line)
  local ok, obj = pcall(vim.json.decode, line, DECODE_OPTS)
  if not ok or type(obj) ~= 'table' then return end
  if obj.type == 'user' then
    local text = type(obj.message) == 'table' and obj.message.content or ''
    if type(text) ~= 'string' then text = vim.json.encode(text) end
    s:_append({ kind = 'prompt', text = text })
    s.turn_start = #s.events
    s.echo_expected = text
    s:_set_state('busy')
  elseif obj.type == 'control_request' and obj.request_id ~= nil then
    s.requests[obj.request_id] = obj.request
    require('agent-ide.session.object')._bump_ids(obj.request_id)
  elseif obj.type == 'control_response' then
    local r = type(obj.response) == 'table' and obj.response or {}
    for i, p in ipairs(s.pending_permissions) do
      if p.request_id == r.request_id then table.remove(s.pending_permissions, i); break end
    end
    if #s.pending_permissions == 0 and s.state == 'waiting' then s:_set_state('busy') end
    s:_emit('permission')
  end
end

---Attach `s` to its keeper (`info` from `keeper.info`). `cb(true)` once the replay is in and
---live lines flow, `cb(false, why)` when another Neovim drives the session or the keeper is
---gone. False when nothing was started (alive already, or attaching).
---@param s table Session
---@param info table
---@param cb fun(ok: boolean, why?: string)
---@return boolean
function M.attach(s, info, cb)
  if s:_alive() or s.attaching then return false end
  local keeper = require('agent-ide.keeper')
  local process = require('agent-ide.claude.process')
  local stream = require('agent-ide.claude.stream')
  local actions = require('agent-ide.session.actions')
  s.attaching = true
  M.history_before(s.path or info.path, info.offset, function(history)
    if s:_alive() then
      s.attaching = false
      return cb(true)
    end
    local decoder = stream.new()
    local client, handle, greeted
    local function mine() return handle ~= nil and s.proc == handle end
    -- before the keeper said hello it is not ours yet: a keeper that is gone (a stale file, a
    -- crash) is forgotten and the caller carries on as without one
    local function gone(code, tail)
      if not greeted then
        keeper.forget(s.id)
        s.attaching = false
        return cb(false, tail)
      end
      if not mine() then return end
      process.untrack(client)
      keeper.forget(s.id)
      s.replaying, s.attaching = false, false
      actions.on_exit(s, code, tail)
    end
    client = keeper.attach(s.id, {
      on_busy = function()
        s.attaching = false
        notify('another Neovim drives this session', vim.log.levels.WARN)
        cb(false, 'busy')
      end,
      on_hello = function(h)
        greeted = true
        handle = require('agent-ide.agents.claude').wrap(s, client, s:_sink())
        handle.pid = h.claude_pid
        s.proc, s.owned, s.pid = handle, true, h.claude_pid
        s.parking, s.interrupted, s.sent_before = false, false, true
        s.requests, s.deferred, s.park_cbs = {}, {}, {}
        s.replaying = true
        -- the keeper's queue first (older), then what was typed here meanwhile
        s.queue = vim.list_extend(vim.list_extend({}, h.queue or {}), s.queue)
        s.events, s.turn_start, s.streaming, s.pending_permissions = history, #history + 1, '', {}
        s.loaded_key = nil -- after the process ends, the transcript is read again from disk
        client.queue_source = function() return s.queue end
        process.track(client)
        s:_emit('events')
      end,
      on_line = function(dir, line)
        if not mine() then return end
        if dir == 'in' then
          s:_raw('out', line)
          sent(s, line)
        else
          s:_raw('in', line)
          local ok, obj = pcall(vim.json.decode, line, DECODE_OPTS)
          if ok and type(obj) == 'table' then
            for _, a in ipairs(decoder:feed(obj, line)) do actions.handle(s, a) end
          else
            s:_append({ kind = 'unknown', label = 'not JSON', raw = line, live_only = true })
          end
        end
      end,
      on_synced = function()
        if not mine() then return end
        s.replaying, s.attaching = false, false
        for _, what in ipairs({ 'events', 'meta', 'permission', 'state' }) do s:_emit(what) end
        cb(true)
      end,
      on_exit = function(code, _, tail) gone(code, tail) end,
      on_lost = function() gone(nil, 'keeper lost') end,
    })
  end)
  return true
end

return M
