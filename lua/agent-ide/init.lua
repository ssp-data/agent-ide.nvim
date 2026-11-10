-- Agent-IDE.nvim entry point.
local config = require('agent-ide.config')
local M = {}

local mapped_key -- the toggle key this module mapped last, if any

---@param opts? table
function M.setup(opts)
  local cfg = config.setup(opts)
  require('agent-ide.ui.highlights').setup()
  if mapped_key then
    pcall(vim.keymap.del, 'n', mapped_key)
    mapped_key = nil
  end
  local key = cfg.keys and cfg.keys.toggle
  if key then
    vim.keymap.set('n', key, M.toggle, { desc = 'Agent-IDE: toggle Agents tab' })
    mapped_key = key
  end
end

function M.toggle()
  require('agent-ide.ui.highlights').setup()
  require('agent-ide.ui.drawer').toggle()
end

return M
