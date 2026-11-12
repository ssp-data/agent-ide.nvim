-- The bottom of the queue panel: how heavy the session is and what its turn does. The context
-- of the conversation (a mark from `context.large` tokens on), a cache written again, the
-- turn's clock, requests, thinking and tokens, what the last turn weighed per model, Claude's
-- todo list, each subagent with its own context, tool uses and the tool it runs now, and the
-- shells running in the background. From the session's activity (session/activity.lua);
-- nothing asks the model. Pure.
local M = {}

local function fmt(n) return require('agent-ide.claude.usage').fmt(n) end

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

-- `claude-fable-5-1` → `fable-5-1`
local function short_model(m) return (tostring(m):gsub('^claude%-', '')) end

local function money(usd) return ('$%.2f'):format(usd) end

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
      if sp[1] < #out.lines[n] then
        out.hl[#out.hl + 1] = { line = n, col_start = sp[1], col_end = math.min(sp[2], #out.lines[n]), group = sp[3] }
      end
    end
    out.rows[n] = row
  end
  -- a header and its entries: mark, a bold-ish name, the rest; `info` dim on the next line
  local function entry(mark, mark_group, name, rest, row, info)
    local text = name and ('%s %s  %s'):format(mark, name, rest) or ('%s %s'):format(mark, rest)
    local spans = { { 0, #mark, mark_group } }
    if name then spans[2] = { #mark + 1, #mark + 1 + #name, 'AgentIdeSection' } end
    add(text, nil, row, spans)
    if info and #info > 0 then add('    ' .. table.concat(info, ' · '), 'AgentIdeAge', row) end
  end
  local function mark_of(status)
    if status == 'running' then return icons.busy or '◐', 'AgentIdeBusy' end
    if status == 'failed' then return '✗', 'AgentIdeFailed' end
    if status == 'stopped' then return '■', 'AgentIdeAge' end
    return '✓', 'AgentIdeAge'
  end

  local act = s.activity
  local live = act and act.started ~= nil
  if not live then act = activity.replay(s.events or {}) end
  local agents = activity.agents(act)
  local shells = live and activity.shells(act) or {}
  -- nothing known yet (a new session): no section
  if not (live or s.context_tokens or #agents > 0 or act.todos) then return end
  local busy = s.state == 'busy' or s.state == 'waiting'

  -- Session: size, cache, turn, tokens, last turn's models
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
    if act.rebuilt then add('  ⚠ cache written again ~' .. fmt(act.rebuilt), 'AgentIdeLarge') end
    -- every request reads the whole conversation again: their count is what a turn costs
    local stop = act.ended or opts.now
    local turn = ('  turn %s · %s'):format(M.duration(stop - act.started), plural(act.calls, 'request', 'requests'))
    add(turn, 'AgentIdeAge')
    if act.thinking and busy then add('  thinking ~' .. fmt(act.thinking), 'AgentIdeBusy') end
    if act.read + act.write + act.input + act.out > 0 then
      add(('  read %s · new %s · out %s'):format(fmt(act.read), fmt(act.write + act.input), fmt(act.out)), 'AgentIdeAge')
    end
    local last = act.last
    if last then
      local total = 0
      for _, m in ipairs(last.models or {}) do total = total + m.tokens end
      if last.cost then add('  ≈ ' .. money(last.cost) .. ' at API prices', 'AgentIdeAge') end
      for _, m in ipairs(last.models or {}) do
        local pct = total > 0 and math.floor(m.tokens / total * 100 + 0.5) or 0
        add(('  %s  %d%% · %s'):format(short_model(m.model), pct, fmt(m.tokens)), 'AgentIdeAge')
      end
    end
  end

  -- Todos: Claude's plan, the item it works on in its own words
  if act.todos and #act.todos > 0 then
    local done = 0
    for _, t in ipairs(act.todos) do
      if t.status == 'completed' then done = done + 1 end
    end
    add('')
    add(('Todos · %d/%d done'):format(done, #act.todos), 'AgentIdeSection')
    for _, t in ipairs(act.todos) do
      if t.status == 'completed' then add('✓ ' .. t.text, 'AgentIdeAge')
      elseif t.status == 'in_progress' then entry(icons.busy or '◐', 'AgentIdeBusy', nil, t.text)
      else add('○ ' .. t.text) end
    end
  end

  -- Agents
  if #agents > 0 then
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
      local mark, group = mark_of(status)
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
      entry(mark, group, a.kind .. (a.background and ' (bg)' or ''), a.desc, { kind = 'agent', id = a.id }, info)
    end
  end

  -- Shells: commands Claude runs in the background (servers, watchers, long tests)
  if #shells > 0 then
    local _, running = activity.shells(act)
    add('')
    add(('Shells · %d running'):format(running), 'AgentIdeSection')
    for _, sh in ipairs(shells) do
      local mark, group = mark_of(sh.status)
      local t = sh.started and M.duration((sh.ended or opts.now) - sh.started)
      entry(mark, group, nil, sh.desc .. (t and ('  ' .. t) or ''))
    end
  end
end

return M
