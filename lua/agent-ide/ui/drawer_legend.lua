-- The legend of the drawer's state marks (`● input  ◐ running  ● idle  ○ parked  ✓ done
-- ✗ failed`), pinned to the bottom of the drawer window: a non-focusable float anchored to that
-- window, so it stays put while the tree scrolls and works with any 'laststatus' (a window's own
-- statusline does not exist with a global one). Hidden while the drawer is too small; `gL`
-- toggles it (remembered across restarts, prefs.lua). The tree's cursor row is never under it: the view (or the cursor) moves.
local api = vim.api
local config = require('agent-ide.config')

local M = {}

M.MIN_HEIGHT, M.MIN_WIDTH = 12, 24

-- state (its mark and colour) and the word shown for it
local ITEMS = {
  { 'waiting', 'input' }, { 'busy', 'running' }, { 'idle', 'idle' },
  { 'parked', 'parked' }, { 'done', 'done' }, { 'failed', 'failed' },
}
local WORD_GROUP = 'AgentIdeAge' -- dim

local S = { win = nil, buf = nil, parent = nil, text = nil, height = 0 }
local on -- nil: `config.drawer.legend` decides
local augroup

---The legend for `width` columns: one line, else two split as evenly as possible, right-aligned;
---items two spaces apart (one when two do not fit); and highlight ranges (byte columns). Nil
---when it needs more than two lines even so.
---@param icons table icon set (`config.icons`)
---@param width integer
---@return { lines: string[], hl: { line: integer, col_start: integer, col_end: integer, group: string }[] }|nil
function M.layout(icons, width)
  local groups = require('agent-ide.ui.tree').STATE_GROUP
  local items = {}
  for _, it in ipairs(ITEMS) do
    local mark = icons[it[1]] or ''
    items[#items + 1] = { mark = mark, word = it[2], group = groups[it[1]],
      w = (mark ~= '' and vim.fn.strdisplaywidth(mark) + 1 or 0) + vim.fn.strdisplaywidth(it[2]) }
  end
  local function span(from, to, sep)
    local r, n = {}, 0
    for i = from, to do
      r[#r + 1] = items[i]
      n = n + items[i].w + (i > from and sep or 0)
    end
    r.w = n
    return r
  end
  for _, sep in ipairs({ 2, 1 }) do
    -- one line, else the most even split into two
    local rows
    local all = span(1, #items, sep)
    if all.w <= width then
      rows = { all }
    else
      for k = 1, #items - 1 do
        local a, b = span(1, k, sep), span(k + 1, #items, sep)
        if a.w <= width and b.w <= width and (not rows or math.max(a.w, b.w) < math.max(rows[1].w, rows[2].w)) then
          rows = { a, b }
        end
      end
    end
    if rows then
      local out = { lines = {}, hl = {} }
      for li, r in ipairs(rows) do
        local text = string.rep(' ', width - r.w)
        for i, it in ipairs(r) do
          if i > 1 then text = text .. string.rep(' ', sep) end
          if it.mark ~= '' then
            out.hl[#out.hl + 1] = { line = li, col_start = #text, col_end = #text + #it.mark, group = it.group }
            text = text .. it.mark .. ' '
          end
          -- without a mark the word carries the state's colour
          local group = it.mark ~= '' and WORD_GROUP or it.group
          out.hl[#out.hl + 1] = { line = li, col_start = #text, col_end = #text + #it.word, group = group }
          text = text .. it.word
        end
        out.lines[li] = text
      end
      return out
    end
  end
end

local ns = api.nvim_create_namespace('agent-ide.drawer_legend')

-- The toggle as remembered (prefs.json), else `config.drawer.legend`.
local function enabled()
  if on == nil then
    local saved = require('agent-ide.prefs').get('legend')
    if saved ~= nil then
      on = saved
    else
      local d = config.get().drawer
      on = not (type(d) == 'table' and d.legend == false)
    end
  end
  return on
end

local function drawer_win()
  local w = require('agent-ide.ui.drawer').state().win
  if w and api.nvim_win_is_valid(w) and api.nvim_win_get_tabpage(w) == api.nvim_get_current_tabpage() then return w end
end

---Close the legend float (it is opened again by the next `update`).
function M.close()
  local w = S.win
  S.win, S.parent, S.height = nil, nil, 0
  if w and api.nvim_win_is_valid(w) then pcall(api.nvim_win_close, w, true) end
end

-- The cursor row of the drawer must stay above the legend: on a cursor move the view scrolls,
-- on a scroll (<C-y>, the mouse) the cursor moves up instead.
local function keep_clear(dwin, move_cursor)
  if not (S.win and S.parent == dwin) then return end
  local room = api.nvim_win_get_height(dwin) - S.height
  if room < 1 then return end
  api.nvim_win_call(dwin, function()
    local view = vim.fn.winsaveview()
    if view.lnum - view.topline + 1 <= room then return end
    if move_cursor then
      api.nvim_win_set_cursor(dwin, { view.topline + room - 1, 0 })
    else
      vim.fn.winrestview({ topline = view.lnum - room + 1 })
    end
  end)
end

local function ensure_buf()
  if S.buf and api.nvim_buf_is_valid(S.buf) then return S.buf end
  S.buf = api.nvim_create_buf(false, true)
  require('agent-ide.ui.bufname').set(S.buf, 'agents://legend')
  vim.bo[S.buf].bufhidden = 'hide'
  S.text = nil
  return S.buf
end

local setup_autocmds

---Show, move or hide the legend for the drawer window as it is now (its size, the tab, the
---toggle); keeps the cursor row clear of it.
function M.update()
  setup_autocmds()
  local dwin = drawer_win()
  if not dwin or not enabled() then return M.close() end
  local h, w = api.nvim_win_get_height(dwin), api.nvim_win_get_width(dwin)
  local l = h >= M.MIN_HEIGHT and w >= M.MIN_WIDTH and M.layout(config.get().icons or {}, w) or nil
  if not l then return M.close() end
  local buf = ensure_buf()
  local text = table.concat(l.lines, '\n')
  if text ~= S.text then
    S.text = text
    api.nvim_buf_set_lines(buf, 0, -1, false, l.lines)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, r in ipairs(l.hl) do
      api.nvim_buf_set_extmark(buf, ns, r.line - 1, r.col_start, { end_col = r.col_end, hl_group = r.group })
    end
  end
  local cfg = { relative = 'win', win = dwin, row = h - #l.lines, col = 0, width = w, height = #l.lines,
    focusable = false, zindex = 10 }
  if S.win and api.nvim_win_is_valid(S.win) and S.parent == dwin then
    api.nvim_win_set_config(S.win, cfg)
  else
    M.close()
    cfg.style, cfg.noautocmd, cfg.border = 'minimal', true, 'none'
    S.win = api.nvim_open_win(buf, false, cfg)
    S.parent = dwin
    vim.wo[S.win].winhighlight = 'NormalFloat:Normal'
    vim.wo[S.win].wrap = false
  end
  S.height = #l.lines
  keep_clear(dwin, false)
end

---`gL`: show or hide the legend; remembered across restarts.
function M.toggle()
  on = not enabled()
  require('agent-ide.prefs').set('legend', on)
  M.update()
  if on and not S.win then
    vim.notify('Agent-IDE: legend hidden while the drawer is smaller than '
      .. M.MIN_WIDTH .. 'x' .. M.MIN_HEIGHT, vim.log.levels.INFO)
  end
end

setup_autocmds = function()
  if augroup then return end
  augroup = api.nvim_create_augroup('agent-ide.drawer_legend', { clear = true })
  api.nvim_create_autocmd({ 'WinResized', 'VimResized', 'TabEnter' }, { group = augroup, callback = function()
    if S.win or drawer_win() then M.update() end
  end })
  api.nvim_create_autocmd('TabLeave', { group = augroup, callback = M.close })
  api.nvim_create_autocmd('WinClosed', { group = augroup, callback = function(ev)
    local w = tonumber(ev.match)
    if w == S.parent then
      M.close()
    elseif w == S.win then
      S.win, S.parent, S.height = nil, nil, 0
    end
  end })
  api.nvim_create_autocmd('CursorMoved', { group = augroup, callback = function()
    if S.win and api.nvim_get_current_win() == S.parent then keep_clear(S.parent, false) end
  end })
  api.nvim_create_autocmd('WinScrolled', { group = augroup, callback = function(ev)
    if S.win and tonumber(ev.match) == S.parent then keep_clear(S.parent, true) end
  end })
end

---State for tests: { win, parent, height, on }.
function M._state() return { win = S.win, parent = S.parent, height = S.height, on = enabled() } end

---Test only: forget the toggle.
function M._reset()
  M.close()
  on = nil
end

return M
