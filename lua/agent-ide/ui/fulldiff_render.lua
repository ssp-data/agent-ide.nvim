-- Pure renderer of the full diff: a scope's file list and its patch blocks become the lines
-- of the buffer (a header per file, then its hunks, then a blank line), the highlight ranges,
-- one fold per file and a node per line (which file, which new-side line) for the keys.
local layout = require('agent-ide.ui.layout')

local M = {}

local INDENT = '  '

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

---@class agent_ide.FullDiffRender
---@field lines string[]
---@field hl { line: integer, col_start: integer, col_end: integer, group: string, end_line: integer|nil }[] `end_line`: the range ends on that later line (at `col_end`)
---@field folds { first: integer, last: integer, closed: boolean, path: string }[]
---@field files { path: string, line: integer }[]
---@field nodes table[] per line: `{ file = k, header = true }` or `{ file = k, new_line = n|nil }`

---Build the buffer content. `files` is the scope's list (`git_cache` shape); `blocks` maps a
---path to `{ lines, binary?, mode_only?, note? }`; `opts.closed[path]` is the user's fold state
---(a path not in it starts closed when its block is longer than `opts.fold_over` lines).
---@param files table[]
---@param blocks table<string, table>
---@param opts { icons: { open: string, closed: string }, width: integer, closed?: table<string, boolean>, fold_over: integer }
---@return agent_ide.FullDiffRender
function M.build(files, blocks, opts)
  local git_sections = require('agent-ide.ui.git_sections')
  local t = { lines = {}, hl = {}, folds = {}, files = {}, nodes = {} }
  local lines, hl, nodes = t.lines, t.hl, t.nodes
  local closed_by_user = opts.closed or {}
  local fold_over = opts.fold_over or 500

  -- A whole-line group right after a range of the same group extends that range (`end_line`),
  -- so a run of added lines is one extmark.
  local function add(text, k, node, group)
    lines[#lines + 1] = text
    nodes[#nodes + 1] = node
    if not group then return end
    local last = hl[#hl]
    if last and last.group == group and last.col_start == 0 and (last.end_line or last.line) == #lines - 1 then
      last.end_line, last.col_end = #lines, #text
    else
      hl[#hl + 1] = { line = #lines, col_start = 0, col_end = #text, group = group }
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
    add(text, k, { file = k, header = true })
    vim.list_extend(hl, ranges)
    t.files[#t.files + 1] = { path = f.path, line = first }
    local note = note_of(f, block)
    if note then
      add(INDENT .. note, k, { file = k }, 'AgentIdeDiffNote')
    else
      local new_line
      for _, l in ipairs(block.lines) do
        local c = l:sub(1, 1)
        if c == '@' then
          new_line = hunk_start(l)
          add(l, k, { file = k }, 'AgentIdeDiffHunk')
        elseif c == '+' then
          add(l, k, { file = k, new_line = new_line }, 'AgentIdeDiffAdd')
          if new_line then new_line = new_line + 1 end
        elseif c == '-' then
          add(l, k, { file = k }, 'AgentIdeDiffDel')
        elseif c == '\\' then
          add(l, k, { file = k }, 'AgentIdeDiffHunk')
        else
          add(l, k, { file = k, new_line = new_line })
          if new_line then new_line = new_line + 1 end
        end
      end
    end
    add('', k, { file = k })
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

return M
