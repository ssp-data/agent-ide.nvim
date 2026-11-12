-- Pure renderer of the full diff: a scope's file list and its patch blocks become the lines
-- of the buffer (a header per file, then its hunks, then a blank line), the highlight ranges,
-- one fold per file and a node per line (which file, which new-side line) for the keys.
-- A block that went through delta (`colored`) carries colour codes: they become spans of the
-- colour-code groups (transcript/ansi.lua) and the text loses them; a plain block gets the diff
-- mode's line colours and the changed text inside a paired `-` / `+` line marked.
local ansi = require('agent-ide.transcript.ansi')
local layout = require('agent-ide.ui.layout')

local M = {}

local INDENT = '  '
local TEXT_PRIORITY = 110 -- above the line colour (extmarks default to 100)

-- The new-side line a hunk starts at (`@@ -a,b +c,d @@`, the count defaults to 1).
local function hunk_start(line)
  local c = line:match('^@@ %-[%d,]+ %+(%d+)')
  return tonumber(c)
end

local function note_of(f, block)
  if f.submodule then return 'submodule: not shown' end
  if f.binary or (block and block.binary) then return 'binary file, not shown' end
  if block and block.note then return block.note end
  if block and block.mode_only then return 'mode changed' end
  if not block then return 'no changes shown' end
  return nil
end

-- A coloured line without its codes (SGR and the erase code delta writes before the reset).
local function strip(raw)
  if not raw:find('\27', 1, true) then return raw, false end
  return (raw:gsub('\27%[[%d;:]*[mK]', '')), true
end

