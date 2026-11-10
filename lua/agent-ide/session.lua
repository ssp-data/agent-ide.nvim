-- Session: one Claude conversation driven from this Neovim. Owns at most one `claude -p`
-- process, keeps the transcript events, the state, a prompt queue and open permission asks.
-- Registry of all sessions plus change listeners. No UI here.
local process = require('agent-ide.claude.process')
local stream = require('agent-ide.claude.stream')

local M = {}

local RAW_KEEP = 5000
local DENY_MESSAGE = 'Denied by user in Neovim'
local ECHO_WARNING = 'Prompt echoed by Claude differs from what was sent'

local by_id, order = {}, {} -- registry
local listeners, broken = {}, {} -- broken: listeners that raised (reported once)
local last_quota
local request_n = 0 -- ids of control requests we send: r1, r2, ...

---Random UUID v4.
---@return string
local function uuid()
  local ok, bytes = pcall(vim.uv.random, 16)
  if not ok or type(bytes) ~= 'string' or #bytes ~= 16 then
    local f = assert(io.open('/dev/urandom', 'rb'))
    bytes = f:read(16)
    f:close()
  end
  local b = { bytes:byte(1, 16) }
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  local hex = {}
  for i = 1, 16 do hex[i] = string.format('%02x', b[i]) end
  local h = table.concat(hex)
  return ('%s-%s-%s-%s-%s'):format(h:sub(1, 8), h:sub(9, 12), h:sub(13, 16), h:sub(17, 20), h:sub(21, 32))
end

local function emit(s, what)
  if by_id[s.id] ~= s then return end -- dropped by _reset: a late callback of an old process
  for _, fn in ipairs(vim.list_slice(listeners)) do
    local ok, err = pcall(fn, s, what)
    if not ok and not broken[fn] then
      broken[fn] = true
      vim.notify('agent-ide: error in session listener: ' .. tostring(err), vim.log.levels.WARN)
    end
  end
end

local Session = {}
Session.__index = Session

function Session:_set_state(state)
  if self.state == state then return end
  self.state = state
  emit(self, 'state')
end

function Session:_append(ev)
  self.events[#self.events + 1] = ev
  emit(self, 'events')
end

function Session:_raw(dir, line)
  local raw = self.raw
  raw[#raw + 1] = { dir = dir, line = line }
  if #raw > RAW_KEEP then table.remove(raw, 1) end
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
      for _, a in ipairs(decoder:feed(obj, raw)) do self:_on_action(a) end
    end,
    on_garbage = function(line)
      if not mine() then return end
      self:_raw('in', line)
      self:_append({ kind = 'unknown', label = 'not JSON', raw = line })
    end,
    on_exit = function(code, _, tail)
      if mine() then self:_on_exit(code, tail) end
    end,
  })
  if not proc then return false, 'cannot start Claude: ' .. tostring(err) end
  self.proc, self.owned, self.parking, self.requests = proc, true, false, {}
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
  self:_write({ type = 'user', message = { role = 'user', content = text } })
  self:_set_state('busy')
  return true
end

-- Claude started a turn by itself (e.g. after a background task): busy without a prompt.
function Session:_turn_begins()
  if self.state ~= 'busy' and self.state ~= 'waiting' then self:_set_state('busy') end
end

local HANDLERS = {}

function HANDLERS.init(self, a)
  self.model, self.mode, self.slash_commands = a.model, a.mode, a.slash_commands
  emit(self, 'meta')
  self:_turn_begins()
end

function HANDLERS.status(self, a)
  if a.mode then
    self.mode = a.mode
    emit(self, 'meta')
  end
  if a.busy then self:_turn_begins() end
end

function HANDLERS.delta(self, a)
  self.streaming = self.streaming .. a.text
  emit(self, 'delta')
end

function HANDLERS.event(self, a)
  local ev = a.event
  ev.streamed = nil
  if a.streamed then self.streaming = '' end
  self:_append(ev)
end

