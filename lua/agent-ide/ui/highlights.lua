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
  -- idle: a filled mark in a mid grey (green reads as running); parked is the hollow mark in the
  -- dim comment colour, so the two differ in shape and brightness
  AgentIdeIdle = { fg = '#8b95a7', ctermfg = 247 },
  AgentIdeParked = M.dim, -- dimmed
  AgentIdeDone = { link = 'AgentIdeLevel3' }, -- the result waits to be read
  AgentIdeFailed = { fg = '#f7768e', ctermfg = 204 }, -- red; its status level stays 3 (review)
  AgentIdeMissing = M.dim,
  AgentIdeAge = M.dim,
  AgentIdeSection = { link = 'Directory' },
  AgentIdeAnswerMark = { link = 'AgentIdeLevel1' }, -- the ● before Claude's own text in a transcript (green)
  -- the removed and added lines of an Edit fold in a transcript (red, green)
  AgentIdeDiffAdd = { fg = '#9ece6a', ctermfg = 114 },
  AgentIdeDiffDel = { fg = '#f7768e', ctermfg = 204 },
  -- the full diff view: the `@@` hunk lines and the one-line notes (binary, submodule), dimmed
  AgentIdeDiffHunk = M.dim,
  AgentIdeDiffNote = M.dim,
  -- the command of a Bash fold, apart from its output
  AgentIdeCommand = { link = 'Special' },
  -- chat winbar: the model in italic (Normal's foreground), the permission mode as a badge; a
  -- mode other than the default one in a warning colour
  AgentIdeModel = function()
    local n = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
    return { fg = n.fg, ctermfg = n.ctermfg, italic = true }
  end,
  AgentIdeMode = M.dim,
  AgentIdeContext = M.dim, -- the context size (`~123k`) beside the model
  AgentIdeModeHot = { link = 'WarningMsg' },
  -- the prompt window's label (`↑ title · model`, ui/prompt_label.lua); a prompt that is not the
  -- transcript's in a warning colour
  AgentIdePromptLabel = M.dim,
  AgentIdePromptOther = { link = 'WarningMsg' },
}

-- the terminal's 16 colours when the colorscheme sets none (`g:terminal_color_<n>`)
local TERMINAL = { '#15161e', '#f7768e', '#9ece6a', '#e0af68', '#7aa2f7', '#bb9af7', '#7dcfff', '#a9b1d6',
  '#414868', '#f7768e', '#9ece6a', '#e0af68', '#7aa2f7', '#bb9af7', '#7dcfff', '#c0caf5' }

local function palette(n)
  if n < 16 then return vim.g['terminal_color_' .. n] or TERMINAL[n + 1] end
  return require('agent-ide.transcript.ansi').xterm(math.min(n, 255))
end

local ansi_groups = {} -- name -> true: the colour-code groups defined so far

local function define_ansi(name)
  local spec = require('agent-ide.transcript.ansi').spec(name, palette, M.dim().fg)
  vim.api.nvim_set_hl(0, name, vim.tbl_extend('force', spec, { default = true }))
end

---Define colour-code group `name` (`transcript/ansi.lua` names them by their style) the first
---time it is used; it is defined again after every colorscheme change, like the others.
---@param name string
function M.ansi(name)
  if ansi_groups[name] then return end
  ansi_groups[name] = true
  define_ansi(name)
end

local function apply()
  for name, def in pairs(GROUPS) do
    if type(def) == 'function' then def = def() end
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('force', def, { default = true }))
  end
  for name in pairs(ansi_groups) do define_ansi(name) end
end

---Define the groups, and again after every colorscheme change (`:hi clear` drops them).
function M.setup()
  apply()
  local group = vim.api.nvim_create_augroup('agent-ide.highlights', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = apply })
end

return M
