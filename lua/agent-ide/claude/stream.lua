-- Stream decoder: turns the objects `claude -p --output-format stream-json` prints into a
-- small set of Actions (see docs/protocol.md, "Decoder mapping"). Pure: no I/O, no timers.
-- Nothing is dropped silently: an object that is not understood becomes an `unknown` action.
local parse = require('agent-ide.transcript.parse')

local M = {}

-- `default` is what Claude calls the mode the plugin calls `manual`.
local function mode_name(m)
  if type(m) ~= 'string' then return nil end
  return m == 'default' and 'manual' or m
end

local function str(v) return type(v) == 'string' and v or nil end

-- A subagent's objects name the tool call that started it. Tested by type, so a caller that
-- decodes JSON null as vim.NIL still gets main-thread objects.
local function is_sidechain(obj) return type(obj.parent_tool_use_id) == 'string' end

-- Stream events that carry nothing the plugin shows: the full message follows anyway.
local QUIET_STREAM = {
  message_start = true, content_block_stop = true, message_delta = true, message_stop = true,
}
local QUIET_DELTA = { input_json_delta = true, thinking_delta = true, signature_delta = true }
-- System subtypes that carry nothing to show (a running estimate, an announcement; the list of
-- background tasks repeats what their own task_* objects say).
local QUIET_SYSTEM = { thinking_tokens = true, background_tasks_changed = true }

local Decoder = {}
Decoder.__index = Decoder

function M.new()
  -- streamed: a text delta of the current content block has been delivered.
  -- tool_ids: ids of tool_use blocks already reported.
  -- tasks: task id -> { name, quiet } for the task_* objects (quiet: a foreground task).
  return setmetatable({ streamed = false, tool_ids = {}, tasks = {} }, Decoder)
end

local function unknown(label, raw)
  return { type = 'unknown', label = label, raw = raw }
end

local function label_of(obj)
  if type(obj) ~= 'table' or type(obj.type) ~= 'string' then return '?' end
  local sub_t = obj.subtype
  if obj.type == 'stream_event' and type(obj.event) == 'table' then sub_t = obj.event.type end
  if obj.type == 'control_request' and type(obj.request) == 'table' then sub_t = obj.request.subtype end
  if type(sub_t) == 'string' and sub_t ~= '' then return obj.type .. '/' .. sub_t end
  return obj.type
end

