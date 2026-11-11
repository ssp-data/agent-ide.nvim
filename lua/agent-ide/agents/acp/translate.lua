-- ACP messages -> the shared Actions (session/actions.lua), per docs/protocol-acp.md. Pure:
-- no I/O, no timers. Keeps the state of the running turn: the answer text streamed so far
-- (deltas, then one `text` event when the block ends), the thought chunks of one thinking
-- block, and the tool calls seen (one `tool_call` when first seen, one `tool_result` when it
-- completes or fails). Nothing is dropped silently: an update that is not understood becomes
-- an `unknown` action; `usage_update` is silent by design (numbers only; the raw view has it).
local M = {}

local Translator = {}
Translator.__index = Translator

---@return table translator
function M.new() return setmetatable({ text = '', thought = '', calls = {}, done = {} }, Translator) end

local function unknown(label, raw) return { type = 'unknown', label = label, raw = raw } end

local function str(v) return type(v) == 'string' and v or nil end

local function list(v) return type(v) == 'table' and vim.islist(v) and v or {} end

---Text of a tool call's `content[]`: text blocks as they are, a diff as `--- <path>` and
---`- ` / `+ ` lines (what an edit fold shows), anything else by its type.
---@param content table|nil
---@return string
function M.content_text(content)
  local parts = {}
  for _, c in ipairs(list(content)) do
    if type(c) ~= 'table' then
      parts[#parts + 1] = '[' .. type(c) .. ']'
    elseif c.type == 'content' and type(c.content) == 'table' and c.content.type == 'text' then
      parts[#parts + 1] = str(c.content.text) or ''
    elseif c.type == 'diff' then
      local lines = { '--- ' .. tostring(c.path or '?') }
      for _, l in ipairs(vim.split(str(c.oldText) or '', '\n', { plain = true })) do lines[#lines + 1] = '- ' .. l end
      for _, l in ipairs(vim.split(str(c.newText) or '', '\n', { plain = true })) do lines[#lines + 1] = '+ ' .. l end
      parts[#parts + 1] = table.concat(lines, '\n')
    else
      parts[#parts + 1] = '[' .. tostring(c.type) .. ']'
    end
  end
  return table.concat(parts, '\n')
end

---The input shown for a tool call: the agent's `rawInput` when it has one, else what the
---call's kind, title and first location say (`command` for a shell command, `file_path` for a
---file, `description` otherwise), so the fold header reads as a tool call does.
---@param u table the `tool_call` update
---@return table
function M.call_input(u)
  local input = {}
  local loc = list(u.locations)[1]
  local path = type(loc) == 'table' and str(loc.path) or nil
  if u.kind == 'execute' then
    input.command = str(u.title) or ''
  elseif path then
    input.file_path = path
    if str(u.title) and u.title ~= path then input.description = u.title end
  else
    input.description = str(u.title) or ''
  end
  if type(u.rawInput) == 'table' and next(u.rawInput) ~= nil then
    for k, v in pairs(u.rawInput) do input[k] = v end
  end
  return input
end

---The name of a tool call: the agent's `name`, else its `kind`, else `tool`.
function M.call_name(u) return str(u.name) or str(u.kind) or 'tool' end

-- The streamed answer so far becomes one text event (marked streamed: the Session clears
-- what it showed while streaming).
function Translator:flush_text(out)
  if self.text == '' then return end
  out[#out + 1] = { type = 'event', event = { kind = 'text', text = self.text }, streamed = true }
  self.text = ''
end

function Translator:flush_thought(out)
  if self.thought == '' then return end
  out[#out + 1] = { type = 'event', event = { kind = 'thinking', text = self.thought } }
  self.thought = ''
end

local function plan_text(u)
  local lines = {}
  for _, e in ipairs(list(u.entries)) do
    if type(e) == 'table' then
      lines[#lines + 1] = ('- [%s] %s%s'):format(tostring(e.status or '?'), tostring(e.content or ''),
        e.priority and (' (' .. tostring(e.priority) .. ')') or '')
    end
  end
  return table.concat(lines, '\n')
end

local U = {}

function U.agent_message_chunk(self, u, raw, out)
  local c = u.content
  if type(c) ~= 'table' or c.type ~= 'text' or type(c.text) ~= 'string' then
    out[#out + 1] = unknown('session/update/agent_message_chunk', raw)
    return
  end
  self:flush_thought(out)
  self.text = self.text .. c.text
  out[#out + 1] = { type = 'delta', text = c.text }
end

function U.agent_thought_chunk(self, u, raw, out)
  local c = u.content
  if type(c) ~= 'table' or c.type ~= 'text' or type(c.text) ~= 'string' then
    out[#out + 1] = unknown('session/update/agent_thought_chunk', raw)
    return
  end
  self:flush_text(out)
  self.thought = self.thought .. c.text
end

-- The agent repeating a user message (seen in a load replay, which the adapter skips): a
-- meta fold, never a prompt (the person did not type it now).
function U.user_message_chunk(self, u, raw, out)
  local c = u.content
  local text = type(c) == 'table' and str(c.text) or nil
  self:flush_text(out)
  self:flush_thought(out)
  out[#out + 1] = { type = 'event', event = { kind = 'meta', label = 'user message', text = text or raw } }
end

function U.tool_call(self, u, raw, out)
  local id = u.toolCallId
  if id == nil then
    out[#out + 1] = unknown('session/update/tool_call', raw)
    return
  end
  self:flush_text(out)
  self:flush_thought(out)
  id = tostring(id)
  if self.calls[id] then return U.tool_call_update(self, u, raw, out) end -- repeated (a replay)
  self.calls[id] = { content = u.content, status = u.status }
  out[#out + 1] = { type = 'event', event = { kind = 'tool_call', id = id, name = M.call_name(u), input = M.call_input(u) } }
  if u.status == 'completed' or u.status == 'failed' then U.tool_call_update(self, u, raw, out) end
end

function U.tool_call_update(self, u, raw, out)
  local id = u.toolCallId
  if id == nil then
    out[#out + 1] = unknown('session/update/tool_call_update', raw)
    return
  end
  id = tostring(id)
  local call = self.calls[id] or {}
  self.calls[id] = call
  if type(u.content) == 'table' and #u.content > 0 then call.content = u.content end
  if u.status ~= nil then call.status = u.status end
  if (u.status == 'completed' or u.status == 'failed') and not self.done[id] then
    self.done[id] = true
    self:flush_text(out)
    out[#out + 1] = { type = 'event', event = { kind = 'tool_result', id = id, text = M.content_text(call.content),
      is_error = u.status == 'failed' } }
  end
end

function U.plan(self, u, _, out)
  self:flush_text(out)
  out[#out + 1] = { type = 'event', event = { kind = 'meta', label = 'plan', text = plan_text(u) } }
end

function U.available_commands_update(_, u, _, out)
  local names = {}
  for _, c in ipairs(list(u.availableCommands)) do
    if type(c) == 'table' and str(c.name) then names[#names + 1] = c.name end
  end
  out[#out + 1] = { type = 'commands', slash_commands = names }
end

function U.current_mode_update(_, u, raw, out)
  if not str(u.currentModeId) then
    out[#out + 1] = unknown('session/update/current_mode_update', raw)
    return
  end
  out[#out + 1] = { type = 'status', mode = u.currentModeId }
end

function U.usage_update() end -- silent by design: context use in numbers; the raw view keeps it

---Actions for one `session/update` notification's `update` object.
---@param u any
---@param raw string the line as received (kept in `unknown` actions)
---@return table[] actions
function Translator:update(u, raw)
  local out = {}
  local kind = type(u) == 'table' and u.sessionUpdate or nil
  local h = type(kind) == 'string' and U[kind] or nil
  if not h then return { unknown('session/update/' .. tostring(kind), raw) } end
  local ok, err = pcall(h, self, u, raw, out)
  if not ok then return { unknown('session/update/' .. kind .. ': ' .. tostring(err), raw) } end
  return out
end

---The `permission` action of a `session/request_permission` request. `request_id` is the
---JSON-RPC id as a string; `options` are the agent's (`{ optionId, name, kind }`), `tool_name`
---and `input` read as a tool call.
---@param id any the JSON-RPC id
---@param params table
---@return table action
function Translator:permission(id, params)
  local tc = type(params.toolCall) == 'table' and params.toolCall or {}
  return { type = 'permission', request_id = tostring(id), tool_name = M.call_name(tc), input = M.call_input(tc),
    description = str(tc.title), options = list(params.options), tool_call_id = tc.toolCallId }
end

---The option id to answer an ask with: `allow` picks the first `allow_once` option (else any
---`allow_*`), deny the first `reject_once` (else any `reject_*`); nil when there is none.
---@param options table[]
---@param allow boolean
---@return string|nil
function M.pick_option(options, allow)
  local want = allow and 'allow_once' or 'reject_once'
  local prefix = allow and '^allow' or '^reject'
  local fallback
  for _, o in ipairs(list(options)) do
    if type(o) == 'table' and o.optionId ~= nil then
      if o.kind == want then return o.optionId end
      if not fallback and type(o.kind) == 'string' and o.kind:find(prefix) then fallback = o.optionId end
    end
  end
  return fallback
end

local OK_STOP = { end_turn = true, cancelled = true }

---Actions that end a turn: the answer to `session/prompt` (`err` a JSON-RPC error, else
---`result.stopReason`). Pending text and thoughts become their events first.
---@param err table|nil
---@param result any
---@return table[] actions
function Translator:result(err, result)
  local out = {}
  self:flush_thought(out)
  self:flush_text(out)
  self.calls, self.done = {}, {}
  if err then
    out[#out + 1] = { type = 'result', is_error = true, text = tostring(err.message or err.code or 'turn failed') }
    return out
  end
  local reason = type(result) == 'table' and str(result.stopReason) or nil
  if reason and OK_STOP[reason] then
    out[#out + 1] = { type = 'result', is_error = false }
  else
    out[#out + 1] = { type = 'result', is_error = true, text = 'Turn ended: ' .. tostring(reason or 'no stop reason') }
  end
  return out
end

M._Translator = Translator
return M
