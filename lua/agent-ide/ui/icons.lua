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

-- The two sets share the fold arrows, the worktree mark and the six state marks (plain
-- characters whose colour tells them apart). Only these differ: the Prompts pencil and the one
-- git glyph of the Changes and Commits rows; the plain set has no icon there.
local SHARED = {
  open = '▾', closed = '▸',
  worktree = '⎇',
  -- session states: waiting and idle are both a filled dot, told apart by colour
  waiting = '●', busy = '◐', idle = '●', parked = '○', done = '✓', failed = '✗',
}

M.nerd = vim.tbl_extend('force', SHARED, {
  prompts = g(0xF0CB6), -- nf-md-pencil_outline
  changes = g(0xF47F), -- nf-oct-git_compare (the same glyph for both git rows)
  commits = g(0xF47F), -- nf-oct-git_compare
})

M.plain = vim.tbl_extend('force', SHARED, { prompts = '', changes = '', commits = '' })

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
