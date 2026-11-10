-- Highlight groups for the drawer and the chat view. `default = true` lets colorschemes override.
local M = {}

local GROUPS = {
  AgentIdeProject = { bold = true },
  -- overall status levels (statusline, status file); the drawer's state groups link to them
  AgentIdeLevel1 = { fg = '#9ece6a', ctermfg = 114 }, -- green
  AgentIdeLevel2 = { fg = '#e0af68', ctermfg = 179 }, -- yellow
  AgentIdeLevel3 = { fg = '#ff9e64', ctermfg = 215 }, -- orange
  AgentIdeLevel4 = { fg = '#a277ff', ctermfg = 141, bold = true }, -- violet, bold: input required
  AgentIdeWaiting = { link = 'AgentIdeLevel4' },
  AgentIdeBusy = { link = 'AgentIdeLevel2' },
  AgentIdeIdle = { link = 'AgentIdeLevel1' },
  AgentIdeParked = { link = 'Comment' }, -- dimmed
  AgentIdeDone = { link = 'AgentIdeLevel3' }, -- the result waits to be read
  AgentIdeFailed = { fg = '#f7768e', ctermfg = 204 }, -- red; its status level stays 3 (review)
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
