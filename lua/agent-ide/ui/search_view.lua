-- Windows of the search picker: an input line on top, the results list below it and a preview
-- of the selected hit beside it (below it on narrow screens). Rendering only; no state.
local api = vim.api

local M = {}

local ns = api.nvim_create_namespace('agent-ide.search')
local ns_cur = api.nvim_create_namespace('agent-ide.search.current')

M.TAGS = { title = 'title ', prompt = 'you   ', answer = 'claude', tool = 'tool  ', project = 'proj  ' }
local KIND_HL = { title = 'AgentIdeSearchKindTitle', prompt = 'AgentIdeSearchKindPrompt',
  answer = 'AgentIdeSearchKindAnswer', tool = 'AgentIdeSearchKindTool', project = 'AgentIdeSearchMeta' }

local GROUPS = {
  AgentIdeSearchMatch = { link = 'Search' },
  AgentIdeSearchMatchCurrent = { link = 'CurSearch' },
  AgentIdeSearchTarget = { link = 'CursorLine' },
  AgentIdeSearchMeta = { link = 'Comment' },
  AgentIdeSearchLimited = { link = 'WarningMsg' },
  AgentIdeSearchKindTitle = { link = 'Directory' },
  AgentIdeSearchKindPrompt = { link = 'Identifier' },
  AgentIdeSearchKindAnswer = { link = 'String' },
  AgentIdeSearchKindTool = { link = 'Comment' },
}

function M.define()
  for name, def in pairs(GROUPS) do api.nvim_set_hl(0, name, vim.tbl_extend('force', def, { default = true })) end
end

local function layout()
  local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
  local W = math.max(20, math.min(cols - 2, math.max(60, math.floor(cols * 0.9))))
  local H = math.max(9, math.min(rows - 2, math.floor(rows * 0.85)))
  local row, col = math.max(0, math.floor((rows - H) / 2)), math.max(0, math.floor((cols - W) / 2))
  local body = math.max(1, H - 5)
  local L = { input = { row = row, col = col, width = W - 2, height = 1 } }
  if W >= 110 then
    local lw = math.floor((W - 4) * 0.45)
    L.list = { row = row + 3, col = col, width = lw, height = body }
    L.preview = { row = row + 3, col = col + lw + 2, width = W - 4 - lw, height = body }
  else
    local lh = math.max(1, math.floor((body - 2) / 2))
    L.list = { row = row + 3, col = col, width = W - 2, height = lh }
    L.preview = { row = row + 5 + lh, col = col, width = W - 2, height = math.max(1, body - lh - 2) }
  end
  return L
end

local function scratch(ft)
  local b = api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = 'wipe'
  if ft then vim.bo[b].filetype = ft end
  return b
end

local function float(buf, box, focus, extra)
  return api.nvim_open_win(buf, focus, vim.tbl_extend('force', {
    relative = 'editor', row = box.row, col = box.col, width = box.width, height = box.height,
    border = 'rounded', style = 'minimal', zindex = 60,
  }, extra or {}))
end

---Open the three windows; the input is focused.
function M.create()
  M.define()
  local L = layout()
  local v = { input_buf = scratch(), list_buf = scratch(), preview_buf = scratch('markdown') }
  local name = require('agent-ide.ui.bufname').set
  name(v.input_buf, 'agents://search')
  name(v.list_buf, 'agents://search/results')
  name(v.preview_buf, 'agents://search/preview')
  vim.bo[v.input_buf].buftype = 'nofile'
  v.list_win = float(v.list_buf, L.list, false, { focusable = false })
  v.preview_win = float(v.preview_buf, L.preview, false, { focusable = false })
  v.input_win = float(v.input_buf, L.input, true, { title = ' Search ', title_pos = 'left' })
  for _, w in ipairs({ v.list_win, v.preview_win, v.input_win }) do
    vim.wo[w].list = false
    vim.wo[w].foldenable = false
  end
  vim.wo[v.list_win].cursorline = true
  vim.wo[v.list_win].wrap = false
  vim.wo[v.preview_win].wrap = true
  vim.wo[v.preview_win].linebreak = true
  vim.wo[v.input_win].wrap = false
  return v
