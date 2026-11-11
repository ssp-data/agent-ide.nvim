-- Shared helpers for read-only markdown transcript buffers: fold levels from the renderer,
-- window options and a per-buffer winbar.
local api = vim.api

local M = {}

local augroup = api.nvim_create_augroup('agent-ide.history', { clear = true })
local ns = api.nvim_create_namespace('agent-ide.history.answers')
local ns_diff = api.nvim_create_namespace('agent-ide.history.diff')

M.ANSWER_MARK = '● '

-- Per transcript buffer: { levels = string[], winbar = string|nil }
local bufs = {}

---Fold level of line `lnum` in the current buffer; '0' for buffers this module does not know.
---@param lnum integer
---@return string
function M.foldexpr(lnum)
  local b = bufs[api.nvim_get_current_buf()]
  return b and b.levels and b.levels[lnum] or '0'
end

local WIN_OPTS = {
  wrap = true,
  linebreak = true,
  foldmethod = 'expr',
  foldexpr = "v:lua.require'agent-ide.ui.history'.foldexpr(v:lnum)",
  foldlevel = 0,
  foldtext = '',
  foldenable = true,
}

---Apply the transcript window options (folds, wrap, winbar of `buf`) to `win`.
---@param win integer
---@param buf integer
function M.apply_win(win, buf)
  for name, value in pairs(WIN_OPTS) do
    api.nvim_set_option_value(name, value, { scope = 'local', win = win })
  end
  local b = bufs[buf]
  api.nvim_set_option_value('winbar', b and b.winbar or '', { scope = 'local', win = win })
  -- 'list' as it was before the raw view (ui/raw.lua) turned it off in this window
  local list = vim.w[win].agent_ide_list
  if list ~= nil then
    api.nvim_set_option_value('list', list, { scope = 'local', win = win })
    vim.w[win].agent_ide_list = nil
  end
end

---Make `buf` a read-only transcript buffer whose windows fold with the levels from `set_folds`.
---Idempotent.
---@param buf integer
function M.setup_buf(buf)
  if bufs[buf] then return end
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = false
  bufs[buf] = { levels = {} }
  -- set after the filetype so a markdown ftplugin cannot override the fold options
  vim.bo[buf].filetype = 'markdown'
  api.nvim_create_autocmd('BufWinEnter', { group = augroup, buffer = buf,
    callback = function(ev) M.apply_win(api.nvim_get_current_win(), ev.buf) end })
  api.nvim_create_autocmd('BufWipeout', { group = augroup, buffer = buf,
    callback = function(ev) bufs[ev.buf] = nil end })
  -- a long transcript must not freeze Neovim when a render plugin sets 'conceallevel'
  require('agent-ide.util.ts_conceal').keep_off(buf, augroup)
  vim.schedule(function()
    if api.nvim_buf_is_valid(buf) then require('agent-ide.util.ts_conceal').off(buf) end
  end)
end

---Store the per-line fold levels (as from `render.fold_levels`) read by `foldexpr` for `buf`.
---The table is kept by reference: a caller may update it in place before changing lines.
---@param buf integer
---@param levels string[]
function M.set_folds(buf, levels)
  M.setup_buf(buf)
  bufs[buf].levels = levels
end

---Set the winbar (statusline syntax) of `buf`, in every window showing it now and later.
---@param buf integer
---@param text string
function M.set_winbar(buf, text)
  M.setup_buf(buf)
  bufs[buf].winbar = text
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    api.nvim_set_option_value('winbar', text, { scope = 'local', win = win })
  end
end

---Replace the whole content of a transcript buffer with `lines` (e.g. a notice).
---@param buf integer
---@param lines string[]
function M.set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  require('agent-ide.util.ts_conceal').off(buf)
end

---Mark the lines where Claude's text starts (`render.render().answers`, 1-based) with a `●` as
---inline virtual text: the buffer text stays as it is, so yanks and text objects copy the words
---only. Marks from line `from` (1-based) on are replaced; earlier ones stay.
---@param buf integer
---@param from integer
---@param lines integer[]
function M.mark_answers(buf, from, lines)
  api.nvim_buf_clear_namespace(buf, ns, from - 1, -1)
  local count = api.nvim_buf_line_count(buf)
  for _, l in ipairs(lines) do
    if l >= from and l <= count then
      api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { virt_text = { { M.ANSWER_MARK, 'AgentIdeAnswerMark' } },
        virt_text_pos = 'inline', right_gravity = false })
    end
  end
end

---Lines marked as answer starts in `buf` (tests).
---@param buf integer
---@return integer[]
function M.answer_marks(buf)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do out[#out + 1] = m[2] + 1 end
  table.sort(out)
  return out
end

---Colour the removed and added lines of the `Edit` folds (`render.render().removed` and
---`.added`, 1-based) red and green, over the markdown highlighting. Marks from line `from`
---(1-based) on are replaced; earlier ones stay.
---@param buf integer
---@param from integer
---@param added integer[]
---@param removed integer[]
function M.mark_diff(buf, from, added, removed)
  api.nvim_buf_clear_namespace(buf, ns_diff, from - 1, -1)
  local count = api.nvim_buf_line_count(buf)
  for hl, lines in pairs({ AgentIdeDiffAdd = added, AgentIdeDiffDel = removed }) do
    for _, l in ipairs(lines) do
      if l >= from and l <= count then
        local text = api.nvim_buf_get_lines(buf, l - 1, l, false)[1]
        api.nvim_buf_set_extmark(buf, ns_diff, l - 1, 0, { end_col = #text, hl_group = hl, priority = 200 })
      end
    end
  end
end

---Coloured diff lines of `buf`, in line order (tests).
---@param buf integer
---@return { line: integer, col: integer, end_col: integer, hl: string }[]
function M.diff_marks(buf)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns_diff, 0, -1, { details = true })) do
    out[#out + 1] = { line = m[2] + 1, col = m[3], end_col = m[4].end_col, hl = m[4].hl_group }
  end
  table.sort(out, function(a, b) return a.line < b.line end)
  return out
end

---Per-line fold levels of transcript `buf` ('>1' starts a fold), or nil for other buffers.
---@param buf integer
---@return string[]|nil
function M.levels(buf)
  return bufs[buf] and bufs[buf].levels
end

---Stored fold levels of `buf` (tests).
function M._levels(buf)
  return bufs[buf] and bufs[buf].levels
end

return M
