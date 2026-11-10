-- The two sides of a diff as lines, and their winbar labels: the base blob is read the way Neovim read the user's buffer
-- (encoding, BOM, CRLF), so only real changes show as differences.
local api = vim.api
local scratch = require('agent-ide.ui.diff_buf')

local M = {}

local BOM = '\239\187\191'

-- The base blob converted the way Neovim read the user's buffer `real` (encoding, BOM).
local function as_read(content, real)
  if not content or not real then return content end
  local fenc = vim.bo[real].fileencoding
  if fenc ~= '' and fenc ~= 'utf-8' and not content:find('\0', 1, true) then content = vim.iconv(content, fenc, 'utf-8') or content end
  if vim.bo[real].bomb and content:sub(1, 3) == BOM then content = content:sub(4) end
  return content
end

local function strip_cr(lines)
  if type(lines) ~= 'table' then return lines end
  for i, l in ipairs(lines) do lines[i] = (l:gsub('\r$', '')) end
  return lines
end

local function all_cr(lines)
  if type(lines) ~= 'table' then return true end
  for _, l in ipairs(lines) do
    if l:sub(-1) ~= '\r' then return false end
  end
  return true
end

local function has_eol(content) return content:sub(-1) == '\n' end

---Left and right lines plus a winbar note, from the raw sides: `left` a blob or nil, `right`
---the user's buffer (number), a blob, nil or true (binary).
function M.sides(left, right)
  local real = type(right) == 'number' and right or nil
  left = as_read(left, real)
  local l, r = scratch.lines_of(left), type(right) == 'string' and scratch.lines_of(right) or right
  if real and vim.bo[real].fileformat == 'dos' then l = strip_cr(l) end
  if not real and type(right) == 'string' and all_cr(l) and all_cr(r) then
    l, r = strip_cr(l), strip_cr(r) -- CRLF on both sides of a commit: not a difference
  end
  local note
  if left and left ~= '' then
    local right_eol
    if real then
      local n = api.nvim_buf_line_count(real)
      if n > 1 or (api.nvim_buf_get_lines(real, 0, 1, false)[1] or '') ~= '' then right_eol = vim.bo[real].eol end
    elseif type(right) == 'string' and right ~= '' then
      right_eol = has_eol(right)
    end
    if right_eol ~= nil and right_eol ~= has_eol(left) then note = ' · final newline differs' end
  end
  return l, r, note
end


local function esc(s) return (tostring(s):gsub('%%', '%%%%')) end

---Labels of both sides of view `d`: { left, right }.
function M.labels(d)
  local f = d.file
  if d.mode == 'commit' then
    local c = d.commit
    return { c.short .. '^', c.short .. ' ' .. c.subject }
  end
  local left
  if d.mode == 'head' then
    left = 'HEAD (uncommitted)'
  else
    local b = d.base or {}
    left = 'base ' .. (b.label or '?')
    if b.rev then left = left .. ' (' .. b.rev:sub(1, 7) .. ')' end
  end
  local right = 'working tree'
  if f.status == 'D' then right = right .. ' (deleted)' end
  return { left, right }
end

---Winbar texts (statusline-escaped) of view `d`: { left, right }, `note` appended on the right.
function M.winbars(d, note)
  local l = M.labels(d)
  local pos = d.index and ('file %d/%d'):format(d.index, #d.list) or ('file ?/' .. #d.list)
  local name = d.file.old_path and (d.file.old_path .. ' → ' .. d.file.path) or d.file.path
  return { esc(l[1] .. ' · ' .. name .. ' · ' .. pos), esc(l[2] .. ' · ' .. pos .. (note or '')) }
end

return M
