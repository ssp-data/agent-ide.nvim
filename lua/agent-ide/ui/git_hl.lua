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
  -- commit graph: one colour per lane column (rotating), ref badges, the hash dim
  AgentIdeGraph1 = { fg = '#7aa2f7', ctermfg = 111 }, -- blue
  AgentIdeGraph2 = { fg = '#bb9af7', ctermfg = 141 }, -- violet
  AgentIdeGraph3 = { fg = '#7dcfff', ctermfg = 117 }, -- cyan
  AgentIdeGraph4 = { fg = '#9ece6a', ctermfg = 114 }, -- green
  AgentIdeGraph5 = { fg = '#e0af68', ctermfg = 179 }, -- yellow
  AgentIdeGraph6 = { fg = '#ff9e64', ctermfg = 215 }, -- orange
  AgentIdeGraphBranch = { fg = '#9ece6a', ctermfg = 114, bold = true },
  AgentIdeGraphRemote = require('agent-ide.ui.highlights').dim,
  AgentIdeGraphTag = { fg = '#e0af68', ctermfg = 179 },
  AgentIdeGraphHead = { bold = true },
  AgentIdeGraphHash = require('agent-ide.ui.highlights').dim,
  -- the full diff without delta: whole lines as Neovim's diff mode colours them, the changed
  -- text inside a modified line like its DiffText
  AgentIdeFullDiffAdd = { link = 'DiffAdd' },
  AgentIdeFullDiffDel = { link = 'DiffDelete' },
  AgentIdeFullDiffText = { link = 'DiffText' },
  AgentIdeFullDiffFile = { bold = true }, -- the file under the cursor, first in the winbar
  -- review comments under a line of the full diff: the bar, the text, the kind in its colour
  -- (a kind of your own: bold)
  AgentIdeReviewBar = require('agent-ide.ui.highlights').dim,
  AgentIdeReviewText = {},
  AgentIdeReviewKind = { bold = true },
  AgentIdeReviewNote = { fg = '#7aa2f7', ctermfg = 111, bold = true }, -- blue
  AgentIdeReviewIssue = { fg = '#e0af68', ctermfg = 179, bold = true }, -- yellow
  AgentIdeReviewBug = { fg = '#f7768e', ctermfg = 204, bold = true }, -- red
  AgentIdeReviewDesign = { fg = '#bb9af7', ctermfg = 141, bold = true }, -- violet
  AgentIdeReviewSuggestion = { fg = '#9ece6a', ctermfg = 114, bold = true }, -- green
  AgentIdeReviewQuestion = { fg = '#7dcfff', ctermfg = 117, bold = true }, -- cyan
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
