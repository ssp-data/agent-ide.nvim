-- Pure renderer of the commit graph: rows of `git_parse.graph` -> lines, one node per line and
-- highlight ranges. Git draws the graph; its ASCII is turned into box-drawing characters, one
-- character per cell, so every lane stays where git put it.
local layout = require('agent-ide.ui.layout')
local tree = require('agent-ide.ui.tree')

local M = {}

M.PALETTE = 6 -- AgentIdeGraph1..6

local GLYPH = { ['*'] = '●', ['|'] = '│', ['/'] = '╱', ['\\'] = '╲', ['_'] = '─', ['-'] = '─', ['.'] = '╮' }
local LANE = { ['|'] = true, ['*'] = true }

local REF_HL = { branch = 'AgentIdeGraphBranch', remote = 'AgentIdeGraphRemote', tag = 'AgentIdeGraphTag',
  head = 'AgentIdeGraphHead', other = 'AgentIdeGraphRemote' }

local AUTHOR_MAX = 16 -- cells of the author column at most

local function chars(s)
  local t = {}
  for i = 1, #s do t[i] = s:sub(i, i) end
  return t
end

---Glyph cells of every graph: `cells[i][c]` is the character of column c (1-based) of row i.
---Each character maps 1:1 (`*` ●, `|` │, `/` ╱, `\` ╲, `_` and `-` ─, `.` ╮). Where a branch
---starts or ends beside a lane that goes on, and nothing else is near, the fork `|\` becomes
---`├─╮` and the join `|/` becomes `├─╯`: the `\` (`/`) must have `|` on its left and space on its
---right, the column on its right must hold a lane in the row below (above) and none in the row
---above (below). Anything else keeps the 1:1 mapping.
---@param graphs string[]
---@return string[][]
function M.cells(graphs)
  local src = {}
  for i, g in ipairs(graphs) do src[i] = chars(g) end
  local out = {}
  for i, l in ipairs(src) do
    local p, n = src[i - 1] or {}, src[i + 1] or {}
    local row = {}
    for c, ch in ipairs(l) do row[c] = GLYPH[ch] or ch end
    for c, ch in ipairs(l) do
      if c % 2 == 0 and (ch == '\\' or ch == '/') and l[c - 1] == '|' and (l[c + 1] == nil or l[c + 1] == ' ') then
        local below, above = n[c + 1], p[c + 1]
        if ch == '\\' and LANE[below] and (above == nil or above == ' ') then
          row[c - 1], row[c], row[c + 1] = '├', '─', '╮'
        elseif ch == '/' and LANE[above] and (below == nil or below == ' ') then
          row[c - 1], row[c], row[c + 1] = '├', '─', '╯'
        end
      end
    end
    out[i] = row
  end
  return out
end

---Palette group of graph column `c` (1-based): a lane and the gap on its left share a colour.
local function lane_hl(c) return 'AgentIdeGraph' .. (math.floor(c / 2) % M.PALETTE + 1) end

-- Graph text of `cells` plus its highlight ranges (byte columns from `col`).
local function graph_text(cells, col, hl, line)
  local parts = {}
  for c, g in ipairs(cells) do
    parts[c] = g
    if g ~= ' ' then hl[#hl + 1] = { line = line, col_start = col, col_end = col + #g, group = lane_hl(c) } end
    col = col + #g
  end
  return table.concat(parts)
end

-- The lanes going on below a commit row (for its file lines): `│` where the row has a lane
-- (the commit's own lane only when it has parents).
local function lanes_below(graph, has_parents)
  local t = {}
  for c = 1, #graph do
    local ch = graph:sub(c, c)
    t[c] = (ch == '|' or (ch == '*' and has_parents)) and '│' or ' '
  end
  while #t > 0 and t[#t] == ' ' do t[#t] = nil end
  return t
end

local function stats(f) return require('agent-ide.ui.git_sections').stats(f) end
local function status_hl(s) return require('agent-ide.ui.git_sections').STATUS_HL[s] end

---Lines of the graph view.
---@param rows table[] from git_parse.graph
---@param opts { width?: integer, now: integer, open?: table<string, table[]|false>, more?: string|nil, state?: string, message?: string }
---  open: hash -> files of an expanded commit (false: loading); more: text of the last line when
---  the limit was hit; state: 'loading' | 'empty' | 'error' (message: its text) | nil (rows)
---@return { lines: string[], nodes: table[], hl: table[] }
function M.build(rows, opts)
  local lines, nodes, hl = {}, {}, {}
  local width, open = opts.width, opts.open or {}
  local function add(pieces, node, cells)
    local n = #lines + 1
    local col, parts = 0, {}
    for i, p in ipairs(pieces) do
      local text = p[1]
      if cells and i == 2 then text = graph_text(cells, col, hl, n) end
      parts[#parts + 1] = text
      if p[2] and text ~= '' then hl[#hl + 1] = { line = n, col_start = col, col_end = col + #text, group = p[2] } end
      col = col + #text
    end
    lines[n] = table.concat(parts)
    nodes[n] = node
  end
  if opts.state then
    local text = opts.state == 'loading' and 'loading…' or opts.state == 'empty' and 'no commits yet' or (opts.message or '')
    add({ { ' ' .. text, opts.state == 'error' and 'ErrorMsg' or 'AgentIdeAge' } }, { type = opts.state })
    return { lines = lines, nodes = nodes, hl = hl }
  end

  local graphs = {}
  local author_w = 0
  for i, r in ipairs(rows) do
    graphs[i] = r.graph
    if r.hash then author_w = math.max(author_w, math.min(AUTHOR_MAX, layout.width(r.author))) end
  end
  local cells = M.cells(graphs)

  for i, r in ipairs(rows) do
    local g = table.concat(cells[i]) -- the piece's width; its text is rebuilt with highlights
    if not r.hash then
      add({ { ' ' }, { g } }, { type = 'connector' }, cells[i])
    else
      local left = { { ' ' }, { g }, { r.short, 'AgentIdeGraphHash' }, { ' ' } }
      for _, ref in ipairs(r.refs) do
        left[#left + 1] = { ref.name, REF_HL[ref.kind], fit = 'last' }
        left[#left + 1] = { ' ' }
      end
      left[#left + 1] = { r.subject, nil, fit = true }
      local author = layout.truncate(r.author, author_w)
      local right = { { tree.ago(r.time, opts.now), 'AgentIdeAge' }, { '  ' },
        { author .. string.rep(' ', author_w - layout.width(author)), 'AgentIdeAge' } }
      local node = { type = 'commit', row = r }
      add(layout.row(left, right, width), node, cells[i])
      local files = open[r.hash]
      if files ~= nil then
        local lanes = lanes_below(r.graph, #r.parents > 0)
        local pad = string.rep(' ', math.max(0, #r.graph - #lanes) + 2)
        if files == false then
          add({ { ' ' }, { '' }, { pad .. 'loading…', 'AgentIdeAge' } }, { type = 'note', row = r }, lanes)
        elseif #files == 0 then
          add({ { ' ' }, { '' }, { pad .. 'no file changes', 'AgentIdeAge' } }, { type = 'note', row = r }, lanes)
        end
        for k, f in ipairs(files or {}) do
          local name = f.old_path and (f.old_path .. ' → ' .. f.path) or f.path
          local fl = { { ' ' }, { table.concat(lanes) }, { pad }, { f.status, status_hl(f.status) }, { ' ' },
            { (name:gsub('[\r\n]', ' ')), nil, fit = true } }
          add(layout.row(fl, stats(f), width), { type = 'file', row = r, file = f, list = files, index = k }, lanes)
        end
      end
    end
  end
  if opts.more then add({ { ' ' .. opts.more, 'AgentIdeAge' } }, { type = 'more' }) end
  return { lines = lines, nodes = nodes, hl = hl }
end

return M
