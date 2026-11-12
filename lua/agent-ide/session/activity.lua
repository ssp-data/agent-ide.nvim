-- What a session's current turn is doing, for the queue panel: the requests it made to the
-- model, and its subagents with their own context, tool uses and the tool they run now. Built
-- from what the stream and the transcript already carry (the `usage` of every message, the
-- Agent tool calls and their results, background tasks); nothing asks the model. Pure: the
-- caller passes the clock (`now`, milliseconds).
local M = {}

-- Tool calls that start a subagent (`Task` in older Claude Code versions).
local AGENT_TOOLS = { Agent = true, Task = true }

local function str(v) return type(v) == 'string' and v ~= '' and v or nil end

---A fresh activity: no turn yet, no agents.
---@return table
function M.new()
  return { started = nil, ended = nil, calls = 0, agent_calls = 0, msgs = {}, agents = {}, order = {} }
end

---A turn starts at `now`: the counts begin again; agents still running (in the background) stay.
---@param act table
---@param now integer
function M.turn(act, now)
  act.started, act.ended, act.calls, act.agent_calls, act.msgs = now, nil, 0, 0, {}
  local order = {}
  for _, id in ipairs(act.order) do
    if act.agents[id].status == 'running' then order[#order + 1] = id else act.agents[id] = nil end
  end
  act.order = order
end

---The turn ended at `now` (its result arrived).
function M.finish(act, now)
  if act.started and not act.ended then act.ended = now end
end

---A transcript event: a main-thread Agent call starts a subagent, its result ends it (unless
---the agent went to the background, then its task's notification does).
---@param act table
---@param ev table
---@param now integer|nil
function M.event(act, ev, now)
  if ev.sidechain then return end
  if ev.kind == 'tool_call' and AGENT_TOOLS[ev.name] and str(ev.id) and not act.agents[ev.id] then
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
---subagent's message (nil: the main thread), `id` the message (a message arrives in parts),
---`tokens` its context, `tools` the names of the tools it calls.
---@param act table
---@param c { parent?: string, id?: string, tokens?: integer, tools?: string[] }
function M.call(act, c)
  local new = not (c.id and act.msgs[c.id])
  if c.id then act.msgs[c.id] = true end
  local a = c.parent and act.agents[c.parent]
  if new then
    if c.parent then act.agent_calls = act.agent_calls + 1 else act.calls = act.calls + 1 end
  end
  if not a then return end
  if c.tokens then a.tokens = c.tokens end
  local tools = c.tools or {}
  a.tools = a.tools + #tools
  if #tools > 0 then a.tool = tools[#tools] end
end

---A background task of an agent (`task` action): started in the background, or finished with
---`status` (completed, failed, killed, …).
---@param act table
---@param t { tool?: string, status: string, tokens?: integer, tool_uses?: integer }
---@param now integer|nil
function M.task(act, t, now)
  local a = t.tool and act.agents[t.tool]
  if not a then return end
  if t.status == 'started' then
    a.background = true
    return
  end
  a.status = t.status == 'completed' and 'done' or (t.status == 'running' and 'running' or 'failed')
  if a.status ~= 'running' then a.ended, a.tool = now, nil end
  if t.tool_uses and t.tool_uses > a.tools then a.tools = t.tool_uses end
end

---The activity of a session's last turn from its transcript events alone (a session not run
---here, or loaded from disk): its agents and whether they finished, no sizes or times.
---@param events table[]
---@return table
function M.replay(events)
  local act = M.new()
  local from = 1
  for i = #events, 1, -1 do
    if events[i].kind == 'prompt' and not events[i].sidechain then from = i; break end
  end
  for i = from, #events do M.event(act, events[i], nil) end
  return act
end

---Agents of `act` in the order they started, `running` ones counted.
---@return table[] agents, integer running
function M.agents(act)
  local list, running = {}, 0
  for _, id in ipairs(act.order) do
    local a = act.agents[id]
    list[#list + 1] = a
    if a.status == 'running' then running = running + 1 end
  end
  return list, running
end

return M
