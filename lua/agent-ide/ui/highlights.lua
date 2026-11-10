-- Highlight groups for the drawer and the chat view. `default = true` lets colorschemes override.
local M = {}

local GROUPS = {
  AgentIdeProject = { bold = true },
  AgentIdeWaiting = { fg = '#a277ff', ctermfg = 141 }, -- violet
  AgentIdeBusy = { link = 'DiagnosticWarn' }, -- yellow
  AgentIdeIdle = { link = 'DiagnosticOk' }, -- green
  AgentIdeParked = { link = 'Comment' }, -- dimmed
  AgentIdeDone = { fg = '#ff9e64', ctermfg = 215 }, -- orange: the result waits to be read
  AgentIdeFailed = { fg = '#ff9e64', ctermfg = 215 },
  AgentIdeMissing = { link = 'Comment' },
  AgentIdeAge = { link = 'Comment' },
  AgentIdeSection = { link = 'Directory' },
}

local function apply()
  for name, def in pairs(GROUPS) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('force', def, { default = true }))
  end
end

---Define the groups, and again after every colorscheme change (`:hi clear` drops them).
function M.setup()
  apply()
  local group = vim.api.nvim_create_augroup('agent-ide.highlights', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = apply })
end

return M
