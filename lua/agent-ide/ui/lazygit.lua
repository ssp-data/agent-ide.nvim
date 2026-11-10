-- `gl`: hand acting over to lazygit for one repository. Through Snacks.lazygit when Snacks is
-- loaded, else in a new tab running `lazygit -p <root>` in a terminal. The repository's git data
-- is invalidated when lazygit exits.
local api = vim.api
local cache = require('agent-ide.git_cache')

local M = {}

local function invalidate(root) vim.schedule(function() cache.invalidate(root) end) end

-- Snacks when it is loaded and has lazygit (a function or a callable table).
local function snacks()
  local s = rawget(_G, 'Snacks')
  if type(s) == 'table' and s.lazygit ~= nil then return s end
end

-- Invalidate when the terminal buffer of a Snacks window closes.
local function watch_buf(buf, root)
  if type(buf) ~= 'number' or not api.nvim_buf_is_valid(buf) then return invalidate(root) end
  api.nvim_create_autocmd({ 'TermClose', 'BufWipeout' }, { buffer = buf, once = true, callback = function() invalidate(root) end })
end

---Open lazygit for repository `root`.
---@param root string
function M.open(root)
  local s = snacks()
  if s then
    local ok, win = pcall(s.lazygit, { cwd = root })
    if ok then
      watch_buf(type(win) == 'table' and win.buf or nil, root)
      return
    end
  end
  if vim.fn.executable('lazygit') ~= 1 then
    return vim.notify('Agent-IDE: lazygit is not installed', vim.log.levels.WARN)
  end
  vim.cmd('tabnew')
  local tab, buf = api.nvim_get_current_tabpage(), api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = 'wipe'
  vim.fn.jobstart({ 'lazygit', '-p', root }, { term = true, on_exit = function()
    invalidate(root)
    vim.schedule(function()
      -- close the lazygit tab when it is still there and shows the terminal
      if api.nvim_tabpage_is_valid(tab) and api.nvim_buf_is_valid(buf) and #api.nvim_list_tabpages() > 1 then
        for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
          if api.nvim_win_get_buf(w) == buf then
            pcall(vim.cmd, 'tabclose ' .. api.nvim_tabpage_get_number(tab))
            break
          end
        end
      end
      if api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end
    end)
  end })
  vim.cmd('startinsert')
end

return M
