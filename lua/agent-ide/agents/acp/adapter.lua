-- The ACP adapter: one per configured agent (`config.agents.<name> = { kind = 'acp', cmd, env,
-- fs, replay_context }`). Starts the agent (agents/acp/client.lua), runs the handshake
-- (`initialize`, then `session/new` or `session/load`), turns its updates into Actions
-- (agents/acp/translate.lua), answers its permission and file requests, and offers the
-- handle a Session drives: prompt (a `session/prompt` request open for the whole turn),
-- interrupt (`session/cancel`), answer, set_mode, set_model, stop. See docs/protocol-acp.md.
local client_mod = require('agent-ide.agents.acp.client')
local fs = require('agent-ide.agents.acp.fs')
local translate = require('agent-ide.agents.acp.translate')

local M = {}

M.PROTOCOL_VERSION = 1
M.HANDSHAKE_MS = 60000 -- initialize and session/new (a load replays the whole conversation first)
M.CLIENT_INFO = { name = 'agent-ide.nvim', version = '0' }

local function list(v) return type(v) == 'table' and vim.islist(v) and v or {} end
local function str(v) return type(v) == 'string' and v or nil end

-- Events the adapter makes itself (an error of the handshake): never in the log.
local function live_meta(label, text)
  return { type = 'event', event = { kind = 'meta', label = label, text = text, live_only = true } }
end

local Handle = {}
Handle.__index = Handle

function Handle:alive() return self.client ~= nil and self.client:alive() end
function Handle:stop(cb, now) return self.client:stop(cb, now) end

-- Turns -------------------------------------------------------------------------------------

function Handle:_prompt(text)
  return self.client:request('session/prompt', { sessionId = self.sid, prompt = { { type = 'text', text = text } } },
    function(err, result)
      if err and err.code == 'exit' then return end -- the exit path ends the turn
      self:_actions(self.translator:result(err, result))
    end, false)
end

