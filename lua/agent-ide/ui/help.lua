-- Centered read-only float listing keys and what they do.
local api = vim.api

local M = {}

local win ---@type integer|nil

-- Close the help float `w` (default: the current one); a stale request for an older float is harmless.
local function close(w)
  w = w or win
  if w and api.nvim_win_is_valid(w) then api.nvim_win_close(w, true) end
  if w == win then win = nil end
end

---@param title string
---@param rows {key: string, desc: string}[]
function M.open(title, rows)
  close()
  local width = 0
  for _, r in ipairs(rows) do width = math.max(width, vim.fn.strdisplaywidth(r.key)) end
  local lines = {}
  for _, r in ipairs(rows) do
    lines[#lines + 1] = r.key .. string.rep(' ', width - vim.fn.strdisplaywidth(r.key)) .. '  ' .. r.desc
  end
  local w = vim.fn.strdisplaywidth(title) + 2
  for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  local h = #lines
  win = api.nvim_open_win(buf, true, {
    relative = 'editor', width = w, height = h, border = 'rounded',
    row = math.max(0, math.floor((vim.o.lines - h) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - w) / 2)),
    title = ' ' .. title .. ' ', title_pos = 'center', style = 'minimal',
  })
  vim.wo[win].list = false
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  -- q and <Esc> close; `/` and `?` search the help (n / N step), the command line keeps it open
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', lhs, function() close() end, { buffer = buf, nowait = true, silent = true })
  end
  local mine = win
  api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = function() vim.schedule(function() close(mine) end) end })
end

return M
