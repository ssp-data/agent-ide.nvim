-- The help palette of a view: a query line over the list of its keys. Typing filters the list
-- fuzzily (`matchfuzzypos`), <C-n> / <C-p> / <Down> / <Up> (and j / k in normal mode) move,
-- <CR> closes the help and presses the selected key in the window the help came from, <Esc>
-- leaves insert mode, and <Esc> or q in normal mode closes. With an empty query the rows show in
-- their groups (headings), as a plain list.
local api = vim.api

local M = {}

local ns = api.nvim_create_namespace('agent-ide.help')
local H ---@type table|nil the open palette

local function valid(w) return w ~= nil and api.nvim_win_is_valid(w) end

-- Close the palette `h` (default: the open one); a stale request for an older one is harmless.
local function close(h)
  h = h or H
  if not h then return end
  if h == H then H = nil end
  if h.augroup then pcall(api.nvim_del_augroup_by_id, h.augroup) end
  local insert = api.nvim_get_mode().mode:sub(1, 1) == 'i' and api.nvim_get_current_win() == h.qwin
  for _, w in ipairs({ h.qwin, h.lwin }) do
    if valid(w) then pcall(api.nvim_win_close, w, true) end
  end
  if insert then vim.cmd('stopinsert') end
end

---Close the open palette.
function M.close() close() end

