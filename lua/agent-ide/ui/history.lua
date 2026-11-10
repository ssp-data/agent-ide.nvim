-- Shared helpers for read-only markdown transcript buffers: fold levels from the renderer,
-- window options and a per-buffer winbar.
local api = vim.api

local M = {}

local augroup = api.nvim_create_augroup('agent-ide.history', { clear = true })

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
