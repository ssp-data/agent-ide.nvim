-- The Claude adapter: how a Session drives `claude -p` (claude/process.lua, under a keeper or
-- as a child) and reads its stream (claude/stream.lua) through the adapter interface every
-- agent offers. Claude's wire shapes (docs/protocol.md) live here and in claude/; the Session
-- only sees Actions and the handle's methods.
local process = require('agent-ide.claude.process')
local stream = require('agent-ide.claude.stream')

local M = {}

M.name = 'claude'
M.label = 'Claude'
M.capabilities = {
  resume = true, modes = true, models = true, commands = true, interrupt = true, quota = true,
  native = true, live = true, transcript = true, images = false,
}
M.confirm_stop_text = 'Claude is still working in this session. Stop it?'

local DENY_MESSAGE = 'Denied by user in Neovim'

local request_n = 0 -- ids of control requests we send: r1, r2, ...
local init_n = 0 -- ids of the `initialize` requests: i1, i2, ... (apart, so r1 stays the first setting)

function M._reset_ids() request_n, init_n = 0, 0 end

---A request id replayed from a keeper (`r12`, `i3`): the counters move past it.
---@param id any
function M._bump_ids(id)
  local kind, n = tostring(id):match('^([ri])(%d+)$')
  if not kind then return end
  n = tonumber(n)
  if kind == 'r' then request_n = math.max(request_n, n) else init_n = math.max(init_n, n) end
end

-- Handle ------------------------------------------------------------------------------------

local Handle = {}
Handle.__index = Handle

function Handle:alive() return self.inner ~= nil and self.inner:alive() end

---Write one object to Claude's stdin and record it (the raw view).
---@param obj table
---@return boolean
function Handle:write(obj)
  if not self:alive() then return false end
  if not self.inner:send(obj) then return false end
  self.sink.raw('out', vim.json.encode(obj))
  return true
end

---Send a control request; `s.requests` remembers it for the answer (session/actions.lua).
function Handle:control(request)
  request_n = request_n + 1
  local id = 'r' .. request_n
  if not self:write({ type = 'control_request', request_id = id, request = request }) then return false end
  self.s.requests[id] = request
  return true
end

function Handle:prompt(text)
  return self:write({ type = 'user', message = { role = 'user', content = text } })
end

function Handle:interrupt() return self:control({ subtype = 'interrupt' }) end

---@param mode string Claude's mode name ('plan', 'acceptEdits', 'default', ...)
function Handle:set_mode(mode) return self:control({ subtype = 'set_permission_mode', mode = mode }) end

function Handle:set_model(model) return self:control({ subtype = 'set_model', model = model }) end

---Send a setting deferred while no process ran (`M.setting`).
function Handle:send_setting(req) return self:control(req) end

---Answer the pending ask `p`. `updated_permissions` (with an allow) are permission updates in
---Claude's suggestion shape (`setMode`, `addRules`, ...) that Claude applies with the answer.
---@param p table pending ask { request_id, input, ... }
---@param allow boolean
---@param opts { updated_input?: table, message?: string, updated_permissions?: table[] }
---@return boolean
function Handle:answer(p, allow, opts)
  local response = allow and { behavior = 'allow', updatedInput = opts.updated_input or p.input }
    or { behavior = 'deny', message = opts.message or DENY_MESSAGE }
  local updates = allow and opts.updated_permissions or nil
  if updates and #updates > 0 then response.updatedPermissions = updates end
  return self:write({ type = 'control_response',
    response = { subtype = 'success', request_id = p.request_id, response = response } })
end

function Handle:stop(cb, now) return self.inner:stop(cb, now) end

---Leave Claude running under its keeper (quit); `items`: the prompts still queued.
function Handle:detach(items) return self.inner:detach(items) end

---Wrap a Claude process or keeper client (`claude/process` interface) for Session `s`.
---@param s table Session
---@param inner table
---@param sink table
---@return table handle
function M.wrap(s, inner, sink)
  return setmetatable({ s = s, inner = inner, sink = sink, keeper = inner.keeper == true,
    pid = inner.handle and inner.handle.pid or nil }, Handle)
