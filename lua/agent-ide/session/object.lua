-- The Session object: one Claude conversation driven from this Neovim. Owns at most one
-- `claude -p` process, keeps the transcript events, the state, a prompt queue and open
-- permission asks. Stream actions and process exit are handled in session/actions.lua.
local process = require('agent-ide.claude.process')
local stream = require('agent-ide.claude.stream')
local actions = require('agent-ide.session.actions')

local M = {}

local RAW_KEEP = 5000
M.RAW_KEEP = RAW_KEEP
local DENY_MESSAGE = 'Denied by user in Neovim'

local request_n = 0 -- ids of control requests we send: r1, r2, ...
local init_n = 0 -- ids of the `initialize` requests: i1, i2, ... (apart, so r1 stays the first setting)

local Session = {}
Session.__index = Session
M.Session = Session

function M._reset_ids() request_n, init_n = 0, 0 end

function Session:_emit(what) require('agent-ide.session')._emit(self, what) end

function Session:_set_state(state)
  if self.state == state then return end
  self.state = state
  self:_emit('state')
end

function Session:_append(ev)
  self.events[#self.events + 1] = ev
  self:_emit('events')
end

function Session:_raw(dir, line)
  local raw = self.raw
  raw[#raw + 1] = { dir = dir, line = line }
  if #raw > RAW_KEEP then
    table.remove(raw, 1)
    self.raw_dropped = self.raw_dropped + 1
  end
  -- the raw view (ui/raw.lua) follows the wire while it is open
  local on_raw = self.on_raw
  if on_raw and not pcall(on_raw, dir, line) then self.on_raw = nil end
end

function Session:_alive() return self.proc ~= nil and self.proc:alive() end

---Write one object to Claude's stdin and record it.
function Session:_write(obj)
  if not self:_alive() then return false end
  if not self.proc:send(obj) then return false end
  self:_raw('out', vim.json.encode(obj))
  return true
end

function Session:_control(request)
  request_n = request_n + 1
  local id = 'r' .. request_n
  if not self:_write({ type = 'control_request', request_id = id, request = request }) then return false end
  self.requests[id] = request
  return true
end

---Empty the queue; returns the prompts dropped.
function Session:_drop_queue()
  local dropped = self.queue
  self.queue = {}
  if #dropped > 0 then self:_emit('meta') end
  return dropped
end

-- Text that was streamed but never confirmed by a full message stays as a text event.
function Session:_flush_streaming()
  if self.streaming == '' then return end
  local text = self.streaming
  self.streaming = ''
  self:_append({ kind = 'text', text = text })
end

-- End of a turn without a running process left behind it: idle when on screen, else unread.
function Session:_settle(failed)
  if self.visible then
    self.unread = false
    self:_set_state('idle')
  else
    self.unread = true
    self:_set_state(failed and 'failed' or 'done')
  end
end

function Session:_has_transcript()
  return self.path ~= nil and vim.uv.fs_stat(self.path) ~= nil
end

function Session:_start_process()
  local resume = self.sent_before or self:_has_transcript()
  local decoder = stream.new()
  local proc
  local function mine() return self.proc == proc end
  local err
  proc, err = process.start({
    cwd = self.cwd,
    session_id = self.id,
    resume = resume,
    model = require('agent-ide.config').get().claude.model,
    on_object = function(obj, raw)
      if not mine() then return end
      self:_raw('in', raw)
      for _, a in ipairs(decoder:feed(obj, raw)) do actions.handle(self, a) end
    end,
    on_garbage = function(line)
      if not mine() then return end
      self:_raw('in', line)
      self:_append({ kind = 'unknown', label = 'not JSON', raw = line, live_only = true })
    end,
    on_exit = function(code, _, tail)
      if mine() then actions.on_exit(self, code, tail) end
    end,
  })
  if not proc then return false, 'cannot start Claude: ' .. tostring(err) end
  self.proc, self.owned, self.parking, self.interrupted, self.requests = proc, true, false, false, {}
  self.pid = proc.handle and proc.handle.pid
  -- the very first line of every new process: Claude answers with its models and commands,
  -- without a turn (docs/protocol.md); the prompt is written after it
  init_n = init_n + 1
  local iid = 'i' .. init_n
  if self:_write({ type = 'control_request', request_id = iid, request = { subtype = 'initialize' } }) then
    self.requests[iid] = { subtype = 'initialize' }
  end
  require('agent-ide.claude.version').check() -- first start only; see claude/version.lua
  for _, req in ipairs(self.deferred) do self:_control(req) end
  self.deferred = {}
  return true
end

function Session:_start_turn(text)
  if not self:_alive() then
    local ok, err = self:_start_process()
    if not ok then return false, err end
  end
  self:_append({ kind = 'prompt', text = text })
  self.turn_start = #self.events
  self.echo_expected = text
  self.sent_before = true
  self:_set_state('busy')
  -- The process died before it could read the prompt: make sure it exits, so the exit
  -- path marks this turn failed.
  if not self:_write({ type = 'user', message = { role = 'user', content = text } }) and self.proc then
    self.proc:stop(nil, true)
  end
  return true
end

-- Public methods -------------------------------------------------------------------------

---A send now would start a Claude process (none runs here and none is being stopped).
function Session:needs_start() return not self:_alive() and not self.parking end

---Another Claude (a terminal) runs this session. The stale live entry of our own dead
---process (same pid) does not count, nor does a live map not refreshed for two poll intervals.
function Session:_elsewhere()
  if self:_alive() then return false end
  local e = require('agent-ide.live').fresh()[self.id]
  return e ~= nil and (self.pid == nil or e.pid ~= self.pid)
end

---Send a prompt; starts the process when none runs, queues while a turn is running.
---@param text string
---@return boolean ok, string|nil reason
function Session:send(text)
  if type(text) ~= 'string' or not text:find('%S') then return false, 'empty' end
  if self:_elsewhere() then return false, 'running elsewhere' end
  self.queue[#self.queue + 1] = text
  if self.state == 'busy' or self.state == 'waiting' or self.parking then
    self:_emit('meta')
    return true
  end
  -- prompts left over from a crash go first
  local ok, err = self:_start_turn(self.queue[1])
  if not ok then
    table.remove(self.queue)
    return false, err
  end
  table.remove(self.queue, 1)
  if #self.queue > 0 then self:_emit('meta') end
  return true
end

---Interrupt the running turn and drop the queue.
---@return string[] dropped prompts, boolean sent
function Session:interrupt()
  local sent = self:_alive() and self:_control({ subtype = 'interrupt' }) or false
  -- only a running turn ends with a result that must not start the next prompt
  if sent and (self.state == 'busy' or self.state == 'waiting') then self.interrupted = true end
  return self:_drop_queue(), sent
end

-- Mode and model changes before a process runs are sent right after it starts.
function Session:_setting(request)
  if self:_alive() then return self:_control(request) end
  self.deferred[#self.deferred + 1] = request
  return true
end

---Ask Claude for another mode. Until Claude confirms or refuses, `mode_requested` holds the
---mode asked for (plugin name: `manual` for Claude's `default`).
---@param mode string Claude's mode name ('plan', 'acceptEdits', 'default', ...)
---@return boolean
function Session:set_mode(mode)
  if not self:_setting({ subtype = 'set_permission_mode', mode = mode }) then return false end
  self.mode_requested = mode == 'default' and 'manual' or mode
  self:_emit('meta')
  return true
end

---Ask Claude for another model; `model_requested` holds it until Claude answers.
---@param model string
---@return boolean
function Session:set_model(model)
  if not self:_setting({ subtype = 'set_model', model = model }) then return false end
  self.model_requested = model
  self:_emit('meta')
  return true
end

---Answer an open permission ask (also user questions and plan approvals).
---`updated_permissions` (with an allow) are permission updates in Claude's suggestion shape
---(`setMode`, `addRules`, ...) that Claude applies with the answer; a `setMode` among them is
---pending in `mode_requested` until Claude reports the mode.
---@param request_id string
---@param allow boolean
---@param opts? { updated_input?: table, message?: string, updated_permissions?: table[] }
---@return boolean answered
function Session:answer(request_id, allow, opts)
  opts = opts or {}
  local idx
  for i, p in ipairs(self.pending_permissions) do
    if p.request_id == request_id then idx = i; break end
  end
  if not idx then return false end
  local p = self.pending_permissions[idx]
  local response = allow and { behavior = 'allow', updatedInput = opts.updated_input or p.input }
    or { behavior = 'deny', message = opts.message or DENY_MESSAGE }
  local updates = allow and opts.updated_permissions or nil
  if updates and #updates > 0 then response.updatedPermissions = updates end
  if not self:_write({ type = 'control_response',
    response = { subtype = 'success', request_id = request_id, response = response } }) then
    return false
  end
  for _, u in ipairs(updates or {}) do
    if u.type == 'setMode' and type(u.mode) == 'string' then
      self.mode_requested = u.mode == 'default' and 'manual' or u.mode
      self.mode_by_answer = self.mode_requested -- given up at the end of the turn if unconfirmed
      self:_emit('meta')
    end
  end
  table.remove(self.pending_permissions, idx)
  self:_emit('permission')
  if #self.pending_permissions == 0 and self.state == 'waiting' then self:_set_state('busy') end
  return true
end

---Stop the process and drop the queue; asks first when a turn is running.
---`cb(false)` when declined, else `cb(true, dropped_prompts)` once the process is gone.
---@param cb? fun(parked: boolean, dropped: string[]|nil)
function Session:park(cb)
  cb = cb or function() end
  if self.state == 'busy' or self.state == 'waiting' then
    local choice = vim.fn.confirm('Claude is still working in this session. Stop it?', '&Stop\n&Cancel', 2)
    if choice ~= 1 then return vim.schedule(function() cb(false) end) end
  end
  local dropped = self:_drop_queue()
  if not self:_alive() then
    self:_set_state('parked')
    return vim.schedule(function() cb(true, dropped) end)
  end
  self.parking = true
  self.park_cbs[#self.park_cbs + 1] = function() cb(true, dropped) end
  self.proc:stop()
end

---The user has seen the session: clears `unread`; `done`/`failed` become `idle`.
function Session:mark_seen()
  self.unread = false
  if self.state == 'done' or self.state == 'failed' then self:_set_state('idle') end
end

---Load the transcript's history into `events`. Reloads only when the file changed and no
---process runs; always calls `cb` (scheduled). Events added while loading are kept after
---the history.
---@param cb? fun()
function Session:load(cb)
  cb = cb or function() end
  if not self.path then return vim.schedule(cb) end
  vim.uv.fs_stat(self.path, vim.schedule_wrap(function(_, st)
    local key = st and (st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.size)
    if not st or self:_alive() or key == self.loaded_key then return cb() end
    local count = #self.events
    require('agent-ide.index').history(self.path, function(history)
      local extra = vim.list_slice(self.events, count + 1)
      local ts = self.turn_start
      if #extra > 0 and ts > count then
        ts = ts - count + #history -- the turn started during the load: follow its prompt
      else
        ts = math.max(ts, #history + 1) -- never backwards
        self.streaming = ''
      end
      self.events = vim.list_extend(history, extra)
      self.turn_start, self.loaded_key = ts, key
      self:_emit('events')
      cb()
    end)
  end))
end

---@param opts { id?: string, cwd: string, path?: string, title?: string }
---@param id string
function M.new(opts, id)
  return setmetatable({
    id = id, cwd = opts.cwd, path = opts.path, title = opts.title,
    state = opts.id and 'parked' or 'idle',
    events = {}, streaming = '', turn_start = 1, pending_permissions = {}, queue = {}, raw = {}, raw_dropped = 0,
    unread = false, owned = false, visible = false,
    -- internal
    requests = {}, deferred = {}, park_cbs = {}, sent_before = false,
  }, Session)
end

return M
