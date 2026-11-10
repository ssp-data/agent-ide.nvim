-- Highlight groups of the git rows and the diff view. `default = true` lets colorschemes override.
local M = {}

local GROUPS = {
  AgentIdeBranch = { link = 'Comment' },
  AgentIdeGitHash = { link = 'Identifier' },
  AgentIdeGitAdd = { link = 'Added' },
  AgentIdeGitDel = { link = 'Removed' },
  AgentIdeGitAdded = { link = 'Added' },
  AgentIdeGitModified = { link = 'Changed' },
  AgentIdeGitDeleted = { link = 'Removed' },
  AgentIdeGitRenamed = { link = 'Changed' },
  AgentIdeGitUntracked = { link = 'Comment' },
}

local function apply()
  for name, def in pairs(GROUPS) do
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
