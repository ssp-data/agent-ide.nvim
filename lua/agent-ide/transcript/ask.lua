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

---A tool permission as one line, the subject first: `Allow Bash: npm test? Run the tests`. A
---summary cut from a longer value says how much is left (`(+2 lines)`, `…`); Claude's own
---description of the call and the ask's reason follow when they say something new.
---@param p table pending ask { tool_name, input, description }
---@return string
function M.question(p)
  local input = type(p.input) == 'table' and p.input or {}
  local field = render.summary_field(input)
  local subject = M.summary(p)
  if field then
    local value = split(input[field])
    if vim.fn.strchars(value[1]) > vim.fn.strchars(subject) then subject = subject .. '…' end
    if #value > 1 then subject = ('%s (+%d lines)'):format(subject, #value - 1) end
  end
  local out = ('Allow %s%s?'):format(render.first_line(p.tool_name or '?'), subject ~= '' and (': ' .. subject) or '')
  local said = { [subject] = true }
  for _, extra in ipairs({ field ~= 'description' and str(input.description) or '', str(p.description) }) do
    extra = render.first_line(extra)
    if extra ~= '' and not said[extra] then
      said[extra] = true
      out = out .. ' ' .. extra
    end
  end
  return out
end

M.MAX_BODY = 12 -- rows of a call's body in the ask window; the rest is counted

---Rows of the ask window for a tool permission: `Allow Bash?`, Claude's description of the call
---and the ask's reason, the subject (unless the body starts with it, as a command does), then
---the call's body as the transcript shows it, at most `MAX_BODY` rows and the rest counted.
---@param p table pending ask { tool_name, input, description }
---@return agent-ide.AskRow[]
function M.permission_rows(p)
  local input = type(p.input) == 'table' and p.input or {}
  local field = render.summary_field(input)
  local subject, body = render.tool_parts(p.tool_name or '?', p.input)
  local rows = { { text = ('Allow %s?'):format(render.first_line(p.tool_name or '?')), hl = 'AgentIdeAskQuestion' } }
  local said = {}
  for _, extra in ipairs({ field ~= 'description' and str(input.description) or '', str(p.description) }) do
    for _, l in ipairs(split(extra)) do
      if l ~= '' and not said[l] then
        said[l] = true
        rows[#rows + 1] = { text = l }
      end
    end
  end
  if field ~= 'command' and subject ~= '' and not said[subject] then rows[#rows + 1] = { text = subject } end
  if #body > 0 then rows[#rows + 1] = { text = '' } end
  for i = 1, math.min(#body, M.MAX_BODY) do rows[#rows + 1] = { text = body[i], hl = 'AgentIdeAskBody' } end
  if #body > M.MAX_BODY then
    rows[#rows + 1] = { text = ('… %d more lines in the transcript'):format(#body - M.MAX_BODY), hl = 'AgentIdeAskMore' }
  end
  return rows
end

---Rows of the ask window for one of Claude's questions: its text, then `hint` dimmed.
---@param question string
---@param hint? string
---@return agent-ide.AskRow[]
function M.question_rows(question, hint)
  local rows = {}
  for _, l in ipairs(split(question)) do rows[#rows + 1] = { text = l, hl = 'AgentIdeAskQuestion' } end
  if hint then rows[#rows + 1] = { text = hint, hl = 'AgentIdeAskMore' } end
  return rows
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