local function event_actions(evs, sidechain, streamed)
  local out = {}
  for _, ev in ipairs(evs) do
    if sidechain then ev.sidechain = true end
    local a = { type = 'event', event = ev }
    if streamed and ev.kind == 'text' then a.streamed = true end
    out[#out + 1] = a
  end
  return out
end

local function duration(ms)
  if ms < 1000 then return ('%dms'):format(ms) end
  local secs = math.floor(ms / 1000)
  if secs < 60 then return ('%ds'):format(secs) end
  return ('%dm %ds'):format(math.floor(secs / 60), secs % 60)
end

local function task_event(label, lines)
  return { { type = 'event', event = { kind = 'meta', label = label, text = table.concat(lines, '\n') } } }
end

-- task_started, task_updated, task_notification: a background task (an async subagent, a shell
-- run in the background) as folds named by its description. A foreground task is a tool call
-- whose own fold shows it, so it and its later objects are quiet.
function Decoder:task(obj, st)
  local id = str(obj.task_id) or '?'
  if st == 'task_started' then
    local quiet = obj.is_backgrounded == false
    local name = str(obj.description) or id
    self.tasks[id] = { name = name, quiet = quiet }
    if quiet then return {} end
    local kind, notes = str(obj.subagent_type), {}
    if kind and obj.task_type then notes[#notes + 1] = tostring(obj.task_type) end
    kind = kind or str(obj.task_type) or 'task'
    if obj.is_backgrounded == true then notes[#notes + 1] = 'in the background' end
    if type(obj.spawn_depth) == 'number' and obj.spawn_depth > 0 then
      notes[#notes + 1] = 'depth ' .. obj.spawn_depth
    end
    local lines = { #notes > 0 and ('%s (%s)'):format(kind, table.concat(notes, ', ')) or kind }
    if str(obj.prompt) then lines[#lines + 1] = 'prompt: ' .. obj.prompt end
    local ids = { 'task ' .. id }
    if str(obj.run_id) then ids[#ids + 1] = 'run ' .. obj.run_id end
    if str(obj.tool_use_id) then ids[#ids + 1] = 'tool call ' .. obj.tool_use_id end
    lines[#lines + 1] = table.concat(ids, ', ')
    return task_event('task started: ' .. name, lines)
  end
  local task = self.tasks[id] or { name = id }
  if task.quiet then return {} end
  if st == 'task_updated' then
    local patch = type(obj.patch) == 'table' and obj.patch or {}
    local lines, keys = {}, vim.tbl_keys(patch)
    table.sort(keys)
    for _, k in ipairs(keys) do
      if k ~= 'status' then lines[#lines + 1] = ('%s: %s'):format(k, (vim.inspect(patch[k]):gsub('^"(.*)"$', '%1'))) end
    end
    return task_event(('task %s: %s'):format(str(patch.status) or 'updated', task.name), lines)
  end
  local lines = {}
  if str(obj.summary) then lines[#lines + 1] = obj.summary end
  local u = type(obj.usage) == 'table' and obj.usage or {}
  local usage = {}
  if type(u.total_tokens) == 'number' then usage[#usage + 1] = u.total_tokens .. ' tokens' end
  if type(u.tool_uses) == 'number' then usage[#usage + 1] = u.tool_uses .. ' tool uses' end
  if type(u.duration_ms) == 'number' then usage[#usage + 1] = duration(u.duration_ms) end
  if #usage > 0 then lines[#lines + 1] = table.concat(usage, ', ') end
  if str(obj.output_file) then lines[#lines + 1] = 'output: ' .. obj.output_file end
  return task_event(('task %s: %s'):format(str(obj.status) or 'done', task.name), lines)
end

function Decoder:system(obj, raw)
  local st = obj.subtype
  if st == 'init' then
    return { {
      type = 'init',
      session_id = str(obj.session_id),
      model = str(obj.model),
      mode = mode_name(obj.permissionMode),
      slash_commands = type(obj.slash_commands) == 'table' and obj.slash_commands or {},
      version = str(obj.claude_code_version),
    } }
  elseif st == 'status' then
    local a = { type = 'status', mode = mode_name(obj.permissionMode) }
    if obj.status == 'requesting' then a.busy = true end
    return { a }
  elseif st == 'hook_started' or st == 'hook_response' then
    local failed = obj.outcome == 'error'
      or (type(obj.exit_code) == 'number' and obj.exit_code ~= 0)
      or obj.error ~= nil
    if not failed then return {} end
    local detail = raw
    for _, v in ipairs({ obj.stderr, obj.output, obj.error }) do
      if type(v) == 'string' and v ~= '' then detail = v; break end
    end
    local name = str(obj.hook_name) or 'hook'
    return { { type = 'event', event = { kind = 'meta', label = 'hook', text = name .. ': ' .. detail } } }
  elseif st == 'task_started' or st == 'task_updated' or st == 'task_notification' then
    return self:task(obj, st)
  elseif st == 'compact_boundary' then
    -- the conversation was summarized (/compact, or Claude on its own near the limit): the
    -- same meta fold the transcript parser makes of the record, and the sizes when given
    local m = type(obj.compact_metadata) == 'table' and obj.compact_metadata or {}
    local pre = type(m.pre_tokens) == 'number' and m.pre_tokens or nil
    local post = type(m.post_tokens) == 'number' and m.post_tokens or nil
    local text = type(obj.content) == 'string' and obj.content
    if not text then
      text = 'conversation compacted' .. (str(m.trigger) and (' (' .. m.trigger .. ')') or '')
        .. (pre and (', ' .. require('agent-ide.claude.usage').fmt(pre) .. ' tokens before') or '')
    end
    return {
      { type = 'event', event = { kind = 'meta', label = 'system: compact_boundary', text = text } },
      { type = 'compact', trigger = str(m.trigger), pre_tokens = pre, post_tokens = post },
    }
  elseif QUIET_SYSTEM[st] then
    return {}
  end
  return { unknown(label_of(obj), raw) }
end

function Decoder:stream_event(obj, raw)
  local ev = obj.event
  if type(ev) ~= 'table' then return { unknown(label_of(obj), raw) } end
  local et = ev.type
  if et == 'content_block_start' then
    -- Only a main-thread block starts a new main text block.
    if not is_sidechain(obj) then self.streamed = false end
    return {}
  elseif et == 'content_block_delta' then
    local d = ev.delta
    local dt = type(d) == 'table' and d.type or nil
    if dt == 'text_delta' and type(d.text) == 'string' then
      -- Subagent messages arrive whole; their deltas would interleave with the main text.
      if is_sidechain(obj) then return {} end
      self.streamed = true
      return { { type = 'delta', text = d.text } }
    elseif QUIET_DELTA[dt] then
      return {}
    end
    return { unknown('stream_event/content_block_delta/' .. tostring(dt), raw) }
  elseif QUIET_STREAM[et] then
    return {}
  end
  return { unknown(label_of(obj), raw) }
end

function Decoder:assistant(obj, raw)
  if type(obj.message) ~= 'table' then return { unknown('assistant', raw) } end
  local sidechain = is_sidechain(obj)
  local evs = parse.message_events({ type = 'assistant', message = obj.message }, raw)
  if obj.local_command_run ~= nil then
    -- Output of a local slash command (e.g. /context), sent as a synthetic message.
    for i, ev in ipairs(evs) do
      if ev.kind == 'text' then evs[i] = { kind = 'meta', label = 'command output', text = ev.text } end
    end
  end
  local kept = {}
  for _, ev in ipairs(evs) do
    if ev.kind == 'tool_call' and type(ev.id) == 'string' then
      if not self.tool_ids[ev.id] then
        self.tool_ids[ev.id] = true
        kept[#kept + 1] = ev
      end
    else
      kept[#kept + 1] = ev
    end
  end
  local streamed = self.streamed and not sidechain
  if streamed then self.streamed = false end
  local acts = event_actions(kept, sidechain, streamed)
  -- the input of this request (cached or not): the size of the conversation. Not from a
  -- subagent (its own context) nor a synthetic message (a local command's output)
  if not sidechain and obj.local_command_run == nil and obj.message.model ~= '<synthetic>' then
    local n = require('agent-ide.claude.usage').context(obj.message.usage)
    if n then acts[#acts + 1] = { type = 'context', tokens = n } end
  end
  return acts
end

local function replay_text(content)
  if type(content) == 'string' then return content end
  local parts = {}
  for _, b in ipairs(content) do
    if type(b) == 'table' and b.type == 'text' and type(b.text) == 'string' then parts[#parts + 1] = b.text end
  end
  return table.concat(parts, '\n')
end

function Decoder:user(obj, raw)
  local msg = obj.message
  if type(msg) ~= 'table' or (type(msg.content) ~= 'string' and type(msg.content) ~= 'table') then
    return { unknown('user', raw) }
  end
  local c = msg.content
  local command_out = type(c) == 'string' and c:match('^%s*<local%-command%-stdout>') ~= nil
  if obj.isReplay == true and not command_out then
    return { { type = 'echo', text = replay_text(c) } }
  end
  -- Everything else in a user message comes from Claude itself (tool results, command
  -- output, interrupt markers), never from the person typing: no `prompt` events.
  local evs = parse.message_events({ type = 'user', isMeta = true, message = msg }, raw)
  local acts = event_actions(evs, is_sidechain(obj), false)
  -- output of a command Claude ran itself, e.g. for our set_model (the Session records it)
  if command_out then
    for _, a in ipairs(acts) do a.command_stdout = true end
  end
  return acts
end

function Decoder:control_request(obj, raw)
  local r = obj.request
  if type(r) == 'table' and r.subtype == 'can_use_tool' then
    return { {
      type = 'permission',
      request_id = obj.request_id,
      tool_name = r.tool_name,
      input = type(r.input) == 'table' and r.input or {},
      description = r.description,
      suggestions = r.permission_suggestions,
    } }
  end
  return { unknown(label_of(obj), raw) }
end

function Decoder:control_response(obj, raw)
  local r = obj.response
  if type(r) ~= 'table' then return { unknown('control_response', raw) } end
  if r.subtype == 'success' then
    return { { type = 'control_ok', request_id = r.request_id, response = r.response } }
  elseif r.subtype == 'error' then
    return { { type = 'control_error', request_id = r.request_id, error = r.error } }
  end
  return { unknown(label_of(obj), raw) }
end

function Decoder:rate_limit_event(obj, raw)
  local info = obj.rate_limit_info
  local uw = type(info) == 'table' and info.unifiedWindows or nil
  if type(uw) ~= 'table' then return { unknown('rate_limit_event', raw) } end
  local windows = {}
  for name, w in pairs(uw) do
    if type(w) == 'table' then
      windows[name] = { utilization = w.utilization, resets_at = w.resetsAt }
    end
  end
  return { { type = 'quota', windows = windows } }
end

function Decoder:result(obj)
  self.streamed = false
  local text = str(obj.result)
  if not text and type(obj.errors) == 'table' then
    local parts = {}
    for _, e in ipairs(obj.errors) do
      if type(e) == 'string' then parts[#parts + 1] = e end
    end
    if #parts > 0 then text = table.concat(parts, '\n') end
  end
  return { { type = 'result', is_error = obj.is_error == true, text = text } }
end

local HANDLERS = {
  system = Decoder.system,
  stream_event = Decoder.stream_event,
  assistant = Decoder.assistant,
  user = Decoder.user,
  control_request = Decoder.control_request,
  control_response = Decoder.control_response,
  rate_limit_event = Decoder.rate_limit_event,
  result = Decoder.result,
}

---Actions for one decoded stream object. Never raises.
---@param obj any decoded JSON (decode with `parse.DECODE_OPTS`)
---@param raw string|nil original line, kept in `unknown` actions
---@return table[] actions
function Decoder:feed(obj, raw)
  if type(raw) ~= 'string' then
    local ok, s = pcall(vim.json.encode, obj)
    raw = ok and s or tostring(obj)
  end
  local handler = type(obj) == 'table' and HANDLERS[obj.type] or nil
  if not handler then return { unknown(label_of(obj), raw) } end
  local ok, out = pcall(handler, self, obj, raw)
  if not ok or type(out) ~= 'table' then return { unknown(label_of(obj), raw) } end
  return out
end

return M
