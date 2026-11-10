-- Test helper for the scriptable fake ACP agent (tests/fake_acp.lua): scenarios, its log, and
-- the synthetic ACP shapes the adapter tests use (docs/protocol-acp.md, field names only).
local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

---Write the scenario (list of JSON strings or tables) and return the value for an agent's
---`cmd` plus the path of the log file the fake appends to (exported through FAKE_ACP_LOG).
---@param scenario_lines (string|table)[]
---@return string[] cmd, string log_path
function M.cmd(scenario_lines)
  local path, log = vim.fn.tempname() .. '.jsonl', vim.fn.tempname() .. '.log'
  local out = {}
  for i, l in ipairs(scenario_lines) do out[i] = type(l) == 'string' and l or vim.json.encode(l) end
  vim.fn.writefile(out, path)
  vim.uv.os_setenv('FAKE_ACP_LOG', log)
  return { vim.v.progpath, '-l', root .. '/tests/fake_acp.lua', path }, log
end

---@param log_path string
---@return table[] decoded log lines (empty when the file does not exist yet)
function M.log(log_path)
  if vim.fn.filereadable(log_path) == 0 then return {} end
  local out = {}
  for _, l in ipairs(vim.fn.readfile(log_path, 'b')) do
    if l ~= '' then out[#out + 1] = vim.json.decode(l, { luanil = { object = true } }) end
  end
  return out
end

---Input lines the fake received, decoded, in order.
---@param log_path string
---@return table[]
function M.ins(log_path)
  local out = {}
  for _, l in ipairs(M.log(log_path)) do
    if l['in'] then out[#out + 1] = vim.json.decode(l['in'], { luanil = { object = true } }) end
  end
  return out
end

---The input lines whose `method` is `method`.
function M.sent(log_path, method)
  return vim.tbl_filter(function(m) return m.method == method end, M.ins(log_path))
end

-- Shapes -------------------------------------------------------------------------------------

---The `initialize` answer of an agent; `opts.load` (default true): `loadSession`.
function M.init_result(opts)
  opts = opts or {}
  return { protocolVersion = 1, agentInfo = { name = 'fake-acp', version = '0.1' },
    authMethods = opts.auth or {},
    agentCapabilities = { loadSession = opts.load ~= false, promptCapabilities = { image = false, embeddedContext = true } } }
end

---The `session/new` answer: `modes` and `models` as Gemini sends them (`opts.modes = false`
---leaves them out; `opts.config = true` sends opencode's `configOptions` instead).
function M.new_result(opts)
  opts = opts or {}
  local r = { sessionId = opts.sid or 'fake-session-1' }
  if opts.config then
    r.configOptions = {
      { id = 'model', name = 'Model', category = 'model', type = 'select', currentValue = 'prov/m-small',
        options = { { value = 'prov/m-small', name = 'prov/M small' }, { value = 'prov/m-big', name = 'prov/M big' } } },
      { id = 'mode', name = 'Session Mode', category = 'mode', type = 'select', currentValue = 'build',
        options = { { value = 'build', name = 'Build' }, { value = 'plan', name = 'Plan' } } },
    }
  elseif opts.modes ~= false then
    r.modes = { currentModeId = 'default', availableModes = {
      { id = 'default', name = 'Default', description = 'Prompts for approval' },
      { id = 'plan', name = 'Plan', description = 'Read-only mode' } } }
    r.models = { currentModelId = 'm-small', availableModels = {
      { modelId = 'm-small', name = 'M small' }, { modelId = 'm-big', name = 'M big', description = 'Bigger' } } }
  end
  return r
end

function M.chunk(text) return { update = { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = text } } } end
function M.thought(text) return { update = { sessionUpdate = 'agent_thought_chunk', content = { type = 'text', text = text } } } end
function M.commands(names)
  local list = {}
  for i, n in ipairs(names) do list[i] = { name = n, description = n .. ' it' } end
  return { update = { sessionUpdate = 'available_commands_update', availableCommands = list } }
end
function M.tool_call(id, title, kind, extra)
  return { update = vim.tbl_extend('force', { sessionUpdate = 'tool_call', toolCallId = id, title = title, kind = kind or 'execute',
    status = 'pending', content = {}, locations = {} }, extra or {}) }
end
function M.tool_update(id, status, extra)
  return { update = vim.tbl_extend('force', { sessionUpdate = 'tool_call_update', toolCallId = id, status = status }, extra or {}) }
end
function M.text_content(text) return { type = 'content', content = { type = 'text', text = text } } end
function M.diff_content(path, old, new) return { type = 'diff', path = path, oldText = old, newText = new } end

---A `session/request_permission` request for tool call `id` with Gemini's three options.
function M.permission(id, title, opts)
  return { request = { method = 'session/request_permission', params = { sessionId = 'fake-session-1',
    options = (opts and opts.options) or {
      { optionId = 'proceed_always', name = 'Allow for this session', kind = 'allow_always' },
      { optionId = 'proceed_once', name = 'Allow', kind = 'allow_once' },
      { optionId = 'cancel', name = 'Reject', kind = 'reject_once' } },
    toolCall = { toolCallId = id, title = title, status = 'pending', kind = (opts and opts.kind) or 'execute',
      content = {}, locations = {} } } } }
end

function M.end_turn(reason, extra)
  return { respond = vim.tbl_extend('force', { stopReason = reason or 'end_turn' }, extra or {}) }
end

---Steps of the handshake: initialize, then session/new answered with `new_result(opts)`.
function M.handshake(opts)
  return { { expect = '"initialize"' }, { respond = M.init_result(opts) }, { expect = '"session/new"' },
    { respond = M.new_result(opts) } }
end

---Steps and lists of steps, flattened into one scenario.
function M.flat(...)
  local out = {}
  for _, part in ipairs({ ... }) do
    if part[1] ~= nil then vim.list_extend(out, part) else out[#out + 1] = part end
  end
  return out
end

return M
