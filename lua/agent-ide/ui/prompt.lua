-- The prompt buffer of a chat: a normal markdown buffer whose text is sent to Claude.
local api = vim.api

local M = {}

---The text a prompt buffer sends: lines joined with '\n', trailing blank lines removed.
---@param lines string[]
---@return string
function M.text_to_send(lines)
  local last = #lines
  while last > 0 and not lines[last]:find('%S') do last = last - 1 end
  return table.concat(lines, '\n', 1, last)
end

---Create the prompt buffer of session `s`: `agent-ide://prompt/<id>`, `acwrite`, markdown.
---`:w` only clears 'modified' (saving prompts comes later).
---@param s table Session
---@return integer buf
function M.create(s)
  local buf = api.nvim_create_buf(false, false)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  api.nvim_buf_set_name(buf, 'agent-ide://prompt/' .. s.id)
  vim.bo[buf].filetype = 'markdown'
  api.nvim_create_autocmd('BufWriteCmd', { buffer = buf,
    callback = function(ev) vim.bo[ev.buf].modified = false end })
  return buf
end

---Window options for a window showing a prompt buffer (it may be split off a transcript window).
---@param win integer
function M.setup_win(win)
  for name, value in pairs({ winfixheight = true, winbar = '', foldenable = false, foldmethod = 'manual' }) do
    api.nvim_set_option_value(name, value, { scope = 'local', win = win })
  end
end

---Empty the prompt buffer after a send.
---@param buf integer
function M.clear(buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.bo[buf].modified = false
end

---Put prompts back (e.g. dropped from the queue) above the text already in the buffer,
---separated by blank lines.
---@param buf integer
---@param texts string[]
function M.restore(buf, texts)
  local lines = vim.split(table.concat(texts, '\n\n'), '\n', { plain = true })
  local cur = api.nvim_buf_get_lines(buf, 0, -1, false)
  if #cur > 1 or cur[1] ~= '' then
    lines[#lines + 1] = ''
    vim.list_extend(lines, cur)
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

return M
