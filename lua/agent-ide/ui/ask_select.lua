-- One choice for the user, the way Claude's asks are shown: the plugin's ask window
-- (ui/ask_float.lua), or `vim.ui.select` with the one-line prompt when `chat.ask_picker` is
-- 'select'. Used for permissions and questions (ui/permission.lua) and for the review's own
-- questions (ui/review_send.lua).
local api = vim.api
local config = require('agent-ide.config')

local M = {}

---One line that fits the space left for messages, so it never causes a hit-enter prompt.
---@param msg string
function M.echo(msg)
  local room = math.max(vim.v.echospace, 1)
  if vim.fn.strdisplaywidth(msg) > room then
    local n = vim.fn.strchars(msg)
    while n > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(msg, 0, n) .. '…') > room do n = n - 1 end
    msg = vim.fn.strcharpart(msg, 0, n) .. '…'
  end
  api.nvim_echo({ { msg } }, true, {})
end

---Open the choice over `items` (each with a `label`): the ask window (`view.rows`: the question
---on its own rows, `view.title` on the border), or `vim.ui.select` with `prompt` when
---`chat.ask_picker` is 'select' (`view.echo`: the prompt to the message line too, as wide as the
---screen, since pickers cut it). `done(choice)` is scheduled; nil when cancelled.
---@param items { label: string }[]
---@param prompt string
---@param done fun(choice: table|nil)
---@param view? { rows?: table[], title?: string, echo?: boolean }
function M.select(items, prompt, done, view)
  local opts = { prompt = prompt, format_item = function(it) return it.label end }
  local function cb(choice) vim.schedule(function() done(choice) end) end
  local chat_cfg = config.get().chat
  if type(chat_cfg) == 'table' and chat_cfg.ask_picker == 'select' then
    if view and view.echo then M.echo(prompt) end
    return vim.ui.select(items, opts, cb)
  end
  opts.rows, opts.title = view and view.rows, view and view.title
  require('agent-ide.ui.ask_float').select(items, opts, cb)
end

return M