end

function M.valid(v)
  return v and api.nvim_win_is_valid(v.input_win) and api.nvim_win_is_valid(v.list_win) and api.nvim_win_is_valid(v.preview_win)
end

function M.close(v)
  for _, w in ipairs({ v.input_win, v.list_win, v.preview_win }) do
    if w and api.nvim_win_is_valid(w) then pcall(api.nvim_win_close, w, true) end
  end
end

---@param parts { text: string, hl?: string }[] title chunks of the input window
function M.set_title(v, parts)
  local chunks = {}
  for _, p in ipairs(parts) do chunks[#chunks + 1] = { p.text, p.hl or 'FloatTitle' } end
  api.nvim_win_set_config(v.input_win, { title = chunks, title_pos = 'left' })
end

local function age(ts)
  if not ts then return '' end
  local d = os.time() - ts
  if d < 60 then return 'now' end
  if d < 3600 then return math.floor(d / 60) .. 'm' end
  if d < 86400 then return math.floor(d / 3600) .. 'h' end
  if d < 30 * 86400 then return math.floor(d / 86400) .. 'd' end
  return os.date('%Y-%m-%d', ts)
end

---Show `hits` (selected: `sel`); `empty` is shown when there are none; `footer` below the list.
function M.render_list(v, hits, sel, empty, footer)
  local lines, metas, cut = {}, {}, {}
  local width = api.nvim_win_get_width(v.list_win)
  for i, h in ipairs(hits) do
    metas[i] = ' ' .. (h.count and ('×' .. h.count .. ' · ') or '') .. (h.project or '?') .. ' · ' .. age(h.ts) .. ' '
    local line = (M.TAGS[h.kind] or '?     ') .. ' ' .. h.snippet
    -- leave room for the project and age on the right
    local room = math.max(10, width - vim.fn.strdisplaywidth(metas[i]) - 1)
    if vim.fn.strdisplaywidth(line) > room then
      line = vim.fn.strcharpart(line, 0, room - 1)
      while vim.fn.strdisplaywidth(line) > room - 1 do line = vim.fn.strcharpart(line, 0, vim.fn.strchars(line) - 1) end
      cut[i] = #line
      line = line .. '…'
    end
    lines[i] = line
  end
  if #hits == 0 then lines = { '  ' .. empty } end
  vim.bo[v.list_buf].modifiable = true
  api.nvim_buf_set_lines(v.list_buf, 0, -1, false, lines)
  vim.bo[v.list_buf].modifiable = false
  api.nvim_buf_clear_namespace(v.list_buf, ns, 0, -1)
  for i, h in ipairs(hits) do
    local tag = #(M.TAGS[h.kind] or '?     ')
    api.nvim_buf_set_extmark(v.list_buf, ns, i - 1, 0, { end_col = tag, hl_group = KIND_HL[h.kind] or 'AgentIdeSearchMeta' })
    for _, r in ipairs(h.positions or {}) do
      local s, e = tag + 1 + r[1], tag + 1 + r[2]
      if e <= (cut[i] or #lines[i]) and s < e then
        api.nvim_buf_set_extmark(v.list_buf, ns, i - 1, s, { end_col = e, hl_group = 'AgentIdeSearchMatch', priority = 200 })
      end
    end
    api.nvim_buf_set_extmark(v.list_buf, ns, i - 1, 0, { virt_text = { { metas[i], 'AgentIdeSearchMeta' } },
      virt_text_pos = 'right_align' })
  end
  if #hits == 0 then
    api.nvim_buf_set_extmark(v.list_buf, ns, 0, 0, { end_col = #lines[1], hl_group = 'AgentIdeSearchMeta' })
  end
  M.set_footer(v, footer)
  M.select(v, #hits > 0 and sel or 1)
end

function M.set_footer(v, footer)
  api.nvim_win_set_config(v.list_win, { footer = { { ' ' .. footer .. ' ', 'FloatFooter' } }, footer_pos = 'right' })
end

function M.select(v, sel)
  local n = api.nvim_buf_line_count(v.list_buf)
  api.nvim_win_set_cursor(v.list_win, { math.max(1, math.min(sel, n)), 0 })
end

---Mark the occurrences `occ` (from `search_hl.occurrences`) in `buf`.
function M.mark(buf, occ)
  for _, o in ipairs(occ) do
    api.nvim_buf_set_extmark(buf, ns, o.line - 1, o.s, { end_col = o.e, hl_group = 'AgentIdeSearchMatch', priority = 200 })
  end
end

---Show occurrence `o` as the current one: marked, on screen (its fold open, centred), with
---`footer` below the preview.
function M.show_match(v, o, footer)
  local buf, win = v.preview_buf, v.preview_win
  api.nvim_buf_clear_namespace(buf, ns_cur, 0, -1)
  if o then
    api.nvim_buf_set_extmark(buf, ns_cur, o.line - 1, o.s, { end_col = o.e, hl_group = 'AgentIdeSearchMatchCurrent',
      priority = 210 })
    api.nvim_win_set_cursor(win, { o.line, o.s })
    api.nvim_win_call(win, function() vim.cmd('normal! zvzz') end)
  end
  if footer then M.set_preview_footer(v, footer) end
end

function M.set_preview_footer(v, footer)
  api.nvim_win_set_config(v.preview_win, { footer = { { ' ' .. footer .. ' ', 'FloatFooter' } }, footer_pos = 'right' })
end

---Show `out.lines` in the preview, line `target` (the hit) marked; `occ` (occurrences of the
---query) marked, occurrence `cur` current and on screen; without one, `top` shows the first
---line, else the hit is centred.
---@param m { occ: table[], cur: integer|nil, top: boolean|nil }
function M.render_preview(v, out, target, m, title, footer)
  local lines, buf, win = out.lines, v.preview_buf, v.preview_win
  -- folded like the chat (tool blocks closed), through the same fold expression
  local history = require('agent-ide.ui.history')
  history.set_folds(buf, require('agent-ide.transcript.render').fold_levels(out.folds or {}, #lines))
  vim.bo[buf].bufhidden = 'wipe' -- set_folds makes it 'hide' the first time
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  history.mark_answers(buf, 1, out.answers or {})
  history.mark_diff(buf, 1, out.added or {}, out.removed or {})
  history.apply_win(win, buf)
  vim.wo[win].winbar = ''
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  api.nvim_buf_clear_namespace(buf, ns_cur, 0, -1)
  target = math.max(1, math.min(target or 1, #lines))
  if #lines > 0 and target then
    api.nvim_buf_set_extmark(buf, ns, target - 1, 0, { line_hl_group = 'AgentIdeSearchTarget' })
  end
  m = m or { occ = {} }
  M.mark(buf, m.occ)
  api.nvim_win_set_config(win, {
    title = { { ' ' .. (title or ''):gsub('[\r\n]+', ' ') .. ' ', 'FloatTitle' } }, title_pos = 'center',
    footer = { { ' ' .. (footer or '') .. ' ', 'FloatFooter' } }, footer_pos = 'right',
  })
  local o = m.cur and m.occ[m.cur]
  if o then
    api.nvim_win_set_cursor(win, { o.line, o.s })
    api.nvim_win_call(win, function() vim.cmd('normal! zx') end) -- folds recomputed, then zv
    return M.show_match(v, o)
  end
  api.nvim_win_set_cursor(win, { m.top and 1 or target, 0 })
  -- the hit's fold (if any) open, the hit in the middle (or the top on screen)
  api.nvim_win_call(win, function() vim.cmd(m.top and 'normal! zxzt' or 'normal! zxzz') end) -- zx: folds recomputed, then zv
end

return M
