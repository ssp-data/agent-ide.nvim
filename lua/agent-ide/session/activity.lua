-- What a session's current turn is doing, for the queue panel: the requests it made to the
-- model and the tokens they read and wrote, a cache that had to be written again, Claude's
-- todo list, its subagents with their own context, tool uses and the tool they run now, the
-- shells it runs in the background, and what the last turn weighed per model. Built from what
-- the stream and the transcript already carry (the `usage` of every message, the Agent and
-- TodoWrite calls, background tasks, the turn's `result`); nothing asks the model. Pure: the
-- caller passes the clock (`now`, milliseconds).
local M = {}

-- Tool calls that start a subagent (`Task` in older Claude Code versions).
local AGENT_TOOLS = { Agent = true, Task = true }

-- A main-thread request that writes at least this many tokens to the cache, and more than it
-- reads from it, wrote the conversation again: the cache had expired or the prompt changed.
M.REBUILT_MIN = 20000

local function str(v) return type(v) == 'string' and v ~= '' and v or nil end

---A fresh activity: no turn yet, no agents.
---@return table
function M.new()
  return {
    started = nil, ended = nil, calls = 0, agent_calls = 0, msgs = {},
    read = 0, write = 0, input = 0, out = 0, rebuilt = nil, thinking = nil,
    agents = {}, order = {}, shells = {}, shell_order = {}, tasks = {}, todos = nil, last = nil,
  }
end

-- Keep the running entries of `map` (in `order`), drop the rest.
local function keep_running(map, order)
  local kept = {}
  for _, id in ipairs(order) do
    if map[id].status == 'running' then kept[#kept + 1] = id else map[id] = nil end
  end
  return kept
end

---A turn starts at `now`: the counts begin again; agents and shells still running (in the
---background) stay, and so do the todos (Claude's plan spans turns).
---@param act table
---@param now integer
function M.turn(act, now)
  act.started, act.ended, act.calls, act.agent_calls, act.msgs = now, nil, 0, 0, {}
  act.read, act.write, act.input, act.out, act.rebuilt, act.thinking, act.last = 0, 0, 0, 0, nil, nil, nil
  act.order = keep_running(act.agents, act.order)
  act.shell_order = keep_running(act.shells, act.shell_order)
end

---The turn ended at `now`; `r` is its `result` action: the cost and the usage per model.
---@param act table
---@param now integer
---@param r? table
function M.finish(act, now, r)
  if act.started and not act.ended then act.ended = now end
  act.thinking = nil
  if r and (r.cost or r.models) then act.last = { cost = r.cost, models = r.models } end
end

---The process is gone (`now`): nothing of it runs any more.
function M.stopped(act, now)
  M.finish(act, now)
  for _, map in ipairs({ act.agents, act.shells }) do
    for _, x in pairs(map) do
      if x.status == 'running' then x.status, x.ended, x.tool = 'stopped', now, nil end
    end
  end
end

-- Claude's todo list from a TodoWrite call: { text, status } per item.
local function todos_of(input)
  if type(input) ~= 'table' or type(input.todos) ~= 'table' then return nil end
  local list = {}
  for _, t in ipairs(input.todos) do
    if type(t) == 'table' and str(t.content) then
      local status = str(t.status) or 'pending'
      list[#list + 1] = { text = status == 'in_progress' and str(t.activeForm) or t.content, status = status }
    end
  end
  return list
end

---A transcript event: a main-thread Agent call starts a subagent, its result ends it (unless
---the agent went to the background, then its task's notification does); a TodoWrite call
---replaces the todo list.
---@param act table
---@param ev table
---@param now integer|nil
function M.event(act, ev, now)
  if ev.sidechain then return end
  if ev.kind == 'tool_call' and ev.name == 'TodoWrite' then
    act.todos = todos_of(ev.input) or act.todos
  elseif ev.kind == 'tool_call' and AGENT_TOOLS[ev.name] and str(ev.id) and not act.agents[ev.id] then
    local input = type(ev.input) == 'table' and ev.input or {}
    act.agents[ev.id] = {
      id = ev.id, kind = str(input.subagent_type) or 'agent', desc = str(input.description) or '',
      tokens = nil, tools = 0, tool = nil, status = 'running', started = now, ended = nil,
      background = input.run_in_background == true,
    }
    act.order[#act.order + 1] = ev.id
  elseif ev.kind == 'tool_result' and act.agents[ev.id] then
    local a = act.agents[ev.id]
    if a.status == 'running' and not a.background then
      a.status, a.ended, a.tool = ev.is_error and 'failed' or 'done', now, nil
    end
  end
end

---One message of a request to the model (`call` action): `parent` names the Agent call of a
---subagent's message (nil: the main thread), `id` the message (a message arrives in parts,
---each with the message's usage so far), `tokens` its context, `read`, `write`, `input`, `out`
---its usage, `tools` the names of the tools it calls.
---@param act table
---@param c table
function M.call(act, c)
  local prev = c.id and act.msgs[c.id]
  local cur = { read = c.read or 0, write = c.write or 0, input = c.input or 0, out = c.out or 0 }
  if c.id then act.msgs[c.id] = cur end
  for k, v in pairs(cur) do act[k] = act[k] + v - (prev and prev[k] or 0) end
  if not prev then
    if c.parent then act.agent_calls = act.agent_calls + 1 else act.calls = act.calls + 1 end
  end
  if not c.parent then
    act.thinking = nil -- the message came: the thinking it estimated is in it
    if cur.write >= M.REBUILT_MIN and cur.write > cur.read and not act.rebuilt then act.rebuilt = cur.write end
  end
  local a = c.parent and act.agents[c.parent]
  if not a then return end
  if c.tokens then a.tokens = c.tokens end
  local tools = c.tools or {}
  a.tools = a.tools + #tools
  if #tools > 0 then a.tool = tools[#tools] end
end

---The model's running estimate of its thinking (`thinking` action).
function M.thinking(act, tokens) act.thinking = tokens end

-- A task's status in the panel's words.
local function status_of(s)
  if s == 'completed' then return 'done' end
  if s == 'running' or s == 'pending' then return 'running' end
  if s == 'killed' or s == 'stopped' then return 'stopped' end
  return 'failed'
end

---A background task (`task` action): an agent's (found by the tool call that started it) or a
---shell's (by its task id), started or finished with `status` (completed, failed, killed, …).
---@param act table
---@param t table
---@param now integer|nil
function M.task(act, t, now)
  if t.status == 'started' and t.id then act.tasks[t.id] = t.tool or false end
  local tool = t.tool or (t.id and act.tasks[t.id]) or nil
  local a = tool and act.agents[tool]
  if a then
    if t.status == 'started' then a.background = t.background or a.background; return end
    a.status = status_of(t.status)
    if a.status ~= 'running' then a.ended, a.tool = now, nil end
    if t.tool_uses and t.tool_uses > a.tools then a.tools = t.tool_uses end
    return
  end
  if t.task_type == 'local_agent' or not t.id then return end -- an agent this turn never started
  local sh = act.shells[t.id]
  if t.status == 'started' then
    if not sh and t.background then
      act.shells[t.id] = { id = t.id, desc = t.desc or t.id, status = 'running', started = now }
      act.shell_order[#act.shell_order + 1] = t.id
    end
  elseif sh then
    sh.status = status_of(t.status)
    if sh.status ~= 'running' then sh.ended = now end
  end
end

---The activity of a session's last turn from its transcript events alone (a session not run
---here, or loaded from disk): its agents and whether they finished, no sizes or times; the
---latest todo list, from whichever turn wrote it.
---@param events table[]
---@return table
function M.replay(events)
  local act = M.new()
  local from = 1
  for i = #events, 1, -1 do
    if events[i].kind == 'prompt' and not events[i].sidechain then from = i; break end
  end
  for i = from, #events do M.event(act, events[i], nil) end
  if not act.todos then
    for i = from - 1, 1, -1 do
      local ev = events[i]
      if ev.kind == 'tool_call' and ev.name == 'TodoWrite' and not ev.sidechain then
        act.todos = todos_of(ev.input)
        break
      end
    end
  end
  return act
end

-- Entries of `map` in `order`, `running` ones counted.
local function listed(map, order)
  local list, running = {}, 0
  for _, id in ipairs(order) do
    list[#list + 1] = map[id]
    if map[id].status == 'running' then running = running + 1 end
  end
  return list, running
end

---Agents of `act` in the order they started, `running` ones counted.
---@return table[] agents, integer running
function M.agents(act) return listed(act.agents, act.order) end

---Background shells of `act` in the order they started, `running` ones counted.
---@return table[] shells, integer running
function M.shells(act) return listed(act.shells, act.shell_order) end

return M
