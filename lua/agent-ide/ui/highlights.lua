-- Highlight groups for the drawer. `default = true` lets colorschemes override.
local M = {}

local GROUPS = {
  AgentIdeProject = { bold = true },
  AgentIdeWaiting = { link = 'Constant' }, -- violet in most colorschemes
  AgentIdeBusy = { link = 'DiagnosticWarn' }, -- yellow
  AgentIdeIdle = { link = 'DiagnosticOk' }, -- green
  AgentIdeParked = { link = 'Comment' }, -- dimmed
  AgentIdeMissing = { link = 'Comment' },
  AgentIdeAge = { link = 'Comment' },
  AgentIdeSection = { link = 'Directory' },
}

function M.setup()
  for name, def in pairs(GROUPS) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('force', def, { default = true }))
  end
end

return M
