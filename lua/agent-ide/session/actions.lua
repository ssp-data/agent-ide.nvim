-- How a Session reacts to decoded stream Actions and to the exit of its process.
local M = {}

local ECHO_WARNING = 'Prompt echoed by Claude differs from what was sent'

-- Events the session makes itself; they are never in Claude's transcript.
local function live_meta(label, text) return { kind = 'meta', label = label, text = text, live_only = true } end

local function clear_permissions(s)
  if #s.pending_permissions == 0 then return end
  s.pending_permissions = {}
  s:_emit('permission')
end

-- Claude started a turn by itself (e.g. after a background task): busy without a prompt.
local function turn_begins(s)
  if s.state ~= 'busy' and s.state ~= 'waiting' then s:_set_state('busy') end
end

local H = {}

local function plugin_mode(m) return m == 'default' and 'manual' or m end

-- Claude reports mode `m`: a request for it is fulfilled.
local function mode_is(s, m)
  s.mode = m
  if s.mode_requested == m then s.mode_requested = nil end
end

function H.init(s, a)
  s.model, s.slash_commands = a.model, a.slash_commands
  if s.cwd and type(a.slash_commands) == 'table' and #a.slash_commands > 0 then
    require('agent-ide.session')._commands_seen[s.cwd] = a.slash_commands -- for new sessions there
  end
  mode_is(s, a.mode)
  s:_emit('meta')
  turn_begins(s)
end

function H.status(s, a)
  if a.mode then
    mode_is(s, a.mode)
    s:_emit('meta')
  end
  if a.busy then turn_begins(s) end
end

function H.delta(s, a)
  s.streaming = s.streaming .. a.text
  s:_emit('delta')
end

-- Claude writes a model switch to the transcript as the user's `/model <name>` command, then
-- its output; the stream shows only the output. Record the command too (history equals live).
local function model_command(s)
  local id, req
  for rid, r in pairs(s.requests) do
    if r.subtype == 'set_model' and not r.recorded and (not id or tonumber(rid:sub(2)) < tonumber(id:sub(2))) then
      id, req = rid, r
    end
  end
  if not req then return end
  req.recorded = true
  s:_append({ kind = 'prompt', text = '/model ' .. tostring(req.model) })
end

function H.event(s, a)
  local ev = a.event
  ev.streamed = nil
  if a.streamed then s.streaming = '' end
  if a.command_stdout then model_command(s) end
  s:_append(ev)
end

function H.echo(s, a)
  local expected = s.echo_expected
  s.echo_expected = nil
  if expected == nil or a.text == expected then return end
  s:_append(live_meta('warning', ECHO_WARNING))
  if not s.echo_warned then
    s.echo_warned = true
    vim.notify('agent-ide: ' .. ECHO_WARNING, vim.log.levels.WARN)
  end
end

function H.permission(s, a)
  s.pending_permissions[#s.pending_permissions + 1] = {
    request_id = a.request_id, tool_name = a.tool_name, input = a.input,
    description = a.description, suggestions = a.suggestions,
  }
  s:_emit('permission')
  s:_set_state('waiting')
end

-- Answers to our own requests; anything else (e.g. Claude echoing our permission
-- answers) is informational only.
function H.control_ok(s, a)
  local req = s.requests[a.request_id]
  if not req then return end
  s.requests[a.request_id] = nil
  if req.subtype == 'set_model' then
    s.model = req.model
    if s.model_requested == req.model then s.model_requested = nil end
    s:_emit('meta')
  elseif req.subtype == 'set_permission_mode' then
    local m = type(a.response) == 'table' and type(a.response.mode) == 'string' and a.response.mode or req.mode
    mode_is(s, plugin_mode(m))
    s:_emit('meta')
  end
end

-- What a refused mode or model request was for: { field, value, what } (nil for others).
local SETTING = {
  set_permission_mode = function(req) return 'mode_requested', plugin_mode(req.mode), 'mode' end,
  set_model = function(req) return 'model_requested', req.model, 'model' end,
}

function H.control_error(s, a)
  local req = s.requests[a.request_id]
  if not req then return end
  s.requests[a.request_id] = nil
  s:_append(live_meta('error', req.subtype .. ': ' .. tostring(a.error)))
  local setting = SETTING[req.subtype]
  if not setting then return end
  local field, value, what = setting(req)
  if s[field] == value then
    s[field] = nil
    s:_emit('meta')
  end
  -- the UI tells the user (only for the session on screen)
  s.control_error = { what = what, value = value, error = a.error }
  s:_emit('control_error')
end

function H.quota(s, a)
  require('agent-ide.session')._set_quota(a.windows)
  s:_emit('quota')
end

function H.result(s, a)
  s:_flush_streaming()
  -- a mode sent with a permission answer is reported within the turn; never pending for ever
  if s.mode_by_answer then
    if s.mode_requested == s.mode_by_answer then
      s.mode_requested = nil
      s:_emit('meta')
    end
    s.mode_by_answer = nil
  end
  s.echo_expected = nil
  if a.is_error then s:_append(live_meta('error', a.text or 'Turn failed')) end
  clear_permissions(s)
  -- after an interrupt or while parking, the queue does not go on by itself
  local hold = s.interrupted or s.parking
  s.interrupted = false
  if not hold and #s.queue > 0 then
    local text = table.remove(s.queue, 1)
    s:_emit('meta')
    if s:_start_turn(text) then return end
  end
  s:_settle(a.is_error)
end

function H.unknown(s, a)
  s:_append({ kind = 'unknown', label = a.label, raw = a.raw, live_only = true })
end

---@param s table Session
---@param a table Action from the stream decoder
function M.handle(s, a)
  local h = H[a.type]
  if h then
    h(s, a)
  else
    s:_append({ kind = 'unknown', label = 'action/' .. tostring(a.type), raw = vim.inspect(a), live_only = true })
  end
end

---The session's process exited (stopped by park, crashed, or ended on its own).
---@param s table Session
---@param code integer
---@param tail string|nil stderr tail
function M.on_exit(s, code, tail)
  s.proc, s.owned, s.echo_expected, s.interrupted = nil, false, nil, false
  -- requests in flight die with the process (deferred ones were sent at its start)
  if s.mode_requested or s.model_requested then
    s.mode_requested, s.model_requested = nil, nil
    s:_emit('meta')
  end
  s:_flush_streaming()
  clear_permissions(s)
  local parking, cbs = s.parking, s.park_cbs
  s.parking, s.park_cbs = false, {}
  if parking then
    s:_set_state('parked')
  elseif s.state == 'busy' or s.state == 'waiting' then
    local text = ('Claude exited (code %s)'):format(tostring(code))
    tail = vim.trim(tail or '')
    if tail ~= '' then text = text .. '\n' .. tail end
    s:_append(live_meta('error', text))
    s:_settle(true)
  elseif s.state == 'idle' then
    s:_set_state('parked')
  end
  for _, cb in ipairs(cbs) do cb() end
end

return M
