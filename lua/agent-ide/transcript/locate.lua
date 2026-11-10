-- Event index -> line in `render.render(events)`, computed from the renderer, never by
-- searching buffer text. `render` renders turn by turn and concatenates, so a turn starts after
-- the rendered lines of the turns before it (as in `ui/textobj.lua`). Inside the turn, the line
-- of event k is where an empty text event would start if appended to the events before k (the
-- trick `transcript/live.lua` uses for streaming lines), with tool results placed as `render`
-- places them: results of calls before k render inside those calls, results of calls at or
-- after k render with their call later.
local render = require('agent-ide.transcript.render')

local M = {}

local EMPTY = { kind = 'text', text = '' }
local EMPTY_PROMPT = { kind = 'prompt', text = '' }

---Bounds of the turn holding event `i` (turn 0 are the events before the first prompt).
---@return { first: integer, last: integer }|nil
function M.turn_of(events, i)
  if i < 1 or i > #events then return nil end
  local first = 1
  for k = i, 1, -1 do
    if render.starts_turn(events[k]) then first = k; break end
  end
  local last = #events
  for k = i + 1, #events do
    if render.starts_turn(events[k]) then last = k - 1; break end
  end
  return { first = first, last = last }
end

---Line (1-based) of event `k` of `turn` within the turn's rendered lines.
---@param turn table[] the events of one turn
---@param k integer
---@return integer
function M.line_in_turn(turn, k)
  local call_at = {}
  for i, e in ipairs(turn) do
    if e.kind == 'tool_call' and e.id ~= nil and call_at[e.id] == nil then call_at[e.id] = i end
  end
  -- walk the events as `render` does: a prompt renders on its own, a result with its call, a
  -- run of sidechain events as one subagent block (headed by its first event)
  local i = 1
  while i <= #turn do
    local e = turn[i]
    if e.kind == 'prompt' or (e.kind == 'tool_result' and call_at[e.id]) or not e.sidechain then
      if i >= k then break end
      i = i + 1
    else
      local j = i
      while j <= #turn and turn[j].sidechain do j = j + 1 end
      if k < j then break end
      i = j
    end
  end
  k = math.min(i, k)
  local ev = turn[k]
  if ev.kind == 'tool_result' and call_at[ev.id] and call_at[ev.id] ~= k then
    return M.line_in_turn(turn, call_at[ev.id]) -- rendered inside its call's block
  end
  local before = {}
  for i = 1, k - 1 do
    local e = turn[i]
    local c = e.kind == 'tool_result' and call_at[e.id]
    if not (c and c >= k) then before[#before + 1] = e end
  end
  for i = k + 1, #turn do
    local e = turn[i]
    local c = e.kind == 'tool_result' and call_at[e.id]
    if c and c < k then before[#before + 1] = e end
  end
  -- a prompt starts its own block ('', '## You', '', text): its placeholder is an empty prompt,
  -- anything else follows a `## Claude` header after a prompt, as an empty text does
  local mark = ev.kind == 'prompt' and EMPTY_PROMPT or EMPTY
  before[#before + 1] = mark
  local start = #render.render(before).lines - #render.render({ mark }).lines + 1
  return ev.kind == 'prompt' and start + 3 or start
end

---Line (1-based) of event `i` in `render.render(events)`, or nil when there is no such event.
---@param events table[]
---@param i integer
---@return integer|nil
function M.line(events, i)
  local t = M.turn_of(events, i)
  if not t then return nil end
  local offset, first = 0, 1
  for k = 2, t.first do
    if k == t.first or render.starts_turn(events[k]) then
      offset = offset + #render.render(vim.list_slice(events, first, k - 1)).lines
      first = k
    end
  end
  return offset + M.line_in_turn(vim.list_slice(events, t.first, t.last), i - t.first + 1)
end

return M
