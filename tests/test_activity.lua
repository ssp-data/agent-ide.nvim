-- The activity of a session's turn (session/activity.lua) and the queue panel's section that
-- shows it (ui/queue_activity.lua): requests, subagents, their context and tools. Pure.
local activity = require('agent-ide.session.activity')
local qa = require('agent-ide.ui.queue_activity')
local queue = require('agent-ide.ui.queue')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function agent_call(id, desc, kind, bg)
  return { kind = 'tool_call', id = id, name = 'Agent',
    input = { description = desc, subagent_type = kind, run_in_background = bg } }
end

T['tracker: requests counted once per message, agents sized by their own messages, ended by their result'] = function()
  local act = activity.new()
  activity.turn(act, 1000)
  activity.call(act, { id = 'm1', tokens = 400000, tools = { 'Agent', 'Agent' } })
  activity.call(act, { id = 'm1', tokens = 400000, tools = {} }) -- the same message, another part
  activity.event(act, agent_call('a1', 'find callers', 'Explore'), 1000)
  activity.event(act, agent_call('a2', 'rewrite test', 'general-purpose'), 1000)
  activity.call(act, { parent = 'a1', id = 's1', tokens = 58000, tools = { 'Grep', 'Read' } })
  activity.call(act, { parent = 'a2', id = 's2', tokens = 97000, tools = { 'Bash' } })
  activity.event(act, { kind = 'tool_call', id = 'x', name = 'Grep', sidechain = true }, 1500) -- inside an agent: no agent
  activity.event(act, { kind = 'tool_result', id = 'a1' }, 4000)
  eq({ act.calls, act.agent_calls }, { 1, 2 })
  local list, running = activity.agents(act)
  eq(running, 1)
  eq(vim.tbl_map(function(a) return { a.kind, a.desc, a.tokens, a.tools, a.status, a.tool } end, list), {
    { 'Explore', 'find callers', 58000, 2, 'done' },
    { 'general-purpose', 'rewrite test', 97000, 1, 'running', 'Bash' },
  })
  eq(list[1].ended - list[1].started, 3000)
  -- the next turn: counts start again, the finished agent goes, the running one stays
  activity.turn(act, 9000)
  eq({ act.calls, #act.order, act.order[1] }, { 0, 1, 'a2' })
end

T['tracker: a background agent ends with its task, not with the tool result that launched it'] = function()
  local act = activity.new()
  activity.turn(act, 0)
  activity.event(act, agent_call('b', 'scan', 'Explore', true), 0)
  activity.task(act, { tool = 'b', status = 'started' }, 0)
  activity.event(act, { kind = 'tool_result', id = 'b' }, 10)
  eq(act.agents.b.status, 'running')
  activity.task(act, { tool = 'b', status = 'completed', tool_uses = 7 }, 5000)
  eq({ act.agents.b.status, act.agents.b.tools, act.agents.b.ended }, { 'done', 7, 5000 })
  activity.task(act, { tool = 'nope', status = 'failed' }, 1) -- unknown: ignored
end

T['replay: the last turn of a transcript gives its agents, without sizes'] = function()
  local act = activity.replay({
    { kind = 'prompt', text = 'old' }, agent_call('o', 'old one', 'Plan'), { kind = 'tool_result', id = 'o' },
    { kind = 'prompt', text = 'new' }, agent_call('n', 'new one', 'Explore'),
    { kind = 'prompt', text = 'inside', sidechain = true },
  })
  eq(act.order, { 'n' })
  eq(act.started, nil)
end

T['section: size with the large mark, the turn, agents with their tool or duration; cut to the width'] = function()
  local act = activity.new()
  activity.turn(act, 0)
  activity.call(act, { id = 'm', tokens = 1, tools = {} })
  activity.event(act, agent_call('a1', 'find the fold callers everywhere', 'Explore'), 0)
  activity.call(act, { parent = 'a1', id = 's', tokens = 58000, tools = { 'Grep' } })
  activity.event(act, agent_call('a2', 'plan', 'Plan'), 1000)
  activity.event(act, { kind = 'tool_result', id = 'a2' }, 124000)
  local s = { state = 'busy', turn_start = 1, queue = {}, context_tokens = 412000, activity = act,
    events = { { kind = 'prompt', text = 'go' } } }
  local l = queue.layout(s, 36, { busy = 'B' }, { now = 372000, large = 200000 })
  eq(vim.list_slice(l.lines, 3), {
    '', ('─'):rep(35), 'Session  ~412k  ▲ large', '  turn 6m12s · 1 request',
    '', 'Agents · 1 running · 1 done · 1 req', 'B Explore  find the fold callers e…', '    ~58k · 1 tool · Grep',
    '✓ Plan  plan', '    2m03s',
  })
  for _, w in ipairs(l.lines) do eq(vim.fn.strdisplaywidth(w) <= 35, true) end
  eq(l.rows[9], { kind = 'agent', id = 'a1' })
  -- below `large`, or `large = false`: no mark; no activity argument: no section at all
  s.context_tokens = 1000
  eq(queue.layout(s, 36, {}, { now = 0, large = 200000 }).lines[5], 'Session  ~1k')
  s.context_tokens = 900000
  eq(queue.layout(s, 36, {}, { now = 0, large = false }).lines[5], 'Session  ~900k')
  eq(#queue.layout(s, 36, {}).lines, 2)
end

T['section: a session not run here shows its last turn agents as finished, no turn line'] = function()
  local s = { state = 'parked', turn_start = 1, queue = {}, events = {
    { kind = 'prompt', text = 'go' }, agent_call('a', 'look', 'Explore') } }
  local lines = queue.layout(s, 36, {}, { now = 0 }).lines
  eq(vim.list_slice(lines, 5), { 'Session', '', 'Agents · 0 running · 1 done', '✓ Explore  look' })
end

T['duration'] = function()
  eq({ qa.duration(45000), qa.duration(372000), qa.duration(3720000) }, { '45s', '6m12s', '1h02m' })
end

return T