---Send a prompt; before the handshake is done it waits (in order) for it.
function Handle:prompt(text)
  if not self:alive() then return false end
  if not self.ready then
    self.waiting[#self.waiting + 1] = text
    return true
  end
  return self:_prompt(text)
end

---Cancel the running turn: the prompt request then answers `cancelled`. Open asks are
---answered as cancelled too, as the protocol asks.
function Handle:interrupt()
  if not self:alive() or not self.ready then return false end
  for id, respond in pairs(self.asks) do
    respond({ outcome = { outcome = 'cancelled' } })
    self.asks[id] = nil
  end
  return self.client:notify('session/cancel', { sessionId = self.sid })
end

---Answer the pending ask `p` with the agent's option for allow or deny (`opts.option_id`: one
---of the agent's other options, chosen by the user).
function Handle:answer(p, allow, opts)
  local respond = self.asks[p.request_id]
  if not respond then return false end
  self.asks[p.request_id] = nil
  local option = (opts and opts.option_id) or translate.pick_option(p.options, allow)
  if option == nil then
    respond({ outcome = { outcome = 'cancelled' } })
  else
    respond({ outcome = { outcome = 'selected', optionId = option } })
  end
  return true
end

-- Settings ----------------------------------------------------------------------------------

-- The agent refused a mode or model change: the transcript and the UI say so (as a refusal
-- of Claude's does through session/actions.lua).
function Handle:_refuse(what, field, value, err)
  local s = self.s
  local msg = tostring(type(err) == 'table' and (err.message or err.code) or err)
  if type(err) == 'table' and type(err.data) == 'table' and str(err.data.details) then msg = msg .. ': ' .. err.data.details end
  self.sink.action(live_meta('error', 'set_' .. what .. ': ' .. msg))
  if s[field] == value then
    s[field] = nil
    s:_emit('meta')
  end
  s.control_error = { what = what, value = value, error = msg }
  s:_emit('control_error')
end

function Handle:set_mode(mode)
  if not self:alive() then return false end
  if not self.ready then
    self.deferred[#self.deferred + 1] = { op = 'set_mode', value = mode }
    return true
  end
  local function done(err)
    if err then return self:_refuse('mode', 'mode_requested', mode, err) end
    self.sink.action({ type = 'status', mode = mode })
  end
  if self.config_ids.mode then
    return self.client:request('session/set_config_option', { sessionId = self.sid, configId = self.config_ids.mode, value = mode }, done)
  end
  return self.client:request('session/set_mode', { sessionId = self.sid, modeId = mode }, done)
end

function Handle:set_model(model)
  if not self:alive() then return false end
  if not self.ready then
    self.deferred[#self.deferred + 1] = { op = 'set_model', value = model }
    return true
  end
  local s = self.s
  local function done(err)
    if err then return self:_refuse('model', 'model_requested', model, err) end
    s.model, s.model_chosen = model, model
    if s.model_requested == model then s.model_requested = nil end
    s:_emit('meta')
  end
  if self.config_ids.model then
    return self.client:request('session/set_config_option', { sessionId = self.sid, configId = self.config_ids.model, value = model }, done)
  end
  return self.client:request('session/set_model', { sessionId = self.sid, modelId = model }, done)
end

---A setting deferred while no process ran (`M.setting`).
function Handle:send_setting(req) return self[req.op](self, req.value) end

-- Handshake ---------------------------------------------------------------------------------

function Handle:_actions(actions)
  for _, a in ipairs(actions) do self.sink.action(a) end
end

-- The agent could not be started for this session: say why, end the process (the exit path
-- marks a running turn failed).
function Handle:_fail(what, err)
  local msg = tostring(type(err) == 'table' and (err.message or err.code) or err)
  if type(err) == 'table' and type(err.data) == 'table' and str(err.data.details) then msg = msg .. ': ' .. err.data.details end
  local names = {}
  for _, a in ipairs(list(self.auth)) do names[#names + 1] = str(a.name) or str(a.id) end
  if what ~= 'initialize' and #names > 0 then msg = msg .. ' (the agent offers: ' .. table.concat(names, ', ') .. ')' end
  self.sink.action(live_meta('error', ('%s: %s'):format(what, msg)))
  self.client:stop(nil, true)
end

local function option_list(options, id_key, name_key)
  local out = {}
  for _, o in ipairs(list(options)) do
    if type(o) == 'table' and o[id_key] ~= nil then
      out[#out + 1] = { id = tostring(o[id_key]), name = str(o[name_key]) or tostring(o[id_key]), description = str(o.description) }
    end
  end
  return out
end

-- The session exists: what the agent offers (modes, models, as `modes`/`models` objects or as
-- config options), then the `init` action, then what waited for the handshake.
function Handle:_ready(r, loaded)
  local s = self.s
  r = type(r) == 'table' and r or {}
  if not loaded and str(r.sessionId) then s.agent_session_id = r.sessionId end
  self.sid = s.agent_session_id
  local mode, model
  if type(r.modes) == 'table' then
    s.capabilities.modes = true
    mode = str(r.modes.currentModeId)
    s.modes = option_list(r.modes.availableModes, 'id', 'name')
  end
  if type(r.models) == 'table' then
    s.capabilities.models = true
    model = str(r.models.currentModelId)
    s.models = vim.tbl_map(function(m) return { value = m.id, name = m.name, description = m.description } end,
      option_list(r.models.availableModels, 'modelId', 'name'))
  end
  for _, o in ipairs(list(r.configOptions)) do
    if type(o) == 'table' and (o.category == 'mode' or o.id == 'mode') then
      self.config_ids.mode = o.id
      s.capabilities.modes = true
      mode = str(o.currentValue)
      s.modes = option_list(o.options, 'value', 'name')
    elseif type(o) == 'table' and (o.category == 'model' or o.id == 'model') then
      self.config_ids.model = o.id
      s.capabilities.models = true
      model = str(o.currentValue)
      s.models = vim.tbl_map(function(m) return { value = m.id, name = m.name, description = m.description } end,
        option_list(o.options, 'value', 'name'))
    end
  end
  self.sink.action({ type = 'init', session_id = self.sid, model = model, mode = mode,
    slash_commands = self.commands or {}, version = self.agent_info and str(self.agent_info.version) or nil })
  self.ready = true
  if self.on_ready then self.on_ready(loaded) end
  local deferred, waiting = self.deferred, self.waiting
  self.deferred, self.waiting = {}, {}
  for _, d in ipairs(deferred) do self:send_setting(d) end
  for _, text in ipairs(waiting) do self:_prompt(text) end
end

function Handle:_open_session()
  local s = self.s
  local load = s.agent_session_id ~= nil and s.capabilities.resume
  local method = load and 'session/load' or 'session/new'
  local params = { cwd = s.cwd, mcpServers = {} }
  if load then params.sessionId = s.agent_session_id end
  self.replaying = load -- the load replays the conversation; the log has it already
  self.client:request(method, params, function(err, r)
    self.replaying = false
    if err and load then
      -- the agent cannot bring the session back: a new one, with the history from the log
      s.agent_session_id = nil
      if self.on_load_failed then self.on_load_failed(err) end
      return self:_open_session()
    end
    if err then return self:_fail(method, err) end
    self:_ready(r, load)
  end, M.HANDSHAKE_MS)
end

function Handle:_handshake(fs_on)
  self.client:request('initialize', {
    protocolVersion = M.PROTOCOL_VERSION,
    clientCapabilities = { fs = { readTextFile = fs_on, writeTextFile = fs_on }, terminal = false },
    clientInfo = M.CLIENT_INFO,
  }, function(err, result)
    if err then return self:_fail('initialize', err) end
    result = type(result) == 'table' and result or {}
    local caps = type(result.agentCapabilities) == 'table' and result.agentCapabilities or {}
    self.s.capabilities.resume = caps.loadSession == true
    self.auth, self.agent_info = result.authMethods, result.agentInfo
    self:_open_session()
  end, M.HANDSHAKE_MS)
end

-- Incoming ----------------------------------------------------------------------------------

function Handle:_update(params)
  local u = type(params) == 'table' and params.update or nil
  if type(u) == 'table' and u.sessionUpdate == 'available_commands_update' then
    local names = {}
    for _, c in ipairs(list(u.availableCommands)) do names[#names + 1] = str(c.name) end
    self.commands = names
  end
  if self.replaying then return end -- the raw view keeps the replay; the events are in the log
  self:_actions(self.translator:update(u, self.last_raw or vim.json.encode(params)))
end

function Handle:_permission(params, respond)
  if type(params) ~= 'table' then return respond(nil, { code = -32602, message = 'invalid params' }) end
  self.ask_n = self.ask_n + 1
  local a = self.translator:permission('p' .. self.ask_n, params)
  self.asks[a.request_id] = respond
  self.sink.action(a)
end

-- Adapter -----------------------------------------------------------------------------------

local function child_env(extra)
  if type(extra) ~= 'table' or next(extra) == nil then return nil end
  local env = vim.fn.environ()
  for k, v in pairs(extra) do env[k] = v end
  return env
end

---The adapter of ACP agent `name` configured as `cfg`.
---@param name string
---@param cfg table { cmd, env?, fs?, replay_context?, label? }
---@return table adapter
function M.new(name, cfg)
  local A = {}
  A.name = name
  A.label = str(cfg.label) or name
  A.cfg = cfg
  A.capabilities = {
    resume = false, modes = false, models = false, commands = false, interrupt = true, quota = false,
    native = false, live = false, transcript = false, images = false,
  }
  A.confirm_stop_text = A.label .. ' is still working in this session. Stop it?'

  ---The agent's mode names are its own.
  function A.plugin_mode(m) return m end

  ---A setting asked for while no process runs, kept until the next start.
  function A.setting(op, value) return { op = op, value = value } end

  ---Start the agent for Session `s`; the handshake runs in the background, a prompt sent
  ---meanwhile waits for it.
  ---@param s table Session
  ---@param sink table
  ---@return table|nil handle, string|nil err
  function A.start(s, sink)
    local fs_scope = cfg.fs == nil and 'cwd' or cfg.fs
    local handle = setmetatable({ s = s, sink = sink, translator = translate.new(), ready = false, waiting = {},
      deferred = {}, asks = {}, ask_n = 0, config_ids = {} }, Handle)
    local function mine() return s.proc == handle end
    local c, err = client_mod.start(cfg.cmd, {
      cwd = s.cwd,
      env = child_env(cfg.env),
      on_raw = function(dir, line)
        if dir == 'in' then handle.last_raw = line end
        sink.raw(dir, line)
      end,
      on_garbage = function(line) if mine() then sink.garbage(line) end end,
      on_exit = function(code, _, tail)
        if mine() then sink.exit(code, tail) end
      end,
    })
    if not c then return nil, ('cannot start %s: %s'):format(A.label, tostring(err)) end
    handle.client, handle.pid = c, c.pid
    c:on_notification('session/update', function(params) if mine() then handle:_update(params) end end)
    c:on_request('session/request_permission', function(params, respond)
      if mine() then handle:_permission(params, respond) else respond(nil, { code = -32000, message = 'session gone' }) end
    end)
    if fs_scope ~= false then
      c:on_request('fs/read_text_file', fs.read_handler(fs_scope, s.cwd))
      c:on_request('fs/write_text_file', fs.write_handler(fs_scope, s.cwd))
    end
    c:on_unhandled(function(msg)
      if not mine() then return end
      local ok, raw = pcall(vim.json.encode, msg)
      sink.action({ type = 'unknown', label = str(msg.method) or 'response', raw = ok and raw or tostring(msg) })
    end)
    -- the handshake starts once `s.proc` is this handle (the caller sets it right after)
    vim.schedule(function() if mine() then handle:_handshake(fs_scope ~= false) end end)
    return handle
  end

  ---History of a past session: the plugin's own log (agents/log.lua).
  function A.history(s, cb)
    require('agent-ide.agents.log').history(s, cb)
  end

  return A
end

M._Handle = Handle
return M
