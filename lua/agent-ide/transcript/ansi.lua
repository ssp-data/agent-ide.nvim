-- Colour codes (SGR, `ESC [ … m`) in tool output, as a terminal would show them: the text without
-- the codes, plus spans naming a highlight group per style. A group name encodes its style
-- (`AgentIdeAnsi_B_F2`: bold, colour 2), so `spec` can define any group from its name alone.
-- Other escape sequences are not colours and stay in the text; the raw view keeps every byte.
local M = {}

M.PREFIX = 'AgentIdeAnsi'

local FLAGS = { b = 'B', d = 'D', i = 'I', u = 'U' }

-- `fg`/`bg` hold a part of the group name: `F<n>`/`G<n>` for palette colour n, `X<hex>`/`Y<hex>`
-- for a true colour.
local function name(st)
  local parts = {}
  for _, f in ipairs({ 'b', 'd', 'i', 'u' }) do
    if st[f] then parts[#parts + 1] = FLAGS[f] end
  end
  if st.fg then parts[#parts + 1] = st.fg end
  if st.bg then parts[#parts + 1] = st.bg end
  if #parts == 0 then return nil end
  return M.PREFIX .. '_' .. table.concat(parts, '_')
end

-- `38;5;n` and `38;2;r;g;b` (and 48 for the background) from `codes[i]` on: the name part and
-- how many codes it used.
local function extended(codes, i, palette, hex)
  if codes[i + 1] == 5 and codes[i + 2] then
    return palette .. codes[i + 2], 2
  elseif codes[i + 1] == 2 and codes[i + 4] then
    return hex .. ('%02x%02x%02x'):format(codes[i + 2] % 256, codes[i + 3] % 256, codes[i + 4] % 256), 4
  end
  return nil, #codes
end

local function apply(st, params)
  local codes = {}
  for p in (params .. ';'):gmatch('([^;:]*)[;:]') do codes[#codes + 1] = tonumber(p) or 0 end
  local i = 1
  while i <= #codes do
    local c = codes[i]
    if c == 0 then
      st.b, st.d, st.i, st.u, st.fg, st.bg = nil, nil, nil, nil, nil, nil
    elseif c == 1 then st.b = true
    elseif c == 2 then st.d = true
    elseif c == 3 then st.i = true
    elseif c == 4 then st.u = true
    elseif c == 22 then st.b, st.d = nil, nil
    elseif c == 23 then st.i = nil
    elseif c == 24 then st.u = nil
    elseif c >= 30 and c <= 37 then st.fg = 'F' .. (c - 30)
    elseif c >= 90 and c <= 97 then st.fg = 'F' .. (c - 82)
    elseif c == 39 then st.fg = nil
    elseif c >= 40 and c <= 47 then st.bg = 'G' .. (c - 40)
    elseif c >= 100 and c <= 107 then st.bg = 'G' .. (c - 92)
    elseif c == 49 then st.bg = nil
    elseif c == 38 or c == 48 then
      local part, used = extended(codes, i, c == 38 and 'F' or 'G', c == 38 and 'X' or 'Y')
      if c == 38 then st.fg = part or st.fg else st.bg = part or st.bg end
      i = i + used
    end
    i = i + 1
  end
end

---The text of `line` without its colour codes, the spans of styled text in it (0-based byte
---columns, end exclusive, with the group name), and the style at the end of the line, to pass
---to the next line (a colour set on one line lasts, as in a terminal).
---@param line string
---@param state table|nil
---@return string text, { [1]: integer, [2]: integer, [3]: string }[] spans, table state
function M.parse(line, state)
  state = state or {}
  local cur = name(state)
  if not cur and not line:find('\27[', 1, true) then return line, {}, state end
  local out, spans, n, pos = {}, {}, 0, 1
  while true do
    local s, e, params = line:find('\27%[([%d;:]*)m', pos)
    local seg = line:sub(pos, s and s - 1 or #line)
    if #seg > 0 then
      out[#out + 1] = seg
      if cur then
        local last = spans[#spans]
        if last and last[2] == n and last[3] == cur then
          last[2] = n + #seg
        else
          spans[#spans + 1] = { n, n + #seg, cur }
        end
      end
      n = n + #seg
    end
    if not s then break end
    apply(state, params)
    cur = name(state)
    pos = e + 1
  end
  return table.concat(out), spans, state
end

---Colour n (16 to 255) of the xterm 256-colour palette.
---@param n integer
---@return string
function M.xterm(n)
  if n >= 232 then
    local v = 8 + 10 * (n - 232)
    return ('#%02x%02x%02x'):format(v, v, v)
  end
  local i = n - 16
  local function level(v) return v == 0 and 0 or 55 + 40 * v end
  return ('#%02x%02x%02x'):format(level(math.floor(i / 36)), level(math.floor(i / 6) % 6), level(i % 6))
end

---Highlight attributes for group `group` (a name `parse` made). `palette(n)` gives the colour
---of palette entry n; `dim` the colour of dim text without a colour of its own.
---@param group string
---@param palette fun(n: integer): string
---@param dim string|nil
---@return table
function M.spec(group, palette, dim)
  local def = {}
  for part in group:sub(#M.PREFIX + 2):gmatch('[^_]+') do
    local k, v = part:sub(1, 1), part:sub(2)
    if k == 'B' then def.bold = true
    elseif k == 'I' then def.italic = true
    elseif k == 'U' then def.underline = true
    elseif k == 'D' then def.dim = true
    elseif k == 'F' then def.fg, def.ctermfg = palette(tonumber(v)), tonumber(v)
    elseif k == 'G' then def.bg, def.ctermbg = palette(tonumber(v)), tonumber(v)
    elseif k == 'X' then def.fg = '#' .. v
    elseif k == 'Y' then def.bg = '#' .. v
    end
  end
  if def.dim then
    def.dim = nil
    if not def.fg then def.fg = dim end
  end
  return def
end

return M
