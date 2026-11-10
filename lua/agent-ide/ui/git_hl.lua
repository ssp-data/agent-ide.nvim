-- Highlight groups of the git rows and the diff view. `default = true` lets colorschemes override.
local M = {}

local GROUPS = {
  AgentIdeBranch = require('agent-ide.ui.highlights').dim,
  AgentIdeGitHash = { link = 'Identifier' },
  -- drawer rows: added green, deleted red, modified yellow (the drawer's state colours)
  AgentIdeGitAdd = { fg = '#9ece6a', ctermfg = 114 },
  AgentIdeGitDel = { fg = '#f7768e', ctermfg = 204 },
  AgentIdeGitAdded = { link = 'AgentIdeGitAdd' },
  AgentIdeGitModified = { fg = '#e0af68', ctermfg = 179 },
  AgentIdeGitDeleted = { link = 'AgentIdeGitDel' },
  AgentIdeGitRenamed = { link = 'AgentIdeGitModified' },
  AgentIdeGitUntracked = require('agent-ide.ui.highlights').dim,
}

local function apply()
  for name, def in pairs(GROUPS) do
    if type(def) == 'function' then def = def() end
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('force', def, { default = true }))
  end
end

local done = false

---Define the groups, and again after every colorscheme change. Idempotent.
function M.setup()
  apply()
  if done then return end
  done = true
  vim.api.nvim_create_autocmd('ColorScheme', { group = vim.api.nvim_create_augroup('agent-ide.git_hl', { clear = true }),
    callback = apply })
end

return M
