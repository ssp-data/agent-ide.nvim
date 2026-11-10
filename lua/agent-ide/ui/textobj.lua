-- Text object for the chat transcript: `ir` / `ar` select one answer of Claude (linewise).
-- Answers are found from the session's events and the renderer, not from the buffer text, so a
-- `## Claude` line inside a prompt or an answer is never taken for a header.
local api = vim.api
local render = require('agent-ide.transcript.render')

local M = {}

local NOTICE = 'Agent-IDE: no Claude answer here'

---Lines the view shows below the events of the last turn while Claude streams, derived the way
---`transcript.live`'s `View:stream_lines` does: whatever `render` puts between the turn's lines
---and an appended text (the `## Claude` header after a prompt), then the streaming text's lines
---without the trailing blank line `render` adds to a finished text.
---@param s table Session
---@param turn table[] events of the last turn
---@param turn_n integer rendered line count of `turn`
local function stream_lines(s, turn, turn_n)
  if s.streaming == '' then return 0 end
  local with = vim.list_slice(turn)
  with[#with + 1] = { kind = 'text', text = '' }
  local text_n = #render.render({ { kind = 'text', text = '' } }).lines
  local header_n = #render.render(with).lines - text_n - turn_n
  return header_n + #render.render({ { kind = 'text', text = s.streaming } }).lines - 1
end

---Answers in the transcript of `s`, oldest first: `{ header, last }` buffer lines (1-based).
---Boundaries are computed from the rendered line counts of the answer's own events, never from
---the buffer end. Rule: an answer is its `## Claude` header plus the lines `render` makes for
---the events of its turn, plus (last turn only) the streaming text below them. Anything else the
---view shows after the events, for example a pending-permission block, is not part of it. A
---later task that renders such a block must put it after the events and the streaming lines.
---@param buf integer transcript buffer
---@param s table Session
---@return { header: integer, last: integer }[]
function M.answers(buf, s)
  local events = s.events
  local turns, first = {}, 1
  for i = 2, #events + 1 do
    if i > #events or render.starts_turn(events[i]) then
      turns[#turns + 1] = vim.list_slice(events, first, i - 1)
      first = i
    end
  end
  local count = api.nvim_buf_line_count(buf)
  local out, offset = {}, 0
  for k, turn in ipairs(turns) do
    local n = #render.render(turn).lines
    if render.starts_turn(turn[1]) then
      local is_last = k == #turns
      local extra = is_last and stream_lines(s, turn, n) or 0
      if #turn > 1 or extra > 0 then
        local prompt_n = #render.render({ turn[1] }).lines
        local header = offset + prompt_n + 1
        local last = offset + n + extra
        if last <= count and api.nvim_buf_get_lines(buf, header - 1, header, false)[1] == '## Claude' then
          out[#out + 1] = { header = header, last = last }
        end
      end
    end
    offset = offset + n
  end
  return out
end

local function blank(line) return not line:find('%S') end

---Line range of an answer for `ir` (inner) or `ar` (outer), or nil.
---@param buf integer
---@param s table Session
---@param inner boolean
---@param row integer cursor line
---@param count integer
---@return integer|nil first, integer|nil last
function M.range(buf, s, inner, row, count)
  local answers = M.answers(buf, s)
  local pick
  for _, a in ipairs(answers) do
    if row >= a.header and row <= a.last then pick = a end
  end
  pick = pick or answers[#answers - count + 1]
  if not pick then return nil end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local last = pick.last
  while last > pick.header and blank(lines[last]) do last = last - 1 end
  if inner then
    local first = pick.header + 1
    if first <= last and blank(lines[first]) then first = first + 1 end
    if first > last then return nil end
    return first, last
  end
  if pick.last > last then last = last + 1 end
  return pick.header, last
end

-- The range found by the expression mapping, selected by the command it returns.
local pending

---Select the range found by the last mapping call (linewise).
function M.apply()
  local range = pending
  pending = nil
  if not range then return end
  if api.nvim_get_mode().mode:match('^[vV\22]') then vim.cmd('normal! \27') end
  api.nvim_win_set_cursor(0, { range[1], 0 })
  vim.cmd('normal! V')
  api.nvim_win_set_cursor(0, { range[2], 0 })
end

---Expression of the mappings: the keys that select the answer, or <Esc> (which also cancels a
---pending operator) with a notice when there is none.
local function expr(buf, s, inner)
  local first, last = M.range(buf, s, inner, api.nvim_win_get_cursor(0)[1], vim.v.count1)
  if not first then
    vim.schedule(function() vim.notify(NOTICE, vim.log.levels.INFO) end)
    return '<Esc>'
  end
  pending = { first, last }
  return '<Cmd>lua require("agent-ide.ui.textobj").apply()<CR>'
end

---Map the answer text objects in transcript `buf` of session `s`.
---@param buf integer
---@param s table Session
---@param keys table `config.keys.chat`
function M.map(buf, s, keys)
  for name, inner in pairs({ answer_inner = true, answer_outer = false }) do
    for _, lhs in ipairs(require('agent-ide.util.keys').list(keys[name])) do
      vim.keymap.set({ 'o', 'x' }, lhs, function() return expr(buf, s, inner) end,
        { expr = true, buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: ' .. (inner and 'inner' or 'outer') .. ' answer' })
    end
  end
end

return M
