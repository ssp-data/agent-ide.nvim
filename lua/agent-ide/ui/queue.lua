-- The queue panel of a chat: a narrow window left of the transcript listing, as a timeline, the
-- prompts of the session: the last few sent (dim), the one Claude works on, and the ones queued
-- behind it, numbered. `Q` in the chat shows or hides it; it follows the chat to another
-- session and redraws as the session changes. In the panel: <CR> on a sent or running prompt
-- puts the transcript cursor on it, on a queued one focuses the prompt; `x` takes a queued
-- prompt out of the queue, back into the prompt buffer; `q` closes.
local api = vim.api

local M = {}

M.WIDTH = 36
M.SENT_SHOWN = 5

local ns = api.nvim_create_namespace('agent-ide.queue')
local Q = { win = nil, buf = nil, s = nil, rows = {} }
local augroup

local function valid_win(w) return w ~= nil and api.nvim_win_is_valid(w) end

local function chat() return require('agent-ide.ui.chat') end

local function first_line(text)
  local l = tostring(text or ''):match('^%s*([^\r\n]*)')
  return l ~= '' and l or '(empty)'
end

---Rows of the panel for session `s` and `width` columns: lines, highlights and, per line, what
---it stands for ({ kind = 'sent'|'running'|'queued', event = i | n = k }). Pure.
---@param s table Session
---@param width integer
---@param icons table
---@return { lines: string[], hl: table[], rows: table[] }
function M.layout(s, width, icons)
  local truncate = require('agent-ide.ui.layout').truncate
  local out = { lines = {}, hl = {}, rows = {} }
  local function add(text, group, row, prefix, prefix_group)
    local n = #out.lines + 1
    local label = truncate(first_line(text), math.max(4, width - vim.fn.strdisplaywidth(prefix) - 1))
    out.lines[n] = prefix .. label
    if prefix_group and prefix ~= '' then out.hl[#out.hl + 1] = { line = n, col_start = 0, col_end = #prefix, group = prefix_group } end
    if group then out.hl[#out.hl + 1] = { line = n, col_start = #prefix, col_end = #out.lines[n], group = group } end
    out.rows[n] = row
  end
  local running = (s.state == 'busy' or s.state == 'waiting') and s.turn_start <= #s.events
    and s.events[s.turn_start] and s.events[s.turn_start].kind == 'prompt' and s.turn_start or nil
  local sent = {}
  for i, ev in ipairs(s.events) do
    if ev.kind == 'prompt' and not ev.sidechain and i ~= running then sent[#sent + 1] = i end
  end
  local n = #s.queue
  add(('Queue · %d waiting'):format(n), 'AgentIdeSection', nil, '', nil)
  local from = math.max(1, #sent - M.SENT_SHOWN + 1)
  if from > 1 then add(('… %d earlier'):format(from - 1), 'AgentIdeAge', nil, '', nil) end
  for k = from, #sent do
    add(s.events[sent[k]].text, 'AgentIdeAge', { kind = 'sent', event = sent[k] }, '✓ ', 'AgentIdeAge')
  end
  if running then
    local waiting = s.state == 'waiting'
    add(s.events[running].text, nil, { kind = 'running', event = running },
      (waiting and (icons.waiting or '●') or (icons.busy or '◐')) .. ' ', waiting and 'AgentIdeWaiting' or 'AgentIdeBusy')
  end
  for k, text in ipairs(s.queue) do
    add(text, nil, { kind = 'queued', n = k }, ('%d. '):format(k), 'AgentIdeSection')
  end
  if #out.lines == 1 then add('nothing sent yet', 'AgentIdeAge', nil, '', nil) end
  return out
end

local function render()
  if not (Q.s and Q.buf and api.nvim_buf_is_valid(Q.buf)) then return end
  local width = valid_win(Q.win) and api.nvim_win_get_width(Q.win) or M.WIDTH
  local icons = require('agent-ide.config').get().icons or {}
  local l = M.layout(Q.s, width, icons)
  vim.bo[Q.buf].modifiable = true
  api.nvim_buf_set_lines(Q.buf, 0, -1, false, l.lines)
  vim.bo[Q.buf].modifiable = false
  api.nvim_buf_clear_namespace(Q.buf, ns, 0, -1)
  for _, h in ipairs(l.hl) do
    api.nvim_buf_set_extmark(Q.buf, ns, h.line - 1, h.col_start, { end_col = h.col_end, hl_group = h.group })
  end
  Q.rows = l.rows
end

local function row_at_cursor()
  if not valid_win(Q.win) then return nil end
  return Q.rows[api.nvim_win_get_cursor(Q.win)[1]]
end

-- <CR>: a sent or running prompt: the transcript cursor goes to it; a queued one: the prompt.
local function open_row()
  local row = row_at_cursor()
  if not row then return end
  local s = Q.s
  if row.kind == 'queued' then return chat().focus_prompt(s, false) end
  local line = require('agent-ide.transcript.locate').line(s.events, row.event)
  local twin = chat()._windows().transcript
  if not line or not valid_win(twin) then return end
  api.nvim_set_current_win(twin)
  pcall(api.nvim_win_set_cursor, twin, { math.min(line, api.nvim_buf_line_count(api.nvim_win_get_buf(twin))), 0 })
  vim.cmd('normal! zv')
end

-- x: a queued prompt leaves the queue and goes back into the prompt buffer, above the draft.
local function unqueue()
  local row = row_at_cursor()
  if not row or row.kind ~= 'queued' then return end
  local s = Q.s
  local text = table.remove(s.queue, row.n)
  if not text then return end
  local _, pbuf = chat().buffers(s)
  if pbuf then
    require('agent-ide.ui.prompt').restore(pbuf, { text })
  else
    vim.fn.setreg('"', text)
    vim.notify('Agent-IDE: the prompt has no buffer; the text is in the unnamed register', vim.log.levels.INFO)
  end
  s:_emit('meta')
end

local function help()
  require('agent-ide.ui.help').open('Agent-IDE queue', {
    { key = '<CR>', desc = 'sent or running prompt: go to it in the transcript; queued: focus the prompt' },
    { key = 'x', desc = 'queued prompt: take it out of the queue, back into the prompt buffer' },
    { key = 'q', desc = 'close the panel' },
  }, { win = Q.win })
end

local function on_session(s, what)
  if s == Q.s and (what == 'meta' or what == 'state' or what == 'events') then render() end
end

local function ensure_buf(s)
  if Q.buf and api.nvim_buf_is_valid(Q.buf) then return Q.buf end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = 'agent-ide-queue'
  vim.bo[buf].modifiable = false
  local function map(lhs, fn, desc) vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE queue: ' .. desc }) end
  map('<CR>', open_row, 'go to the prompt')
  map('x', unqueue, 'take a queued prompt back')
  map('q', function() M.close() end, 'close')
  map('g?', help, 'help')
  Q.buf = buf
  return buf
end

---Show the panel for session `s` (the current chat's when nil) left of the transcript.
---@param s? table Session
function M.open(s)
  s = s or chat().current()
  if not s then return vim.notify('Agent-IDE: no chat open', vim.log.levels.INFO) end
  local twin = chat()._windows().transcript
  if not valid_win(twin) then return end
  if Q.s ~= s then
    Q.s = s
    local buf = ensure_buf(s)
    require('agent-ide.ui.bufname').track(buf, s, ' · queue', function() return chat().project_of(s) end)
  end
  local buf = ensure_buf(s)
  if not valid_win(Q.win) then
    Q.win = api.nvim_open_win(buf, false, { split = 'left', win = twin, width = M.WIDTH })
    for name, value in pairs({ winfixwidth = true, number = false, relativenumber = false, signcolumn = 'no',
      wrap = false, list = false, cursorline = true, foldenable = false, winbar = '' }) do
      api.nvim_set_option_value(name, value, { scope = 'local', win = Q.win })
    end
  elseif api.nvim_win_get_buf(Q.win) ~= buf then
    api.nvim_win_set_buf(Q.win, buf)
  end
  if not augroup then
    augroup = api.nvim_create_augroup('agent-ide.queue', { clear = true })
    api.nvim_create_autocmd('WinClosed', { group = augroup, callback = function(ev)
      if tonumber(ev.match) == Q.win then Q.win = nil end
    end })
    local session = require('agent-ide.session')
    session.off_change(on_session)
    session.on_change(on_session)
  end
  render()
end

---Close the panel (the session stays known, so `Q` reopens it there).
function M.close()
  local w = Q.win
  Q.win = nil
  if valid_win(w) then pcall(api.nvim_win_close, w, true) end
end

---`Q`: show or hide the panel for the current chat.
function M.toggle()
  if valid_win(Q.win) then return M.close() end
  M.open()
end

---The chat moved to session `s`: an open panel follows it.
---@param s table Session
function M.follow(s)
  if valid_win(Q.win) and Q.s ~= s then M.open(s) end
end

---Test only.
function M._state() return { win = valid_win(Q.win) and Q.win or nil, buf = Q.buf, sid = Q.s and Q.s.id, rows = Q.rows } end

return M
