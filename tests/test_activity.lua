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

T['tracker: tokens summed per message (its parts overwrite), a cache written again, thinking until the message'] = function()
  local act = activity.new()
  activity.turn(act, 0, 395000) -- resumed: the conversation was 395k before
  activity.thinking(act, 8000)
  activity.call(act, { id = 'm', tokens = 400103, read = 100, write = 400000, input = 3, out = 10 })
  activity.call(act, { id = 'm', tokens = 400103, read = 100, write = 400000, input = 3, out = 50 }) -- a later part
  activity.call(act, { id = 'n', tokens = 400602, read = 400100, write = 500, input = 2, out = 20 })
  activity.call(act, { parent = 'x', id = 'a', write = 90000 }) -- an agent's fresh context: no rebuild
  eq({ act.read, act.write, act.input, act.out, act.calls, act.agent_calls }, { 400200, 490500, 5, 70, 2, 1 })
  eq({ act.rebuilt, act.thinking }, { 400000, nil })
  activity.finish(act, 10, { cost = 3.1, models = { { model = 'claude-fable-5-1', tokens = 9, cost = 3 } } })
  eq(act.last.cost, 3.1)
  activity.turn(act, 20)
  eq({ act.read, act.rebuilt, act.last }, { 0, nil, nil })
end

T['tracker: background shells by task id, kept across turns while running, stopped with the process'] = function()
  local act = activity.new()
  activity.turn(act, 0)
  activity.task(act, { id = 's1', status = 'started', task_type = 'local_bash', desc = 'npm run dev', background = true }, 0)
  activity.task(act, { id = 's2', status = 'started', task_type = 'local_bash', desc = 'make test', background = true }, 0)
  activity.task(act, { id = 's2', status = 'completed', task_type = 'local_bash' }, 5000)
  local list, running = activity.shells(act)
  eq({ #list, running, list[2].status, list[2].ended }, { 2, 1, 'done', 5000 })
  activity.turn(act, 6000)
  eq(act.shell_order, { 's1' })
  activity.stopped(act, 7000)
  eq(act.shells.s1.status, 'stopped')
  -- a foreground task (no `background`) is no shell
  activity.task(act, { id = 'f', status = 'started', task_type = 'local_bash', desc = 'x' }, 0)
  eq(act.shells.f, nil)
end

T['tracker: the todo list of the latest TodoWrite, kept across turns; replay finds it in an older turn'] = function()
  local todo = { kind = 'tool_call', id = 't', name = 'TodoWrite', input = { todos = {
    { content = 'write tests', status = 'completed', activeForm = 'Writing tests' },
    { content = 'wire the panel', status = 'in_progress', activeForm = 'Wiring the panel' },
    { content = 'update docs', status = 'pending', activeForm = 'Updating docs' },
  } } }
  local act = activity.new()
  activity.event(act, todo, 0)
  activity.turn(act, 1)
  eq(act.todos, { { text = 'write tests', status = 'completed' }, { text = 'Wiring the panel', status = 'in_progress' },
    { text = 'update docs', status = 'pending' } })
  local r = activity.replay({ { kind = 'prompt', text = 'a' }, todo, { kind = 'prompt', text = 'b' } })
  eq(#r.todos, 3)
end

T['section: cache warning, thinking, tokens, last turn per model, todos and shells'] = function()
  local act = activity.new()
  activity.turn(act, 0, 398000) -- resumed after a pause
  activity.call(act, { id = 'm', tokens = 400000, read = 0, write = 400000, input = 0, out = 40000 })
  activity.thinking(act, 8000)
  activity.event(act, { kind = 'tool_call', id = 't', name = 'TodoWrite', input = { todos = {
    { content = 'a', status = 'completed' }, { content = 'b', status = 'in_progress', activeForm = 'Doing b' },
    { content = 'c', status = 'pending' } } } }, 0)
  activity.task(act, { id = 's', status = 'started', task_type = 'local_bash', desc = 'npm run dev', background = true }, 0)
  local s = { state = 'busy', turn_start = 1, queue = {}, context_tokens = 400000, activity = act,
    events = { { kind = 'prompt', text = 'go' } } }
  local lines = queue.layout(s, 36, { busy = 'B' }, { now = 65000, large = false }).lines
  eq(vim.list_slice(lines, 5), {
    'Session  ~400k', '  ⚠ cache written again ~400k', '  turn 1m05s · 1 request', '  thinking ~8k',
    '  read 0 · new 400k · out 40k',
    '', 'Todos · 1/3 done', '✓ a', 'B Doing b', '○ c',
    '', 'Shells · 1 running', 'B npm run dev  1m05s',
  })
  -- after the result: no thinking, the cost and the models
  activity.finish(act, 70000, { cost = 3.1, models = { { model = 'claude-fable-5-1', tokens = 900, cost = 3 },
    { model = 'claude-opus-5-5', tokens = 100, cost = 0.1 } } })
  s.state = 'idle'
  lines = queue.layout(s, 36, { busy = 'B' }, { now = 99000, large = false }).lines
  eq(vim.list_slice(lines, 7, 11), { '  turn 1m10s · 1 request', '  read 0 · new 400k · out 40k',
    '  ≈ $3.10 at API prices', '  fable-5-1  90% · 900', '  opus-5-5  10% · 100' })
end

T['failure text: the API status in words and the reason the turn ended'] = function()
  local f = require('agent-ide.session.actions')._failure_text
  eq(f({ text = 'Overloaded', api_error_status = 529, terminal_reason = 'api_error' }),
    'Overloaded\n(API error 529: Anthropic is overloaded; ended: api_error)')
  eq(f({ api_error_status = 503 }), 'Turn failed\n(API error 503: server error)')
  eq(f({ text = 'x', terminal_reason = 'completed' }), 'x')
end

T['tracker: a new conversation writes its cache the first time, which is no rewrite; a pause later is'] = function()
  local act = activity.new()
  activity.turn(act, 0) -- nothing known before: a new session
  activity.call(act, { id = 'a', tokens = 35071, read = 14875, write = 20194, input = 2 })
  activity.call(act, { id = 'b', tokens = 44414, read = 35069, write = 9343, input = 2 }) -- grew by its write
  eq(act.rebuilt, nil)
  -- the next turn after the cache expired: the whole conversation written again
  activity.turn(act, 1)
  activity.call(act, { id = 'c', tokens = 45000, read = 0, write = 44998, input = 2 })
  eq(act.rebuilt, 44998)
end

return T
