-- Lines for the asks a session has open (tool permissions, user questions, plan approvals).
-- The live view shows them below the session's events and streaming lines; they are not
-- events, so they are never part of `render.render(s.events)`, and they disappear once answered.
local render = require('agent-ide.transcript.render')

local M = {}

local function split(s)
  s = tostring(s == nil and '' or s):gsub('\r\n', '\n'):gsub('\r', '\n')
  return vim.split(s, '\n', { plain = true })
end

local function str(v) return type(v) == 'string' and v or '' end

local function list(v) return type(v) == 'table' and vim.islist(v) and v or {} end

---Summary of an ask's input, as in a tool call header (`/x/a.txt`, `ls`, ...).
---@param p table pending ask { tool_name, input }
---@return string summary
function M.summary(p)
  return (render.tool_parts(p.tool_name or '?', p.input))
end

local function question_lines(p, out)
  out[#out + 1] = '▸ Question from Claude'
  for _, q in ipairs(list(type(p.input) == 'table' and p.input.questions)) do
    if type(q) == 'table' then
      for _, l in ipairs(split(str(q.question))) do out[#out + 1] = '│ ' .. l end
      for _, o in ipairs(list(q.options)) do
        if type(o) == 'table' then
          local d = str(o.description)
          out[#out + 1] = '│   ' .. render.first_line(str(o.label)) .. (d ~= '' and (' — ' .. render.first_line(d)) or '')
        end
      end
    end
  end
end

local function plan_lines(p, out)
  out[#out + 1] = '▸ Plan to approve'
  vim.list_extend(out, split(type(p.input) == 'table' and str(p.input.plan) or ''))
  out[#out + 1] = ''
end

local function permission_lines(p, out)
  local name = render.first_line(p.tool_name or '?')
  local summary, body = render.tool_parts(p.tool_name or '?', p.input)
  out[#out + 1] = ('▸ Permission needed: %s: %s'):format(name, summary)
  for _, l in ipairs(body) do out[#out + 1] = '│ ' .. l end
end

---Lines for every open ask of `s`, oldest first; `{}` when none is open.
---@param s table Session
---@return string[]
function M.lines(s)
  local out = {}
  for _, p in ipairs(s.pending_permissions or {}) do
    if p.tool_name == 'AskUserQuestion' then
      question_lines(p, out)
    elseif p.tool_name == 'ExitPlanMode' then
      plan_lines(p, out)
    else
      permission_lines(p, out)
    end
  end
  return out
end

return M
