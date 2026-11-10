-- Asks before Neovim quits while a session started here is still working, so quitting does
-- not silently kill a turn. `ExitPre` fires only for a quit that really exits Neovim (the last
-- window of the last tab, or a quit-all), unlike `QuitPre`, which also fires when any window
-- closes. A forced quit (`:qa!`, `:q!`, ...) is not asked about.
--
-- Cancelling: an autocommand cannot return a value, so the quit is made to fail the way
-- Neovim itself refuses to leave a modified buffer: a hidden unnamed-file buffer is marked
-- modified (E162). Neovim then switches the window to that buffer; the next tick puts the
-- window back and deletes the buffer.
local api = vim.api

local M = {}

local MESSAGE = 'Agent-IDE: %d session(s) still working. Quit anyway?'
local BUFFER_NAME = 'Agent-IDE: sessions still working'

local last_cmd ---@type string|nil the typed ex command being executed (cleared on the next tick)
local asking = false

---True when the ex command line ends a Neovim session without asking (`q!`, `qa!`, `wq!`, `x!`, ...).
---@param cmd string|nil
---@return boolean
function M._forced(cmd)
  for part in (cmd or ''):gmatch('[^|]+') do
    local word = part:match("^[%s:%d,;%.%$%%'<>%+%-]*(%a+)!")
    if word and (word:find('^q') or word:find('^wq') or word:find('^x') or word:find('^exi')) then return true end
  end
  return false
end

---Sessions started by this Neovim that are running a turn or wait for an answer.
---@return integer
function M.working()
  local n = 0
  for _, s in ipairs(require('agent-ide.session').all()) do
    if s.owned and (s.state == 'busy' or s.state == 'waiting') then n = n + 1 end
  end
  return n
end

local function refuse_quit()
  local win, prev = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local scratch = api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = ''
  pcall(api.nvim_buf_set_name, scratch, BUFFER_NAME)
  vim.bo[scratch].modified = true
  vim.schedule(function()
    if api.nvim_win_is_valid(win) and api.nvim_buf_is_valid(prev) and api.nvim_win_get_buf(win) ~= prev then
      pcall(api.nvim_win_set_buf, win, prev)
    end
    pcall(api.nvim_buf_delete, scratch, { force = true })
  end)
end

local function on_exit_pre()
  if asking then return end
  local n = M.working()
  if n == 0 or M._forced(last_cmd) then return end
  asking = true -- one question per quit, whatever fires this event again
  local choice = vim.fn.confirm(MESSAGE:format(n), '&Quit\n&Cancel', 2)
  vim.schedule(function() asking = false end)
  if choice ~= 1 then refuse_quit() end
end

function M.setup()
  local group = api.nvim_create_augroup('agent-ide.quit_guard', { clear = true })
  api.nvim_create_autocmd('CmdlineLeave', { group = group, pattern = ':', callback = function()
    if vim.v.event.abort then return end
    last_cmd = vim.fn.getcmdline()
    vim.schedule(function() last_cmd = nil end)
  end })
  api.nvim_create_autocmd('ExitPre', { group = group, callback = on_exit_pre })
end

return M
