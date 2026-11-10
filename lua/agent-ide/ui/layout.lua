-- Pure row layout of the drawer: display widths, truncation that never splits a character, and
-- rows of a left and a right part with the right part aligned to the window's right edge.
--
-- A piece is `{ text, hl_group|nil, fit = true|'drop'|nil }`. `fit` pieces of the left part
-- (a title, a branch) give up room, the last one first, so the right part stays whole; a
-- `fit = 'drop'` piece (a description) goes away rather than shrink below MIN_DROP cells; a
-- `fit = 'last'` piece (a marker) shrinks only after all the others, and goes away too.
local M = {}

local GAP = 2 -- cells between the left and the right part
local MIN_DROP = 6
local ELLIPSIS = '…'

local strdisplaywidth = vim.fn.strdisplaywidth

---Display width of `s` (cells); plain ASCII without calling into Vimscript.
---@param s string
---@return integer
function M.width(s)
  if not s:find('[\128-\255]') then return #s end
  return strdisplaywidth(s)
end

---`s` cut to at most `width` cells with `…` at the end; whole characters only (a wide
---character that does not fit is left out; combining marks stay with their character).
---@param s string
---@param width integer
---@return string
function M.truncate(s, width)
  if width <= 0 then return '' end
  if M.width(s) <= width then return s end
  local room = width - M.width(ELLIPSIS)
  if room <= 0 then return width >= M.width(ELLIPSIS) and ELLIPSIS or '' end
  if not s:find('[\128-\255]') then return s:sub(1, room) .. ELLIPSIS end
  local out, used = {}, 0
  for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    local w = M.width(ch)
    if used + w > room then break end
    out[#out + 1] = ch
    used = used + w
  end
  return table.concat(out) .. ELLIPSIS
end

local function sum(pieces)
  local n = 0
  for _, p in ipairs(pieces) do n = n + M.width(p[1]) end
  return n
end

-- Shrink the `fit` pieces of `left` (a copy) by `excess` cells, the last one first; pieces
-- with `fit = 'last'` only once the others are as short as they get.
local function shrink(left, excess)
  local out = {}
  for i, p in ipairs(left) do out[i] = p end
  for pass = 1, 2 do
    for i = #out, 1, -1 do
      if excess <= 0 then return out end
      local p = out[i]
      if p.fit and (p.fit == 'last') == (pass == 2) then
        local w = M.width(p[1])
        local want = math.max(1, w - excess)
        if p.fit ~= true and want < MIN_DROP then
          out[i] = { '', p[2] }
          excess = excess - w
        elseif want < w then
          local t = M.truncate(p[1], want)
          out[i] = { t, p[2] }
          excess = excess - (w - M.width(t))
        end
      end
    end
  end
  return out
end

---Pieces of one row: `left`, then padding, then `right` ending at cell `width`. Without a
---width the right part follows after two spaces. A row without a right part only shrinks
---when it is wider than `width`.
---@param left table[] pieces
---@param right table[]|nil pieces
---@param width integer|nil
---@return table[] pieces
function M.row(left, right, width)
  right = right or {}
  local has_right = #right > 0
  if not width then
    if not has_right then return left end
    local out = vim.list_extend({}, left)
    out[#out + 1] = { string.rep(' ', GAP) }
    return vim.list_extend(out, right)
  end
  local lw, rw = sum(left), sum(right)
  local need = has_right and (lw + GAP + rw) or lw
  if need > width then
    left = shrink(left, need - width)
    lw = sum(left)
  end
  if not has_right then return left end
  local out = vim.list_extend({}, left)
  out[#out + 1] = { string.rep(' ', math.max(1, width - lw - rw)) }
  return vim.list_extend(out, right)
end

return M