---The rows of `rows` that fit `query`, in match order, with the byte ranges matched (`text` is
---`key  desc`); an empty query keeps every row and its headings.
---@param rows table[]
---@param query string
---@return table[] shown rows { row, text, pos? } (a heading row: { heading })
function M.filter(rows, query)
  local width = 0
  for _, r in ipairs(rows) do
    if not r.heading then width = math.max(width, vim.fn.strdisplaywidth(r.key)) end
  end
  local items = {}
  for _, r in ipairs(rows) do
    if r.heading then
      items[#items + 1] = { heading = r.heading }
    else
      items[#items + 1] = { row = r, text = r.key .. string.rep(' ', width - vim.fn.strdisplaywidth(r.key)) .. '  ' .. r.desc }
    end
  end
  if query == '' then return items end
  local candidates = vim.tbl_filter(function(it) return it.row ~= nil end, items)
  local found = vim.fn.matchfuzzypos(candidates, query, { key = 'text' })
  local out = {}
  for i, it in ipairs(found[1]) do
    out[i] = { row = it.row, text = it.text, pos = found[2][i] }
  end
  return out
end

-- The list as shown: lines, the row of each line (nil for a heading or a blank line).
local function render(h)
  local shown = M.filter(h.rows, h.query)
  local lines, at = {}, {}
  for _, it in ipairs(shown) do
    if it.heading then
      if #lines > 0 then lines[#lines + 1] = '' end
      lines[#lines + 1] = it.heading
    else
      lines[#lines + 1] = it.text
      at[#lines] = it
    end
  end
  if #lines == 0 then lines[1] = '  nothing matches' end
  vim.bo[h.lbuf].modifiable = true
  api.nvim_buf_set_lines(h.lbuf, 0, -1, false, lines)
  vim.bo[h.lbuf].modifiable = false
  api.nvim_buf_clear_namespace(h.lbuf, ns, 0, -1)
  for l, it in pairs(at) do
    for _, p in ipairs(it.pos or {}) do
      -- matchfuzzypos gives character positions; the help is ASCII apart from the odd key name
      local s = vim.str_byteindex(it.text, 'utf-32', p, false)
      local e = vim.str_byteindex(it.text, 'utf-32', p + 1, false)
      api.nvim_buf_set_extmark(h.lbuf, ns, l - 1, s, { end_col = e, hl_group = 'AgentIdeSearchMatch', priority = 200 })
    end
  end
  for l, line in ipairs(lines) do
    if not at[l] and line ~= '' then api.nvim_buf_set_extmark(h.lbuf, ns, l - 1, 0, { end_col = #line, hl_group = 'AgentIdeSection' }) end
  end
  h.at = at
  -- the selection: the same row when it is still shown, else the first row
  local sel
  for l, it in pairs(at) do
    if h.selected and it.row == h.selected then sel = l end
  end
  if not sel then
    for l = 1, #lines do
      if at[l] then sel = l; break end
    end
  end
  h.sel = sel
  h.selected = sel and at[sel].row or nil
  if valid(h.lwin) then api.nvim_win_set_cursor(h.lwin, { sel or 1, 0 }) end
end

-- Move the selection by `d` rows (skipping headings), wrapping around.
local function move(h, d)
  local n = api.nvim_buf_line_count(h.lbuf)
  local l = h.sel or 1
  for _ = 1, n do
    l = ((l - 1 + d) % n) + 1
    if h.at[l] then
      h.sel, h.selected = l, h.at[l].row
      api.nvim_win_set_cursor(h.lwin, { l, 0 })
      return
    end
  end
end

-- The key a help row stands for: the first of `a / b`, nil for a row without one.
local function first_key(row)
  local k = row and row.key and row.key:match('^(.-)%s*/%s') or (row and row.key)
  if not k or k == '' then return nil end
  return k
end

-- <CR>: close, then press the selected row's key in the window the help came from.
local function press(h)
  local row = h.selected
  local win = h.win
  close(h)
  local key = first_key(row)
  if not key or not valid(win) then return end
  api.nvim_set_current_win(win)
  api.nvim_feedkeys(vim.keycode(key), 'mt', false)
end

local function layout(rows, title)
  local w = vim.fn.strdisplaywidth(title) + 4
  local n = 0
  for _, r in ipairs(rows) do
    if r.heading then
      w = math.max(w, vim.fn.strdisplaywidth(r.heading))
      if n > 0 then n = n + 1 end
    else
      w = math.max(w, vim.fn.strdisplaywidth(r.key .. '  ' .. r.desc) + 4)
    end
    n = n + 1
  end
  local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
  w = math.max(20, math.min(w, cols - 4))
  local h = math.max(1, math.min(n, lines - 6))
  local row = math.max(0, math.floor((lines - h - 3) / 2))
  local col = math.max(0, math.floor((cols - w) / 2))
  return { query = { row = row, col = col, width = w, height = 1 }, list = { row = row + 3, col = col, width = w, height = h } }
end

local function float(buf, box, focus, extra)
  return api.nvim_open_win(buf, focus, vim.tbl_extend('force', {
    relative = 'editor', row = box.row, col = box.col, width = box.width, height = box.height,
    border = 'rounded', style = 'minimal', zindex = 60, noautocmd = not focus,
  }, extra or {}))
end

---Open the help `title` with `rows`.
---@param title string
---@param rows {key: string, desc: string}[] a row `{ heading = text }` is a sub-heading (after a blank line)
---@param opts? { win?: integer } the window <CR> presses a key in (default: the current one)
function M.open(title, rows, opts)
  close()
  opts = opts or {}
  local h = { rows = rows, query = '', win = opts.win or api.nvim_get_current_win() }
  if not valid(h.win) then h.win = api.nvim_get_current_win() end
  local L = layout(rows, title)
  local name = require('agent-ide.ui.bufname').set
  h.lbuf = api.nvim_create_buf(false, true)
  name(h.lbuf, 'agents://help')
  vim.bo[h.lbuf].bufhidden = 'wipe'
  vim.bo[h.lbuf].modifiable = false
  h.qbuf = api.nvim_create_buf(false, true)
  name(h.qbuf, 'agents://help/query')
  vim.bo[h.qbuf].bufhidden = 'wipe'
  vim.bo[h.qbuf].buftype = 'nofile'
  vim.b[h.qbuf].completion = false -- no completion menu in the query line (blink.cmp reads it)
  h.lwin = float(h.lbuf, L.list, false, { focusable = false,
    footer = { { ' type to filter · <CR> presses the key · <Esc> <Esc> closes ', 'FloatFooter' } }, footer_pos = 'right' })
  vim.wo[h.lwin].cursorline = true
  vim.wo[h.lwin].wrap = false
  vim.wo[h.lwin].list = false
  h.qwin = float(h.qbuf, L.query, true, { title = ' ' .. title .. ' ', title_pos = 'center' })
  vim.wo[h.qwin].wrap = false
  vim.wo[h.qwin].list = false
  H = h
  render(h)
  local cmp = package.loaded['cmp']
  if type(cmp) == 'table' and type(cmp.setup) == 'table' and cmp.setup.buffer then pcall(cmp.setup.buffer, { enabled = false }) end
  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = h.qbuf, nowait = true, silent = true, desc = 'Agent-IDE help' })
  end
  for _, lhs in ipairs({ '<C-n>', '<Down>' }) do map({ 'i', 'n' }, lhs, function() move(h, 1) end) end
  for _, lhs in ipairs({ '<C-p>', '<Up>' }) do map({ 'i', 'n' }, lhs, function() move(h, -1) end) end
  map('n', 'j', function() move(h, 1) end)
  map('n', 'k', function() move(h, -1) end)
  map({ 'i', 'n' }, '<CR>', function() press(h) end)
  for _, lhs in ipairs({ 'q', '<Esc>' }) do map('n', lhs, function() close(h) end) end
  h.augroup = api.nvim_create_augroup('agent-ide.help', { clear = true })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group = h.augroup, buffer = h.qbuf, callback = function()
    h.query = api.nvim_buf_get_lines(h.qbuf, 0, 1, false)[1] or ''
    render(h)
  end })
  api.nvim_create_autocmd('WinLeave', { group = h.augroup, buffer = h.qbuf, callback = function()
    vim.schedule(function()
      if H == h and api.nvim_get_current_win() ~= h.qwin then close(h) end
    end)
  end })
  api.nvim_create_autocmd('WinClosed', { group = h.augroup, callback = function(ev)
    if H == h and (tonumber(ev.match) == h.qwin or tonumber(ev.match) == h.lwin) then vim.schedule(function() close(h) end) end
  end })
  vim.cmd('startinsert!')
end

---Test only: the open palette's state.
function M._state()
  if not H then return nil end
  return { qwin = H.qwin, lwin = H.lwin, lbuf = H.lbuf, qbuf = H.qbuf, sel = H.sel, query = H.query,
    selected = H.selected and H.selected.key or nil }
end

return M
