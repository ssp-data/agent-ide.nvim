-- Keeps a transcript buffer equal to `render.render(s.events)` while a session grows, rewriting
-- only the current turn (and the streaming answer below it). Below everything, after the events
-- and the streaming lines, come the lines of the session's open asks (`transcript/ask.lua`):
-- buffer = render(events) ++ streaming lines ++ ask lines. The ask lines are never folded.
local api = vim.api
local ask = require('agent-ide.transcript.ask')
local history = require('agent-ide.ui.history')
local render = require('agent-ide.transcript.render')

local M = {}

local View = {}
View.__index = View

-- `marks`: the answer-start lines (1-based, relative to `lines`) of what was rendered.
local function render_range(events, first, last, lines, levels, marks, name)
  if last < first then return end
  local out = render.render(vim.list_slice(events, first, last), name)
  local lv = render.fold_levels(out.folds, #out.lines)
  local base = #lines
  vim.list_extend(lines, out.lines)
  vim.list_extend(levels, lv)
  for _, a in ipairs(out.answers) do marks[#marks + 1] = base + a end
end

---Replace the buffer lines from `row` (0-based) on, where the view last wrote `old`/`old_lv`,
---with `new`/`new_lv`; only lines from the first difference in text or level are written, and
---the answer marks (`new_marks`, 1-based in `new`) of the rewritten part are set again.
function View:write(row, old, old_lv, new, new_lv, new_marks)
  local k = 1
  while k <= #old and k <= #new and old[k] == new[k] and old_lv[k] == new_lv[k] do k = k + 1 end
  if k > #old and k > #new then return end
  local buf, levels = self.buf, self.levels
  local start = row + k - 1 -- 0-based first changed line
  for i = start + 1, #levels do levels[i] = nil end
  for i = k, #new do levels[row + i] = new_lv[i] end
  history.set_folds(buf, levels)
  vim.bo[buf].modifiable = true
  local empty = start == 0 and k > #new
  api.nvim_buf_set_lines(buf, start, -1, false, empty and { '' } or vim.list_slice(new, k))
  vim.bo[buf].modifiable = false
  local abs = {}
  for _, m in ipairs(new_marks or {}) do abs[#abs + 1] = row + m end
  history.mark_answers(buf, start + 1, abs)
end

---Windows showing the buffer whose cursor is on its last line, or on a closed fold that
---contains the last line (Neovim may move a cursor inside a closed fold to the fold start).
function View:followers()
  local buf = self.buf
  local count = api.nvim_buf_line_count(buf)
  local out = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local row = api.nvim_win_get_cursor(win)[1]
    if row == count or api.nvim_win_call(win, function() return vim.fn.foldclosedend(row) end) == count then
      out[#out + 1] = win
    end
  end
  return out
end

---Put the cursor of each window in `wins` on the buffer's last line.
function View:follow(wins)
  local last = api.nvim_buf_line_count(self.buf)
  for _, win in ipairs(wins) do
    if api.nvim_win_is_valid(win) then api.nvim_win_set_cursor(win, { last, 0 }) end
  end
end

---Lines of the streaming answer as they will read once it is a `text` event, without the
---trailing blank line `render` adds after it, and the index of its first text line (the
---answer mark; nil while nothing streams).
---@return string[] lines, integer|nil mark
function View:stream_lines()
  local s = self.s
  if s.streaming == '' then return {}, nil end
  if self.header == nil then
    -- the lines `render` puts between the turn and an answer appended to it (the `## Claude`
    -- header after a prompt): render the turn with an empty text appended and take what lies
    -- between the turn's own lines and the empty text's lines
    local turn = vim.list_slice(s.events, self.start, #s.events)
    turn[#turn + 1] = { kind = 'text', text = '' }
    local with = render.render(turn, render.name_of(s)).lines
    local text_n = #render.render({ { kind = 'text', text = '' } }).lines
    self.header = vim.list_slice(with, #self.turn + 1, #with - text_n)
  end
  local lines = vim.list_slice(self.header)
  local body = render.render({ { kind = 'text', text = s.streaming } }).lines
  body[#body] = nil
  local mark = #body > 0 and #lines + 1 or nil
  return vim.list_extend(lines, body), mark
end

local function zeros(n)
  local t = {}
  for i = 1, n do t[i] = '0' end
  return t
end

function View:sync_events()
  local events = self.s.events
  if #events < self.seen then return self:sync_reset() end
  local start = self.start
  for i = self.seen + 1, #events do
    if i > start and render.starts_turn(events[i]) then start = i end
  end
  self.seen = #events
  -- completed turns (rendered for the last time) then the current one
  local lines, levels, marks = {}, {}, {}
  local name = render.name_of(self.s)
  render_range(events, self.start, start - 1, lines, levels, marks, name)
  local done = #lines
  render_range(events, start, #events, lines, levels, marks, name)
  local below = vim.list_extend(vim.list_slice(self.stream), self.tail)
  local old = vim.list_extend(vim.list_slice(self.turn), below)
  local old_lv = vim.list_extend(vim.list_slice(self.turn_lv), zeros(#below))
  self.start, self.header = start, nil
  self.turn, self.turn_lv = vim.list_slice(lines, done + 1), vim.list_slice(levels, done + 1)
  local stream_mark
  self.stream, stream_mark = self:stream_lines()
  self.tail = ask.lines(self.s)
  if stream_mark then marks[#marks + 1] = #lines + stream_mark end
  below = vim.list_extend(vim.list_slice(self.stream), self.tail)
  vim.list_extend(lines, below)
  vim.list_extend(levels, zeros(#below))
  local follow = self:followers()
  self:write(self.offset, old, old_lv, lines, levels, marks)
  self:close_new_folds(self.offset, old_lv, levels)
  self:follow(follow)
  self.offset = self.offset + done
end

---Close the folds that did not exist before this update, in every window showing the buffer.
---Neovim opens new folds once the user has toggled any fold by hand; folds start closed here as
---in the history view, while folds the user opened stay as they are.
function View:close_new_folds(row, old_lv, new_lv)
  local before = 0
  for _, l in ipairs(old_lv) do
    if l == '>1' then before = before + 1 end
  end
  local starts, seen = {}, 0
  for i, l in ipairs(new_lv) do
    if l == '>1' then
      seen = seen + 1
      if seen > before then starts[#starts + 1] = row + i end
    end
  end
  if #starts == 0 then return end
  for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
    api.nvim_win_call(win, function()
      for _, lnum in ipairs(starts) do
        if vim.fn.foldclosed(lnum) == -1 and vim.fn.foldlevel(lnum) > 0 then vim.cmd(lnum .. 'foldclose') end
      end
    end)
  end
end

-- Rewrite what lies below the current turn: the streaming lines and the ask lines.
function View:sync_below()
  local stream, mark = self:stream_lines()
  local tail = ask.lines(self.s)
  local old = vim.list_extend(vim.list_slice(self.stream), self.tail)
  local new = vim.list_extend(vim.list_slice(stream), tail)
  local follow = self:followers()
  self:write(self.offset + #self.turn, old, zeros(#old), new, zeros(#new), mark and { mark } or {})
  self:follow(follow)
  self.stream, self.tail = stream, tail
end

function View:sync_reset()
  self.start, self.offset, self.seen, self.header = 1, 0, 0, nil
  -- the whole buffer counts as the current turn with unknown levels, so all of it is rewritten
  self.turn, self.turn_lv, self.stream, self.tail = api.nvim_buf_get_lines(self.buf, 0, -1, false), {}, {}, {}
  self:sync_events()
end

---Bring the buffer up to date with the session.
---@param what 'events'|'delta'|'permission'|'reset' anything else is ignored
function View:sync(what)
  if self.detached or not api.nvim_buf_is_valid(self.buf) then return end
  if what == 'events' then
    self:sync_events()
  elseif what == 'delta' or what == 'permission' then
    self:sync_below()
  elseif what == 'reset' then
    self:sync_reset()
  end
end

---Stop updating the buffer; its content stays as it is.
function View:detach()
  self.detached = true
end

---Show session `s` in `buf` and keep it in sync through `view:sync`.
---`sync('events')` assumes `s.events` only grew (the last turn may change); after replacing
---`s.events` (a reload from disk) callers must use `sync('reset')`.
---@param buf integer
---@param s table Session (`events`, `streaming`, `pending_permissions`)
---@return table view
function M.attach(buf, s)
  history.setup_buf(buf)
  vim.bo[buf].undolevels = -1
  local view = setmetatable({ buf = buf, s = s, levels = {} }, View)
  history.set_folds(buf, view.levels)
  view:sync_reset()
  return view
end

return M
