-- Text object for the chat transcript: `ir` / `ar` select one answer of Claude (linewise).
-- Answers are found from the session's events and the renderer, not from the buffer text, so a
-- `## Claude` line inside a prompt or an answer is never taken for a header.
local api = vim.api
local render = require('agent-ide.transcript.render')

local M = {}

local NOTICE = 'Agent-IDE: no Claude answer here'

---Answers in the transcript of `s`, oldest first: `{ header, last }` buffer lines (1-based). An
---answer runs from its `## Claude` header up to the line before the next `## You` header (or the
---end of the buffer).
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
    local next_offset = offset + n
    if render.starts_turn(turn[1]) then
      local streaming = k == #turns and #turn == 1 and s.streaming ~= ''
      if #turn > 1 or streaming then
        local header = offset + #render.render({ turn[1] }).lines + 1
        local last = k == #turns and count or (next_offset + 1)
        if header <= count and api.nvim_buf_get_lines(buf, header - 1, header, false)[1] == '## Claude' then
          out[#out + 1] = { header = header, last = math.min(last, count) }
        end
      end
    end
    offset = next_offset
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
    if keys[name] then
      vim.keymap.set({ 'o', 'x' }, keys[name], function() return expr(buf, s, inner) end,
        { expr = true, buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: ' .. (inner and 'inner' or 'outer') .. ' answer' })
    end
  end
end

return M
