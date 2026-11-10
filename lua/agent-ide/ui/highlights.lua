-- Highlight groups for the drawer and the chat view. `default = true` lets colorschemes override.
local M = {}

---A dim style: the foreground of `Comment` as it resolves now, never italic or bold (many
---colourschemes make Comment italic; dimmed things here are dimmed only).
---@return table
function M.dim()
  local c = vim.api.nvim_get_hl(0, { name = 'Comment', link = false })
  return { fg = c.fg, ctermfg = c.ctermfg, italic = false, bold = false }
end

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
  AgentIdeParked = M.dim, -- dimmed
  AgentIdeDone = { link = 'AgentIdeLevel3' }, -- the result waits to be read
  AgentIdeFailed = { fg = '#f7768e', ctermfg = 204 }, -- red; its status level stays 3 (review)
  AgentIdeMissing = M.dim,
  AgentIdeAge = M.dim,
  AgentIdeSection = { link = 'Directory' },
  AgentIdeAnswerMark = { link = 'AgentIdeIdle' }, -- the ● before Claude's own text in a transcript
  -- chat winbar: the model in italic (Normal's foreground), the permission mode as a badge; a
  -- mode other than the default one in a warning colour
  AgentIdeModel = function()
    local n = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
    return { fg = n.fg, ctermfg = n.ctermfg, italic = true }
  end,
  AgentIdeMode = M.dim,
  AgentIdeModeHot = { link = 'WarningMsg' },
}

local function apply()
  for name, def in pairs(GROUPS) do
    if type(def) == 'function' then def = def() end
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