end

-- Adapter -----------------------------------------------------------------------------------

---The plugin's name for one of Claude's modes (`manual` for Claude's `default`).
---@param m string
---@return string
function M.plugin_mode(m) return m == 'default' and 'manual' or m end

---A mode or model change asked for while no process runs, in the shape `s.deferred` keeps
---until the next start (Claude's control request).
---@param op 'set_mode'|'set_model'
---@param value string
---@return table
function M.setting(op, value)
  if op == 'set_mode' then return { subtype = 'set_permission_mode', mode = value } end
  return { subtype = 'set_model', model = value }
end

---Start Claude for Session `s`: resume when the session sent before or has a transcript. The
---very first line is `initialize` (docs/protocol.md). Returns the handle; `s.proc` is still
---the caller's to set, so a callback of this process counts only once it is.
---@param s table Session
---@param sink table { raw, action, garbage, exit, pid }
---@return table|nil handle, string|nil err
function M.start(s, sink)
  local resume = s.sent_before or s:_has_transcript()
  local decoder = stream.new()
  local handle
  local function mine() return handle ~= nil and s.proc == handle end
  local inner, err = process.start({
    cwd = s.cwd,
    session_id = s.id,
    resume = resume,
    path = s.path,
    model = require('agent-ide.prefs').start_model(s),
    on_object = function(obj, raw)
      if not mine() then return end
      sink.raw('in', raw)
      for _, a in ipairs(decoder:feed(obj, raw)) do sink.action(a) end
    end,
    on_garbage = function(line)
      if mine() then sink.garbage(line) end
    end,
    on_exit = function(code, _, tail)
      if mine() then sink.exit(code, tail) end
    end,
    on_pid = function(pid) -- a keeper names Claude's pid once it is up
      if mine() then
        handle.pid = pid
        sink.pid(pid)
      end
    end,
  })
  if not inner then return nil, 'cannot start Claude: ' .. tostring(err) end
  inner.queue_source = function() return s.queue end -- handed to a keeper when Neovim quits
  handle = M.wrap(s, inner, sink)
  -- Claude answers `initialize` with its models and commands, without a turn; the prompt is
  -- written after it
  init_n = init_n + 1
  local iid = 'i' .. init_n
  if handle:write({ type = 'control_request', request_id = iid, request = { subtype = 'initialize' } }) then
    s.requests[iid] = { subtype = 'initialize' }
  end
  require('agent-ide.claude.version').check() -- first start only; see claude/version.lua
  return handle
end

---Load the transcript's history into `s.events`. Reloads only when the file changed and no
---process runs; always calls `cb` (scheduled). Events added while loading are kept after
---the history.
---@param s table Session
---@param cb fun()
function M.history(s, cb)
  if not s.path then return vim.schedule(cb) end
  vim.uv.fs_stat(s.path, vim.schedule_wrap(function(_, st)
    local key = st and (st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.size)
    if not st or s:_alive() or key == s.loaded_key then return cb() end
    local count = #s.events
    require('agent-ide.index').history(s.path, function(history)
      local extra = vim.list_slice(s.events, count + 1)
      local ts = s.turn_start
      if #extra > 0 and ts > count then
        ts = ts - count + #history -- the turn started during the load: follow its prompt
      else
        ts = math.max(ts, #history + 1) -- never backwards
        s.streaming = ''
      end
      s.events = vim.list_extend(history, extra)
      s.turn_start, s.loaded_key = ts, key
      s:_emit('events')
      cb()
    end)
  end))
end

---A keeper holds a Claude for `s` and nothing runs here: attach to it; `cb(ok)`. False when
---there is nothing to attach to (or it is attached, or attaching).
---@param s table Session
---@param cb fun(ok: boolean, why?: string)
---@return boolean
function M.attach(s, cb)
  local info = require('agent-ide.keeper').info(s.id)
  if not info or s:_alive() or s.parking then return false end
  return require('agent-ide.session.attach').attach(s, info, cb)
end

M._Handle = Handle
return M
