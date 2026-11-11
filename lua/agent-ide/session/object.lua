-- The Session object: one conversation with an agent, driven from this Neovim. Owns at most
-- one agent process (through its adapter, lua/agent-ide/agents), keeps the transcript events,
-- the state, a prompt queue and open permission asks. Stream actions and process exit are
-- handled in session/actions.lua.
local actions = require('agent-ide.session.actions')
local agents = require('agent-ide.agents')

local M = {}

local RAW_KEEP = 5000
M.RAW_KEEP = RAW_KEEP

local Session = {}
Session.__index = Session
M.Session = Session

-- The Claude adapter numbers its control requests; a keeper replay moves the counters past
-- the ids it replays (session/attach.lua).
function M._reset_ids() require('agent-ide.agents.claude')._reset_ids() end
function M._bump_ids(id) require('agent-ide.agents.claude')._bump_ids(id) end

function Session:_emit(what) require('agent-ide.session')._emit(self, what) end

function Session:_set_state(state)
  if self.state == state then return end
  self.state = state
  self:_emit('state')
end

function Session:_append(ev)
  self.events[#self.events + 1] = ev
  if self.log and not ev.live_only then self.log:append(ev) end
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

---Write one object to the agent's stdin and record it (Claude's wire; tests use it).
function Session:_write(obj)
  if not self:_alive() or not self.proc.write then return false end
  return self.proc:write(obj)
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

---What the adapter feeds this session: wire lines, Actions, the exit. The adapter ignores
---callbacks of a process that is no longer `self.proc`.
function Session:_sink()
  return {
    raw = function(dir, line) self:_raw(dir, line) end,
    action = function(a) actions.handle(self, a) end,
    garbage = function(line)
      self:_raw('in', line)
      self:_append({ kind = 'unknown', label = 'not JSON', raw = line, live_only = true })
    end,
    exit = function(code, tail) actions.on_exit(self, code, tail) end,
    pid = function(pid) self.pid = pid end,
  }
end

function Session:_start_process()
  self.requests = {}
  local handle, err = self.adapter.start(self, self:_sink())
  if not handle then return false, err end
  self.proc, self.owned, self.parking, self.interrupted = handle, true, false, false
  self.pid = handle.pid
  -- mode and model changes asked for before the process ran
  for _, req in ipairs(self.deferred) do handle:send_setting(req) end
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
  if not self.proc:prompt(text) and self.proc then
    self.proc:stop(nil, true)
  end
  return true
end

-- Public methods -------------------------------------------------------------------------

---A send now would start the agent's process (none runs here, none is being stopped, no
---keeper holds one to attach to).
function Session:needs_start()
  return not self:_alive() and not self.parking and not (self.capabilities.live and require('agent-ide.keeper').info(self.id))
end

---Another Claude (a terminal) runs this session. The stale live entry of our own dead
---process (same pid) does not count, nor does a live map not refreshed for two poll intervals,
---nor a Claude a keeper of this plugin holds (that one is attached to, not driven elsewhere).
---Only Claude sessions can be elsewhere (`capabilities.live`).
function Session:_elsewhere()
  if self:_alive() or not self.capabilities.live then return false end
  local e = require('agent-ide.live').fresh()[self.id]
  return e ~= nil and (self.pid == nil or e.pid ~= self.pid) and not require('agent-ide.keeper').claude_pids()[e.pid]
end

---A keeper holds a process for this session and nothing runs here: attach to it; `cb(ok)`.
---False when there is nothing to attach to (or it is attached, or attaching, or the agent has
---no keepers).
---@param cb? fun(ok: boolean, why?: string)
---@return boolean
function Session:attach(cb)
  if not self.adapter.attach then return false end
  return self.adapter.attach(self, cb or function() end)
end