---The highlight ranges of coloured line `raw` (a line through delta) at `line`: its spans as
---colour-code groups (transcript/ansi.lua) with the text priority, and the background delta
---sets for the rest of the screen line (the colour before its `ESC[0K`) as a line highlight.
---Decoded on demand by the view for the lines it draws. nil gives an empty list.
---@param raw string|nil
---@param line integer
---@return table[]
function M.decode(raw, line)
  if not raw then return {} end
  local out = {}
  local _, spans = ansi.parse((raw:gsub('\27%[%d*K', '')))
  for _, s in ipairs(spans) do
    if s[2] > s[1] then
      out[#out + 1] = { line = line, col_start = s[1], col_end = s[2], group = s[3], priority = TEXT_PRIORITY }
    end
  end
  local eol = raw:match('(\27%[[%d;:]*m)\27%[%d*K')
  if eol then
    local _, s = ansi.parse(eol .. 'x')
    if s[1] then out[#out + 1] = { line = line, col_start = 0, col_end = 0, group = s[1][3], line_hl = true } end
  end
  return out
end

local function continuation(byte) return byte ~= nil and byte >= 0x80 and byte < 0xC0 end

-- The part of `a` and `b` (the lines without their markers) that differs: the common prefix
-- and suffix lengths, on character boundaries; nil when the lines have nothing in common or
-- nothing different.
local function changed(a, b)
  local la, lb = #a, #b
  local p = 0
  while p < la and p < lb and a:byte(p + 1) == b:byte(p + 1) do p = p + 1 end
  while p > 0 and continuation(a:byte(p + 1)) do p = p - 1 end
  local s = 0
  while s < la - p and s < lb - p and a:byte(la - s) == b:byte(lb - s) do s = s + 1 end
  while s > 0 and continuation(a:byte(la - s + 1)) do s = s - 1 end
  if p + s == 0 or (p + s >= la and p + s >= lb) then return nil end
  return p, s
end

---@class agent_ide.FullDiffRender
---@field lines string[]
---@field hl { line: integer, col_start: integer, col_end: integer, group: string, hl_eol: boolean|nil, priority: integer|nil, line_hl: boolean|nil }[] `hl_eol`: the colour runs to the end of the screen line; `line_hl`: a whole-line (background) highlight
---@field folds { first: integer, last: integer, closed: boolean, path: string }[]
---@field files { path: string, line: integer }[]
---@field nodes table[] per line: `{ file = k, header = true }` or `{ file = k, new_line = n|nil }`
---@field raw table<integer, string> the coloured lines (delta) as they came, by line, for `decode`
---@field line_group table<integer, string> the group of a whole line (a `+` line, a `@@` line, a note), by line
---@field line_eol table<integer, true> the lines whose colour runs to the end of the screen line

---Build the buffer content. `files` is the scope's list (`git_cache` shape); `blocks` maps a
---path to `{ lines, binary?, mode_only?, note?, colored? }`; `opts.closed[path]` is the user's
---fold state (a path not in it starts closed when its block is longer than `opts.fold_over`).
---@param files table[]
---@param blocks table<string, table>
---@param opts { icons: { open: string, closed: string }, width: integer, closed?: table<string, boolean>, fold_over: integer }
---@return agent_ide.FullDiffRender
function M.build(files, blocks, opts)
  local git_sections = require('agent-ide.ui.git_sections')
  local t = { lines = {}, hl = {}, folds = {}, files = {}, nodes = {}, raw = {}, line_group = {}, line_eol = {} }
  local lines, hl, nodes = t.lines, t.hl, t.nodes
  local closed_by_user = opts.closed or {}
  local fold_over = opts.fold_over or 500

  -- A whole-line colour goes into `line_group` (and `line_eol`), not into `hl`: no table per
  -- line, the view's decoration provider reads them as they are.
  local line_group, line_eol = t.line_group, t.line_eol
  local function add(text, node, group, hl_eol)
    local n = #lines + 1
    lines[n] = text
    nodes[n] = node
    if group then line_group[n] = group end
    if hl_eol then line_eol[n] = true end
  end

  local function text_range(line, col_start, col_end, group)
    if col_end > col_start then
      hl[#hl + 1] = { line = line, col_start = col_start, col_end = col_end, group = group, priority = TEXT_PRIORITY }
    end
  end

  -- The changed text of a `-` line and the `+` line paired with it.
  local function mark_pair(del_line, add_line)
    local a, b = lines[del_line]:sub(2), lines[add_line]:sub(2)
    local p, s = changed(a, b)
    if not p then return end
    text_range(del_line, 1 + p, 1 + #a - s, 'AgentIdeFullDiffText')
    text_range(add_line, 1 + p, 1 + #b - s, 'AgentIdeFullDiffText')
  end

  local function hunks(block, k)
    local colored = block.colored
    local new_line
    local plain = { file = k } -- the node of every line of this file without a new-side number
    local dels, adds = {}, 0 -- the `-` lines of the current run, how many `+` lines followed
    for _, raw in ipairs(block.lines) do
      local text, keep = raw, false
      if colored then text, keep = strip(raw) end
      local c = text:byte(1)
      if c == 64 then -- @
        new_line = hunk_start(text)
        add(text, plain, 'AgentIdeDiffHunk')
      elseif c == 43 then -- +
        add(text, { file = k, new_line = new_line }, not colored and 'AgentIdeFullDiffAdd' or nil, true)
        if new_line then new_line = new_line + 1 end
        if not colored then
          adds = adds + 1
          if dels[adds] then mark_pair(dels[adds], #lines) end
        end
      elseif c == 45 then -- -
        add(text, plain, not colored and 'AgentIdeFullDiffDel' or nil, true)
        if adds > 0 then dels, adds = {}, 0 end
        dels[#dels + 1] = #lines
      elseif c == 92 then -- \
        add(text, plain, 'AgentIdeDiffHunk')
      else
        add(text, { file = k, new_line = new_line })
        if new_line then new_line = new_line + 1 end
      end
      if c ~= 43 and c ~= 45 and #dels > 0 then dels, adds = {}, 0 end
      if keep then t.raw[#lines] = raw end
    end
  end

  local function file_block(f, block, k)
    local closed = closed_by_user[f.path]
    if closed == nil then closed = block ~= nil and block.lines ~= nil and #block.lines > fold_over end
    local name = f.old_path and (f.old_path .. ' → ' .. f.path) or f.path
    local icon = closed and opts.icons.closed or opts.icons.open
    local left = { { icon .. ' ' }, { f.status, git_sections.STATUS_HL[f.status] }, { ' ' },
      { (name:gsub('[\r\n]', ' ')), nil, fit = true } }
    local pieces = layout.row(left, git_sections.stats(f), opts.width)
    local text, col = '', 0
    local first = #lines + 1
    local ranges = {}
    for _, p in ipairs(pieces) do
      if p[2] then ranges[#ranges + 1] = { line = first, col_start = col, col_end = col + #p[1], group = p[2] } end
      text = text .. p[1]
      col = col + #p[1]
    end
    add(text, { file = k, header = true })
    vim.list_extend(hl, ranges)
    t.files[#t.files + 1] = { path = f.path, line = first }
    local note = note_of(f, block)
    if note then
      add(INDENT .. note, { file = k }, 'AgentIdeDiffNote')
    else
      hunks(block, k)
    end
    add('', { file = k })
    t.folds[#t.folds + 1] = { first = first, last = #lines, closed = closed, path = f.path }
  end

  local seen = {}
  for k, f in ipairs(files) do
    seen[f.path] = true
    file_block(f, blocks[f.path], k)
  end
  -- a block the list does not know (it changed in between): shown anyway
  local extra = {}
  for path, block in pairs(blocks) do
    if not seen[path] then extra[#extra + 1] = path end
  end
  table.sort(extra)
  for _, path in ipairs(extra) do
    local block = blocks[path]
    file_block({ status = 'M', path = path, old_path = block.old_path, binary = block.binary or false, submodule = false },
      block, #t.files + 1)
  end
  return t
end

---The highlight ranges of a render by line (`by_line[line]` is a list in the order given):
---what a decoration provider draws for the visible lines only, so a long patch costs nothing
---to colour until it is looked at.
---@param hl table[] `agent_ide.FullDiffRender.hl`
---@return table<integer, table[]>
function M.index(hl)
  local by_line = {}
  for _, h in ipairs(hl) do
    local list = by_line[h.line]
    if not list then
      list = {}
      by_line[h.line] = list
    end
    list[#list + 1] = h
  end
  return by_line
end

return M