function HANDLERS.echo(self, a)
  local expected = self.echo_expected
  self.echo_expected = nil
  if expected == nil or a.text == expected then return end
  self:_append({ kind = 'meta', label = 'warning', text = ECHO_WARNING })
  if not self.echo_warned then
    self.echo_warned = true
    vim.notify('agent-ide: ' .. ECHO_WARNING, vim.log.levels.WARN)
  end
end

function HANDLERS.permission(self, a)
  self.pending_permissions[#self.pending_permissions + 1] = {
    request_id = a.request_id, tool_name = a.tool_name, input = a.input,
    description = a.description, suggestions = a.suggestions,
  }
  emit(self, 'permission')
  self:_set_state('waiting')
end

-- Answers to our own requests; anything else (e.g. Claude echoing our permission
-- answers) is informational only.
function HANDLERS.control_ok(self, a)
  local req = self.requests[a.request_id]
  if not req then return end
  self.requests[a.request_id] = nil
  if req.subtype == 'set_model' then
    self.model = req.model
    emit(self, 'meta')
  end
end

function HANDLERS.control_error(self, a)
  local req = self.requests[a.request_id]
  if not req then return end
  self.requests[a.request_id] = nil
  self:_append({ kind = 'meta', label = 'error', text = req.subtype .. ': ' .. tostring(a.error) })
end

function HANDLERS.quota(self, a)
  last_quota = a.windows
  emit(self, 'quota')
end

function HANDLERS.result(self, a)
  self:_flush_streaming()
  self.echo_expected = nil
  if a.is_error then self:_append({ kind = 'meta', label = 'error', text = a.text or 'Turn failed' }) end
  if #self.pending_permissions > 0 then
    self.pending_permissions = {}
    emit(self, 'permission')
  end
  if #self.queue > 0 and self:_start_turn(table.remove(self.queue, 1)) then return end
  self:_settle(a.is_error)
end

function HANDLERS.unknown(self, a)
  self:_append({ kind = 'unknown', label = a.label, raw = a.raw })
end

function Session:_on_action(a)
  local h = HANDLERS[a.type]
  if h then
    h(self, a)
  else
    self:_append({ kind = 'unknown', label = 'action/' .. tostring(a.type), raw = vim.inspect(a) })
  end
end

function Session:_on_exit(code, tail)
  self.proc = nil
  self.echo_expected = nil
  self:_flush_streaming()
  if #self.pending_permissions > 0 then
    self.pending_permissions = {}
    emit(self, 'permission')
  end
  local parking, cbs = self.parking, self.park_cbs
  self.parking, self.park_cbs = false, {}
  if parking then
    self:_set_state('parked')
  else
    self.owned = false
    if self.state == 'busy' or self.state == 'waiting' then
      local text = ('Claude exited (code %s)'):format(tostring(code))
      tail = vim.trim(tail or '')
      if tail ~= '' then text = text .. '\n' .. tail end
      self:_append({ kind = 'meta', label = 'error', text = text })
      self:_settle(true)
    elseif self.state == 'idle' then
      self:_set_state('parked')
    end
  end
  for _, cb in ipairs(cbs) do cb(true) end
end

-- Public methods -------------------------------------------------------------------------