---The next queued prompt starts a turn when none runs (after an attach).
function Session:_resume_queue()
  if self.state == 'busy' or self.state == 'waiting' or self.parking or #self.queue == 0 then return end
  local text = table.remove(self.queue, 1)
  self:_emit('meta')
  if not self:_start_turn(text) then
    table.insert(self.queue, 1, text)
    self:_emit('meta')
  end
end

---Send a prompt; starts the process when none runs, queues while a turn is running.
---@param text string
---@return boolean ok, string|nil reason
function Session:send(text)
  if type(text) ~= 'string' or not text:find('%S') then return false, 'empty' end
  if self:_elsewhere() then return false, 'running elsewhere' end
  self.queue[#self.queue + 1] = text
  if self.state == 'busy' or self.state == 'waiting' or self.parking or self.attaching then
    self:_emit('meta')
    return true
  end
  -- a keeper holds this session's process: attach, then the queue goes on
  if not self:_alive() and self.capabilities.live and require('agent-ide.keeper').info(self.id) then
    self:_emit('meta')
    self:attach(function(ok) if ok then self:_resume_queue() end end)
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
  local sent = self:_alive() and self.proc:interrupt() or false
  -- only a running turn ends with a result that must not start the next prompt
  if sent and (self.state == 'busy' or self.state == 'waiting') then self.interrupted = true end
  return self:_drop_queue(), sent
end

-- Mode and model changes before a process runs are sent right after it starts (`deferred`
-- holds them in the adapter's own shape).
function Session:_setting(op, value)
  if self:_alive() then return self.proc[op](self.proc, value) end
  self.deferred[#self.deferred + 1] = self.adapter.setting(op, value)
  return true
end

---Ask the agent for another mode. Until it confirms or refuses, `mode_requested` holds the
---mode asked for (plugin name: `manual` for Claude's `default`).
---@param mode string the agent's mode name (Claude: 'plan', 'acceptEdits', 'default', ...)
---@return boolean
function Session:set_mode(mode)
  if not self:_setting('set_mode', mode) then return false end
  self.mode_requested = self.adapter.plugin_mode(mode)
  self:_emit('meta')
  return true
end

---Ask the agent for another model; `model_requested` holds it until it answers.
---@param model string
---@return boolean
function Session:set_model(model)
  if not self:_setting('set_model', model) then return false end
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
  if not self:_alive() or not self.proc:answer(p, allow, opts) then return false end
  for _, u in ipairs(allow and opts.updated_permissions or {}) do
    if u.type == 'setMode' and type(u.mode) == 'string' then
      self.mode_requested = self.adapter.plugin_mode(u.mode)
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
    local choice = vim.fn.confirm(self.adapter.confirm_stop_text, '&Stop\n&Cancel', 2)
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

---Load the session's history into `events` (the adapter's: Claude's transcript file, the
---plugin's own log for other agents); always calls `cb` (scheduled). A keeper that holds this
---session's process is attached to instead: the history comes with the attach.
---@param cb? fun()
function Session:load(cb)
  cb = cb or function() end
  if self:attach(function(ok) if not ok then self:load(cb) else cb() end end) then return end
  self.adapter.history(self, cb)
end

---@param opts { id?: string, cwd: string, path?: string, title?: string, agent?: string, agent_session_id?: string }
---@param id string
function M.new(opts, id)
  local name = opts.agent or agents.default()
  local adapter, err = agents.get(name)
  if not adapter then error('agent-ide: ' .. tostring(err), 2) end
  return setmetatable({
    id = id, cwd = opts.cwd, path = opts.path, title = opts.title,
    agent = name, adapter = adapter, capabilities = vim.deepcopy(adapter.capabilities),
    agent_session_id = opts.agent_session_id,
    state = opts.id and 'parked' or 'idle',
    events = {}, streaming = '', turn_start = 1, pending_permissions = {}, queue = {}, raw = {}, raw_dropped = 0,
    unread = false, owned = false, visible = false,
    -- internal
    requests = {}, deferred = {}, park_cbs = {}, sent_before = false,
  }, Session)
end

return M
