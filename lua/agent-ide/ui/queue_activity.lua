-- The bottom of the queue panel: how heavy the session is and what its turn does. The context
-- of the conversation (a mark from `context.large` tokens on), the requests the turn made and
-- how long it runs, and each subagent with its own context, tool uses and the tool it runs now.
-- From the session's activity (session/activity.lua); nothing asks the model. Pure.
local M = {}

local fmt = function(n) return require('agent-ide.claude.usage').fmt(n) end

---`45s`, `6m12s`, `1h02m`.
---@param ms number
---@return string
function M.duration(ms)
  local secs = math.max(0, math.floor(ms / 1000))
  if secs < 60 then return secs .. 's' end
  if secs < 3600 then return ('%dm%02ds'):format(math.floor(secs / 60), secs % 60) end
  return ('%dh%02dm'):format(math.floor(secs / 3600), math.floor(secs % 3600 / 60))
end

local function plural(n, one, many) return ('%d %s'):format(n, n == 1 and one or many) end

---Lines of the section for session `s`, appended to `out` ({ lines, hl, rows }, as
---`queue.layout` builds it); agent rows are `{ kind = 'agent', id = tool call id }`.
---@param out table
---@param s table Session
---@param width integer
---@param opts { icons: table, now: integer, large: integer|false|nil }
function M.append(out, s, width, opts)
  local activity = require('agent-ide.session.activity')
  local truncate = require('agent-ide.ui.layout').truncate
  local icons = opts.icons or {}
  local function add(text, group, row, spans)
    local n = #out.lines + 1
    out.lines[n] = truncate(text, width - 1)
    if group then out.hl[#out.hl + 1] = { line = n, col_start = 0, col_end = #out.lines[n], group = group } end
    for _, sp in ipairs(spans or {}) do
      if sp[2] <= #out.lines[n] then
        out.hl[#out.hl + 1] = { line = n, col_start = sp[1], col_end = math.min(sp[2], #out.lines[n]), group = sp[3] }
      end
    end
    out.rows[n] = row
  end
  local act = s.activity
  local live = act and act.started ~= nil
  if not live then act = activity.replay(s.events or {}) end
  -- nothing known yet (a new session): no section
  if not (live or s.context_tokens or #act.order > 0) then return end

  add('')
  add(('─'):rep(math.max(4, width - 1)), 'AgentIdeAge')
  local ctx = s.context_tokens
  local head = 'Session' .. (ctx and ('  ~' .. fmt(ctx)) or '')
  local spans = { { 0, 7, 'AgentIdeSection' } }
  if ctx and opts.large and ctx >= opts.large then
    spans[#spans + 1] = { #head, #head + #'  ▲ large', 'AgentIdeLarge' }
    head = head .. '  ▲ large'
  end
  add(head, nil, nil, spans)
  if live then
    -- every request reads the whole conversation again: their count is what a turn costs
    local stop = act.ended or opts.now
    add(('  turn %s · %s'):format(M.duration(stop - act.started), plural(act.calls, 'request', 'requests')), 'AgentIdeAge')
  end

  local agents = activity.agents(act)
  if #agents == 0 then return end
  local busy = s.state == 'busy' or s.state == 'waiting'
  -- from the transcript alone, an agent of a finished turn has finished
  local function status_of(a) return (a.status == 'running' and not busy and not live) and 'done' or a.status end
  local running = 0
  for _, a in ipairs(agents) do
    if status_of(a) == 'running' then running = running + 1 end
  end
  add('')
  local h = ('Agents · %d running'):format(running)
  if #agents > running then h = h .. (' · %d done'):format(#agents - running) end
  if live and act.agent_calls > 0 then h = h .. (' · %d req'):format(act.agent_calls) end
  add(h, 'AgentIdeSection')
  for _, a in ipairs(agents) do
    local status = status_of(a)
    local mark, group
    if status == 'running' then mark, group = icons.busy or '◐', 'AgentIdeBusy'
    elseif status == 'failed' then mark, group = '✗', 'AgentIdeFailed'
    else mark, group = '✓', 'AgentIdeAge' end
    local kind = a.kind .. (a.background and ' (bg)' or '')
    add(('%s %s  %s'):format(mark, kind, a.desc), nil, { kind = 'agent', id = a.id },
      { { 0, #mark, group }, { #mark + 1, #mark + 1 + #kind, 'AgentIdeSection' } })
    local info = {}
    if a.tokens then info[#info + 1] = '~' .. fmt(a.tokens) end
    if a.tools > 0 then info[#info + 1] = plural(a.tools, 'tool', 'tools') end
    if status == 'running' and a.tool then
      info[#info + 1] = a.tool
    elseif a.started and a.ended then
      info[#info + 1] = M.duration(a.ended - a.started)
    elseif status == 'running' and a.started then
      info[#info + 1] = M.duration(opts.now - a.started)
    end
    if #info > 0 then add('    ' .. table.concat(info, ' · '), 'AgentIdeAge', { kind = 'agent', id = a.id }) end
  end
end

return M