---Send a prompt; starts the process when none runs, queues while a turn is running.
---@param text string
---@return boolean ok, string|nil reason
function Session:send(text)
  if type(text) ~= 'string' or not text:find('%S') then return false, 'empty' end
  if require('agent-ide.live').get()[self.id] ~= nil and not self.owned then
    return false, 'running elsewhere'
  end
  if self.state == 'busy' or self.state == 'waiting' then
    self.queue[#self.queue + 1] = text
    return true
  end
  -- prompts left over from a crash go first
  self.queue[#self.queue + 1] = text
  local ok, err = self:_start_turn(self.queue[1])
  if not ok then
    table.remove(self.queue)
    return false, err
  end
  table.remove(self.queue, 1)
  return true
end

---@return boolean sent
function Session:interrupt()
  return self:_alive() and self:_control({ subtype = 'interrupt' })
end

-- Mode and model changes before a process runs are sent right after it starts.
function Session:_setting(request)
  if self:_alive() then return self:_control(request) end
  self.deferred[#self.deferred + 1] = request
  return true
end

---@param mode string Claude's mode name ('plan', 'acceptEdits', 'default', ...)
---@return boolean
function Session:set_mode(mode) return self:_setting({ subtype = 'set_permission_mode', mode = mode }) end

---@param model string
---@return boolean
function Session:set_model(model) return self:_setting({ subtype = 'set_model', model = model }) end

---Answer an open permission ask (also user questions and plan approvals).
---@param request_id string
---@param allow boolean
---@param opts? { updated_input?: table, message?: string }
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
  if not self:_write({ type = 'control_response',
    response = { subtype = 'success', request_id = request_id, response = response } }) then
    return false
  end
  table.remove(self.pending_permissions, idx)
  emit(self, 'permission')
  if #self.pending_permissions == 0 and self.state == 'waiting' then self:_set_state('busy') end
  return true
end

---Stop the process; asks first when a turn is running. `cb(false)` when declined.
---@param cb? fun(parked: boolean)
function Session:park(cb)
  cb = cb or function() end
  if self.state == 'busy' or self.state == 'waiting' then
    local choice = vim.fn.confirm('Claude is still working in this session. Stop it?', '&Stop\n&Cancel', 2)
    if choice ~= 1 then return vim.schedule(function() cb(false) end) end
  end
  if not self:_alive() then
    self:_set_state('parked')
    return vim.schedule(function() cb(true) end)
  end
  self.parking = true
  self.park_cbs[#self.park_cbs + 1] = cb
  self.proc:stop()
end

---The user has seen the session: clears `unread`; `done`/`failed` become `idle`.
function Session:mark_seen()
  self.unread = false
  if self.state == 'done' or self.state == 'failed' then self:_set_state('idle') end
end

---Load the transcript's history into `events`. Reloads only when the file changed and no
---process runs; always calls `cb` (scheduled).
---@param cb? fun()
function Session:load(cb)
  cb = cb or function() end
  if not self.path then return vim.schedule(cb) end
  vim.uv.fs_stat(self.path, vim.schedule_wrap(function(_, st)
    local key = st and (st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.size)
    if not st or self:_alive() or key == self.loaded_key then return cb() end
    local count = #self.events
    require('agent-ide.index').history(self.path, function(events)
      -- a process started meanwhile owns the events now; keep what it produced
      if not self:_alive() and #self.events == count then
        self.events, self.loaded_key = events, key
        self.streaming, self.turn_start = '', #events + 1
        emit(self, 'events')
      end
      cb()
    end)
  end))
end

-- Module -------------------------------------------------------------------------------

---@param opts { id?: string, cwd: string, path?: string, title?: string }
---@return table session
function M.open(opts)
  local s = opts.id and by_id[opts.id]
  if s then
    s.path = s.path or opts.path
    s.title = s.title or opts.title
    return s
  end
  s = setmetatable({
    id = opts.id or uuid(), cwd = opts.cwd, path = opts.path, title = opts.title,
    state = opts.id and 'parked' or 'idle',
    events = {}, streaming = '', turn_start = 1, pending_permissions = {}, queue = {}, raw = {},
    unread = false, owned = false, visible = false,
    -- internal
    requests = {}, deferred = {}, park_cbs = {}, sent_before = false,
  }, Session)
  by_id[s.id] = s
  order[#order + 1] = s
  return s
end

---@param id string
---@return table|nil
function M.get(id) return by_id[id] end

---@return table[] sessions in creation order
function M.all() return vim.list_slice(order) end

---@param fn fun(session: table, what: 'state'|'events'|'delta'|'meta'|'permission'|'quota')
function M.on_change(fn) listeners[#listeners + 1] = fn end

---@param fn function
function M.off_change(fn)
  for i, f in ipairs(listeners) do
    if f == fn then table.remove(listeners, i); return end
  end
end

---@return table|nil windows latest quota: name -> { utilization, resets_at }
function M.quota() return last_quota end

---Test only: stop every process, forget all sessions and listeners.
function M._reset()
  for _, s in ipairs(order) do
    if s.proc then s.proc:stop(nil, true) end
  end
  by_id, order, listeners, broken = {}, {}, {}, {}
  last_quota, request_n = nil, 0
end

return M
