-- Icon sets of the drawer: `nerd` (Nerd Fonts v3 glyphs, the default) and `plain` (characters of
-- ordinary monospace fonts). `config.icons_style` picks the base set; `config.icons` overrides
-- single entries. An empty icon is not drawn (and takes no space).
local M = {}

-- UTF-8 of one code point (no `\u{}` escapes: they need LuaJIT or Lua 5.3).
local function g(cp)
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

M.nerd = {
  open = g(0xF47C), -- nf-oct-chevron_down
  closed = g(0xF460), -- nf-oct-chevron_right
  agents = g(0xF06A9), -- nf-md-robot (drawer header)
  prompts = g(0xF06A9), -- nf-md-robot (the Prompts node, as in the header)
  project = g(0xF401), -- nf-oct-repo
  new = g(0xF0415), -- nf-md-plus
  -- sections
  sessions = g(0xF0822), -- nf-md-forum_outline
  saved_prompts = g(0xF0818), -- nf-md-content_save_outline
  changes = g(0xF440), -- nf-oct-diff
  commits = g(0xF417), -- nf-oct-git_commit
  skills = g(0xF140B), -- nf-md-lightning_bolt
  library = g(0xF125F), -- nf-md-bookshelf
  group = g(0xF0256), -- nf-md-folder_outline
  worktree = g(0xF418), -- nf-oct-git_branch
  -- session states
  waiting = g(0xF009E), -- nf-md-bell_ring
  busy = g(0xF1396), -- nf-md-circle_half_full
  idle = g(0xF0766), -- nf-md-circle_outline
  parked = g(0xF04B2), -- nf-md-sleep
  done = g(0xF05E0), -- nf-md-check_circle
  failed = g(0xF0159), -- nf-md-close_circle
  -- prompt entries (by kind)
  command = g(0xF0FDF), -- nf-md-slash_forward
  skill = g(0xF0A66), -- nf-md-puzzle_outline
  template = g(0xF09EE), -- nf-md-file_document_outline
  saved = g(0xF00C3), -- nf-md-bookmark_outline
}

M.plain = {
  open = '▾', closed = '▸', agents = '', prompts = '✎', project = '', new = '+',
  sessions = '', saved_prompts = '', changes = '', commits = '', skills = '', library = '', group = '',
  worktree = '⎇',
  waiting = '◐', busy = '●', idle = '○', parked = '·', done = '✔', failed = '✖',
  command = '', skill = '', template = '', saved = '',
}

---The icon set of `style` ('nerd' | 'plain'; anything else: nerd) with `overrides` on top.
---@param style string|nil
---@param overrides table|nil
---@return table
function M.resolve(style, overrides)
  local base = style == 'plain' and M.plain or M.nerd
  return vim.tbl_extend('force', base, overrides or {})
end

---`icon` and a space, or nothing for an empty or missing icon.
---@param icon string|nil
---@return string
function M.prefix(icon)
  if icon == nil or icon == '' then return '' end
  return icon .. ' '
end

return M
