-- The text a review becomes (pure): what lands in the prompt buffer on `gs`, or is sent at once
-- with one comment. An intro, the kinds used with their descriptions, then a group per scope
-- (the uncommitted changes, a commit, …) in the order the comments were made, each comment
-- numbered through with its reference (path, line and side, or the file) and the line's text.
local M = {}

M.DEFAULT_INTRO = 'I reviewed your changes and have the following comments. Please address them.'

---The heading of a group: where its comments were made.
---@param scope { kind: string, hash?: string, short?: string, subject?: string, base?: string }
---@return string
function M.heading(scope)
  local k = scope.kind
  if k == 'commit' then
    return ('commit %s (%s)'):format(scope.short or (scope.hash or '?'):sub(1, 7), scope.subject or '')
  elseif k == 'branch' then
    return ('branch vs %s (uncommitted included)'):format(scope.base or 'main')
  elseif k == 'commits' then
    if not scope.base or scope.base == 'HEAD' then return 'recent commits' end
    return ('commits on branch (%s..HEAD)'):format(scope.base)
  end
  return 'uncommitted changes (working tree against HEAD' .. (scope.hash and (' ' .. scope.hash) or '') .. ')'
end

---Where a comment points: `` `path:line` ``, `` `path:line (old line)` `` or `` `path` (file) ``.
---@param c { path: string, side?: string, line?: integer }
---@return string
function M.reference(c)
  if not c.line then return '`' .. c.path .. '` (file)' end
  return ('`%s:%d%s`'):format(c.path, c.line, c.side == 'old' and ' (old line)' or '')
end

-- A key that tells the groups apart (one commit from another).
local function scope_key(s) return s.kind .. (s.kind == 'commit' and ('@' .. (s.hash or s.short or '')) or '') end

---The lines of the review text for `comments` (in the order given, numbered in that order).
---@param comments table[]
---@param opts { project: string, root: string, cwd?: string, kinds: { [1]: string, [2]: string }[], intro: string }
---@return string[]
function M.build(comments, opts)
  local out = { opts.intro }
  if opts.cwd and opts.cwd ~= opts.root then out[#out + 1] = 'Repository: ' .. opts.root end
  out[#out + 1] = ''
  -- the kinds used, in the configured order, unknown ones after them as they come
  local used, seen = {}, {}
  for _, c in ipairs(comments) do
    if not seen[c.kind] then
      seen[c.kind] = true
      used[#used + 1] = c.kind
    end
  end
  local described, parts = {}, {}
  for _, k in ipairs(opts.kinds or {}) do
    if seen[k[1]] and not described[k[1]] then
      described[k[1]] = true
      parts[#parts + 1] = k[2] and k[2] ~= '' and (k[1] .. ' (' .. k[2] .. ')') or k[1]
    end
  end
  for _, k in ipairs(used) do
    if not described[k] then parts[#parts + 1] = k end
  end
  out[#out + 1] = 'Comment kinds: ' .. table.concat(parts, ', ')
  -- groups in the order of their first comment
  local groups, order = {}, {}
  for _, c in ipairs(comments) do
    local key = scope_key(c.scope)
    if not groups[key] then
      groups[key] = { scope = c.scope, items = {} }
      order[#order + 1] = key
    end
    table.insert(groups[key].items, c)
  end
  local n = {}
  for i, c in ipairs(comments) do n[c] = i end
  for _, key in ipairs(order) do
    local g = groups[key]
    out[#out + 1] = ''
    out[#out + 1] = '## ' .. M.heading(g.scope)
    out[#out + 1] = ''
    for _, c in ipairs(g.items) do
      local head = ('%d. **[%s]** %s'):format(n[c], c.kind, M.reference(c))
      if c.code and c.code ~= '' then head = head .. ' — `' .. c.code .. '`' end
      out[#out + 1] = head
      for _, l in ipairs(vim.split(c.text or '', '\n', { plain = true })) do out[#out + 1] = '   ' .. l end
    end
  end
  return out
end

return M
