-- The window for Claude's asks: the question on its own rows at the top, a rule, then the
-- numbered choices. It takes the place of `vim.ui.select` (same call shape) because pickers
-- show a select's prompt as a one-line title and cut it. `j`/`k` move between the choices,
-- `<CR>` picks, `1`-`9` pick directly, `q`, `<Esc>` or leaving the window cancel. The callback
-- runs once, scheduled, after the window is closed.
local api = vim.api

local M = {}

local MAX_WIDTH = 120

---@alias agent-ide.AskRow { text: string, hl?: string }

---Lines of the window (pure): the rows of the question, a rule as wide as the window, the
---choices (`1. Allow`; past nine without a number). `width` is the widest line, at least 30
---and at most `max_width` (longer lines wrap in the window).
---@param rows agent-ide.AskRow[]
---@param labels string[]
---@param max_width? integer default 120
---@return { lines: string[], hls: { line: integer, hl: string, col?: integer, end_col?: integer }[], first: integer, last: integer, width: integer }
function M.layout(rows, labels, max_width)
  local lines, hls, width = {}, {}, 30
  local function add(text, hl, col, end_col)
    lines[#lines + 1] = text
    width = math.max(width, vim.fn.strdisplaywidth(text))
    if hl then hls[#hls + 1] = { line = #lines, hl = hl, col = col, end_col = end_col } end
  end
  for _, r in ipairs(rows) do add(r.text, r.hl) end
  local rule = #lines + 1
  add('')
  for i, label in ipairs(labels) do
    local num = i <= 9 and (i .. '. ') or '   '
    add(num .. label, 'AgentIdeAskNumber', 0, #num)
  end
  width = math.max(20, math.min(width, max_width or MAX_WIDTH))
  lines[rule] = ('─'):rep(width)
  hls[#hls + 1] = { line = rule, hl = 'AgentIdeAskRule' }
  return { lines = lines, hls = hls, first = rule + 1, last = #lines, width = width }
end

local ns = api.nvim_create_namespace('agent-ide.ask_float')

---Open the window. Same shape as `vim.ui.select`, plus `opts.rows` (the question's rows; the
---prompt alone when absent) and `opts.title` (the border's short title).
---@param items any[]
---@param opts { prompt?: string, rows?: agent-ide.AskRow[], title?: string, format_item?: fun(item: any): string }
---@param on_choice fun(item: any|nil, idx: integer|nil)
---@return integer win
function M.select(items, opts, on_choice)
  local labels = {}
  for i, it in ipairs(items) do labels[i] = opts.format_item and opts.format_item(it) or tostring(it) end
  local rows = opts.rows or { { text = opts.prompt or 'Choose', hl = 'AgentIdeAskQuestion' } }
  local L = M.layout(rows, labels, math.min(MAX_WIDTH, vim.o.columns - 6))
  local origin = api.nvim_get_current_win()

  local buf = api.nvim_create_buf(false, true)
  require('agent-ide.ui.bufname').set(buf, 'agents://ask')
  vim.bo[buf].bufhidden = 'wipe'
  api.nvim_buf_set_lines(buf, 0, -1, false, L.lines)
  vim.bo[buf].modifiable = false
  for _, h in ipairs(L.hls) do
    if h.end_col then
      api.nvim_buf_set_extmark(buf, ns, h.line - 1, h.col or 0, { end_col = h.end_col, hl_group = h.hl })
    else
      api.nvim_buf_set_extmark(buf, ns, h.line - 1, 0, { line_hl_group = h.hl })
    end
  end

  local screen_lines = vim.o.lines - vim.o.cmdheight - 2
  local width = L.width
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor', width = width, height = math.min(#L.lines, screen_lines - 2),
    row = 0, col = math.floor((vim.o.columns - width) / 2),
    border = 'rounded', style = 'minimal', zindex = 60,
    title = ' ' .. (opts.title or 'Claude asks') .. ' ', title_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].breakindentopt = 'shift:3' -- a wrapped choice continues under its text
  vim.wo[win].cursorline = true
  -- long rows wrap: size the window to the text as shown, then centre it
  local h = math.min(api.nvim_win_text_height(win, {}).all, screen_lines - 2)
  api.nvim_win_set_config(win, { relative = 'editor', height = h, width = width,
    row = math.max(0, math.floor((screen_lines - h) / 2)), col = math.floor((vim.o.columns - width) / 2) })
  api.nvim_win_set_cursor(win, { L.first, 0 })

  local done = false
  local function finish(idx)
    if done then return end
    done = true
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    if api.nvim_win_is_valid(origin) then api.nvim_set_current_win(origin) end
    vim.schedule(function() on_choice(idx and items[idx], idx) end)
  end
  local function map(lhs, fn) vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true }) end
  map('<CR>', function() finish(api.nvim_win_get_cursor(win)[1] - L.first + 1) end)
  for _, k in ipairs({ 'q', '<Esc>', '<C-c>' }) do map(k, function() finish(nil) end) end
  for i = 1, math.min(#items, 9) do map(tostring(i), function() finish(i) end) end
  local function step(d)
    local row = api.nvim_win_get_cursor(win)[1] + d * vim.v.count1
    api.nvim_win_set_cursor(win, { math.min(math.max(row, L.first), L.last), 0 })
  end
  for _, k in ipairs({ 'j', '<Down>', '<C-n>' }) do map(k, function() step(1) end) end
  for _, k in ipairs({ 'k', '<Up>', '<C-p>' }) do map(k, function() step(-1) end) end

  local group = api.nvim_create_augroup('agent-ide.ask_float.' .. buf, { clear = true })
  api.nvim_create_autocmd('CursorMoved', { group = group, buffer = buf, callback = function()
    if not api.nvim_win_is_valid(win) then return end
    local row = api.nvim_win_get_cursor(win)[1]
    local clamped = math.min(math.max(row, L.first), L.last)
    if clamped ~= row then api.nvim_win_set_cursor(win, { clamped, 0 }) end
  end })
  api.nvim_create_autocmd('WinLeave', { group = group, buffer = buf, callback = function()
    vim.schedule(function() finish(nil) end)
  end })
  api.nvim_create_autocmd('BufWipeout', { group = group, buffer = buf, callback = function()
    pcall(api.nvim_del_augroup_by_id, group)
    finish(nil)
  end })
  return win
end

return M
