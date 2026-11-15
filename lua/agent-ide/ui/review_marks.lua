-- Review comments in the full diff: where a line of the render anchors a comment, and the
-- comments as virtual lines under their line. Placing walks the lines of the commented files
-- only (their fold ranges), never the whole patch. A comment whose line is no longer in the
-- diff sits under its file's header with a note; a comment on a file the render does not
-- show is not placed (it stays in the review).
local api = vim.api

local M = {}

local ns = api.nvim_create_namespace('agent-ide.review')

local BUILT_IN = { NOTE = 'Note', ISSUE = 'Issue', BUG = 'Bug', DESIGN = 'Design', SUGGESTION = 'Suggestion', QUESTION = 'Question' }

---The highlight group of a kind: its own for the built-in ones, `AgentIdeReviewKind` otherwise.
---@param kind string
---@return string
function M.group_of(kind)
  local name = BUILT_IN[kind]
  return name and ('AgentIdeReview' .. name) or 'AgentIdeReviewKind'
end

---What a comment on buffer line `row` of render `t` anchors to: a `+` or context line by its
---new-side number, a `-` line by its old-side number (with the line's text, its first
---character dropped), anything else of a file (header, `@@`, note, blank) the file itself.
---@param t table agent_ide.FullDiffRender
---@param row integer
---@return { path: string, side?: 'new'|'old', line?: integer, code?: string }|nil
function M.anchor(t, row)
  local node = t.nodes[row]
  if not node then return nil end
  local f = t.files[node.file]
  if not f then return nil end
  if node.new_line then
    return { path = f.path, side = 'new', line = node.new_line, code = t.lines[row]:sub(2) }
  elseif node.old_line then
    return { path = f.path, side = 'old', line = node.old_line, code = t.lines[row]:sub(2) }
  end
  return { path = f.path }
end

---The buffer lines the comments go under: `line -> { { comment, lost }, … }` in the order
---given. Only the fold ranges of commented paths are walked.
---@param t table agent_ide.FullDiffRender
---@param comments table[]
---@return table<integer, { comment: table, lost: boolean }[]>
function M.lines(t, comments)
  local by_path = {}
  for _, c in ipairs(comments) do
    local list = by_path[c.path]
    if not list then
      list = {}
      by_path[c.path] = list
    end
    list[#list + 1] = c
  end
  local out = {}
  local function put(line, c, lost)
    local list = out[line]
    if not list then
      list = {}
      out[line] = list
    end
    list[#list + 1] = { comment = c, lost = lost }
  end
  for _, fold in ipairs(t.folds) do
    local list = by_path[fold.path]
    if list then
      local new, old
      for _, c in ipairs(list) do
        if c.line and not new then
          -- the line numbers of this file, once, from its hunks
          new, old = {}, {}
          for row = fold.first, fold.last do
            local n = t.nodes[row]
            if n.new_line and not new[n.new_line] then new[n.new_line] = row end
            if n.old_line and not old[n.old_line] then old[n.old_line] = row end
          end
        end
        local row = c.line and (c.side == 'old' and old[c.line] or new[c.line]) or nil
        if row then
          put(row, c, false)
        else
          put(fold.first, c, c.line ~= nil)
        end
      end
    end
  end
  return out
end

local BAR, CONT = '  ┃ ', '  ┃      '

local function virt_lines(entry)
  local c = entry.comment
  local text = vim.split(c.text or '', '\n', { plain = true })
  local first = { { BAR, 'AgentIdeReviewBar' }, { c.kind .. '  ', M.group_of(c.kind) } }
  if entry.lost then first[#first + 1] = { ('(line %d not in this diff)  '):format(c.line), 'AgentIdeDiffNote' } end
  first[#first + 1] = { text[1] or '', 'AgentIdeReviewText' }
  local out = { first }
  for i = 2, #text do out[#out + 1] = { { CONT, 'AgentIdeReviewBar' }, { text[i], 'AgentIdeReviewText' } } end
  return out
end

---Show `comments` under their lines of `buf` (rendered as `t`): the namespace is cleared, one
---`virt_lines` extmark per commented line. Returns what `M.lines` gave.
---@param buf integer
---@param t table agent_ide.FullDiffRender
---@param comments table[]
---@return table<integer, { comment: table, lost: boolean }[]>
function M.place(buf, t, comments)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local map = M.lines(t, comments)
  for line, list in pairs(map) do
    local v = {}
    for _, e in ipairs(list) do vim.list_extend(v, virt_lines(e)) end
    api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { virt_lines = v })
  end
  return map
end

return M
