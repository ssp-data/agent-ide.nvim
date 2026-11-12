-- Pure parsers of git output used by agent-ide.git. Paths come from `-z` output, so spaces,
-- quotes and non-ASCII characters arrive unchanged.
local M = {}

local SUBMODULE = '160000'

local function split0(s)
  local out = vim.split(s or '', '\0', { plain = true })
  if out[#out] == '' then out[#out] = nil end
  return out
end

---Files of `git diff -z --raw --numstat` (or `diff-tree` with the same flags): raw records
---first, then numstat records, both in the same order.
---@param out string
---@return { status: string, path: string, old_path: string|nil, added: integer|nil, removed: integer|nil, binary: boolean, submodule: boolean }[]
function M.raw_numstat(out)
  local t = split0(out)
  local files, by_path, order = {}, {}, {}
  local i = 1
  while i <= #t and t[i]:sub(1, 1) == ':' do
    local old_mode, new_mode, status = t[i]:match('^:(%d+) (%d+) %S+ %S+ (%S+)$')
    status = status or '?'
    local letter = status:sub(1, 1)
    local f = { status = letter, binary = false, submodule = old_mode == SUBMODULE or new_mode == SUBMODULE }
    if letter == 'R' or letter == 'C' then
      f.old_path, f.path = t[i + 1], t[i + 2]
      i = i + 3
    else
      f.path = t[i + 1]
      i = i + 2
    end
    files[#files + 1] = f
    order[#order + 1] = f
    by_path[f.path] = f
  end
  -- numstat: "a\td\tpath" or, for a rename/copy, "a\td\t" followed by old and new path
  local k = 0
  while i <= #t do
    local a, d, path = t[i]:match('^([%d-]+)\t([%d-]+)\t(.*)$')
    if not a then break end
    if path == '' then
      path = t[i + 2]
      i = i + 3
    else
      i = i + 1
    end
    k = k + 1
    local f = by_path[path] or order[k]
    if f then
      if a == '-' then
        f.binary = not f.submodule
      else
        f.added, f.removed = tonumber(a), tonumber(d)
      end
    end
  end
  return files
end

---@param out string `ls-files -z` output
---@return string[]
function M.paths(out) return split0(out) end

---Commits of `git log --format=%x1e%H%x1f%h%x1f%at%x1f%s [--shortstat]`, in output order.
---@param out string
---@return { hash: string, short: string, date: integer, subject: string, files: integer }[]
function M.log(out)
  local commits = {}
  for rec in (out or ''):gmatch('\30([^\30]*)') do
    local line, rest = rec:match('^([^\n]*)\n?(.*)$')
    local hash, short, date, subject = line:match('^(%x+)\31(%x+)\31(%d*)\31(.*)$')
    if hash then
      -- the first number of the shortstat line is the files count, whatever the language
      local files = tonumber(rest:match('(%d+)')) or 0
      commits[#commits + 1] = { hash = hash, short = short, date = tonumber(date) or 0, subject = subject, files = files }
    end
  end
  return commits
end

---Default branch from `for-each-ref --format=%(refname)%00%(symref)` over origin/HEAD, main,
---master, origin/main and origin/master: origin/HEAD's target, else main, else master. `refs`
---are every existing ref of that branch (local and origin), for a merge-base nearest HEAD.
---@param out string
---@return string|nil ref, string|nil name, string[] refs e.g. 'origin/main', 'main', { 'main', 'origin/main' }
function M.default_ref(out)
  local refs = {}
  for line in (out or ''):gmatch('[^\n]+') do
    local name, target = line:match('^([^%z]*)%z?(.*)$')
    refs[name] = target
  end
  local function existing(name)
    local list = {}
    if refs['refs/heads/' .. name] then list[#list + 1] = name end
    if refs['refs/remotes/origin/' .. name] then list[#list + 1] = 'origin/' .. name end
    return list
  end
  local target = refs['refs/remotes/origin/HEAD']
  if target and target ~= '' then
    local short = target:gsub('^refs/remotes/', '')
    local name = short:gsub('^origin/', '')
    local list = existing(name)
    if #list == 0 then list = { short } end
    return short, name, list
  end
  for _, name in ipairs({ 'main', 'master' }) do
    local list = existing(name)
    if #list > 0 then return list[1], name, list end
  end
  return nil, nil, {}
end

---@param s string
---@return string first line without the line end
function M.line(s) return ((s or ''):match('^[^\r\n]*')) end

local ESCAPES = { a = '\a', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', v = '\v', ['\\'] = '\\', ['"'] = '"' }

---A path as git quotes it (C style, within double quotes) back to its bytes; a string without
---the surrounding quotes is returned unchanged.
---@param s string
---@return string
function M.unquote(s)
  if s:sub(1, 1) ~= '"' or s:sub(-1) ~= '"' or #s < 2 then return s end
  return (s:sub(2, -2):gsub('\\(%d%d?%d?)', function(oct) return string.char(tonumber(oct, 8) % 256) end)
    :gsub('\\(.)', function(c) return ESCAPES[c] or c end))
end

-- The two paths of a `diff --git a/X b/Y` line (`rest` is what follows `diff --git `). Quoted
-- paths are unquoted; unquoted ones are identical halves (a rename has `rename from/to` lines).
local function header_paths(rest)
  if rest:sub(1, 1) == '"' then
    local q = rest:match('^(".-[^\\]")')
    if q then return (M.unquote(q):gsub('^a/', '')) end
  end
  local n = (#rest - 4) / 2
  if n >= 1 and rest:sub(n + 3, n + 4) == ' b' and rest:sub(1, 2) == 'a/' then return rest:sub(3, n + 2) end
  return (rest:match('^a/(.-) b/') or rest)
end

---Blocks of a patch (`git diff -p`), one per `diff --git` header, in output order: `path` (the
---new path), `old_path` for a rename or copy, `lines` from the first `@@` on (hunk headers,
---context, `+`, `-`, `\ No newline…`), `binary` for a `Binary files … differ` block and
---`mode_only` for one with mode lines and no hunk. Git's own header lines are left out.
---@param text string
---@return { path: string, old_path: string|nil, lines: string[], binary: boolean, mode_only: boolean }[]
function M.patch(text)
  local blocks, b, in_hunk = {}, nil, false
  for line in (text or ''):gmatch('[^\n]*\n?') do
    if line == '' then break end
    line = line:gsub('\n$', '')
    if line:sub(1, 11) == 'diff --git ' then
      b = { path = header_paths(line:sub(12)), lines = {}, binary = false, mode_only = false, modes = false }
      blocks[#blocks + 1] = b
      in_hunk = false
    elseif b then
      if in_hunk then
        b.lines[#b.lines + 1] = line
      elseif line:sub(1, 2) == '@@' then
        in_hunk = true
        b.lines[#b.lines + 1] = line
      elseif line:sub(1, 12) == 'rename from ' then
        b.old_path = M.unquote(line:sub(13))
      elseif line:sub(1, 10) == 'rename to ' then
        b.path = M.unquote(line:sub(11))
      elseif line:sub(1, 10) == 'copy from ' then
        b.old_path = M.unquote(line:sub(11))
      elseif line:sub(1, 8) == 'copy to ' then
        b.path = M.unquote(line:sub(9))
      elseif line:sub(1, 13) == 'Binary files ' then
        b.binary = true
      elseif line:sub(1, 9) == 'old mode ' or line:sub(1, 9) == 'new mode ' then
        b.modes = true
      end
    end
  end
  for _, blk in ipairs(blocks) do
    blk.mode_only = blk.modes and #blk.lines == 0 and not blk.binary
    blk.modes = nil
  end
  return blocks
end

-- Ref badges of one `%D` (with `--decorate=full`): `HEAD -> refs/heads/x` gives the branch, then
-- HEAD; a remote's symbolic HEAD (`refs/remotes/origin/HEAD`) is left out.
local function graph_refs(d)
  local refs = {}
  if d == '' then return refs end
  for item in vim.gsplit(d, ', ', { plain = true }) do
    local head_of = item:match('^HEAD %-> (.+)$')
    local name = head_of or item
    local tag = name:match('^tag: refs/tags/(.+)$') or name:match('^tag: (.+)$')
    if tag then
      refs[#refs + 1] = { name = tag, kind = 'tag' }
    elseif name == 'HEAD' then
      refs[#refs + 1] = { name = 'HEAD', kind = 'head' }
    elseif name:find('^refs/heads/') then
      refs[#refs + 1] = { name = name:sub(12), kind = 'branch' }
    elseif name:find('^refs/remotes/') then
      if not name:find('/HEAD$') then refs[#refs + 1] = { name = name:sub(14), kind = 'remote' } end
    else
      refs[#refs + 1] = { name = (name:gsub('^refs/', '')), kind = 'other' } -- e.g. grafted
    end
    if head_of then refs[#refs + 1] = { name = 'HEAD', kind = 'head' } end
  end
  return refs
end

---Rows of `git log --graph --format=%x1e%H%x1f%h%x1f%D%x1f%at%x1f%an%x1f%P%x1f%s` (with
---`--decorate=full`): a commit row per commit, its `graph` the prefix git drew; a graph-only line
---is a connector row `{ graph }` (trailing spaces cut). With `limit`, the commits after the first
---`limit` are cut off (and what follows them); `more` tells whether there were any.
---@param out string
---@param limit? integer
---@return table[] rows, boolean more
function M.graph(out, limit)
  local rows, n = {}, 0
  for line in (out or ''):gmatch('[^\n]+') do
    local graph, rest = line:match('^([^\30]*)\30(.*)$')
    if not graph then
      rows[#rows + 1] = { graph = (line:gsub('%s+$', '')) }
    else
      n = n + 1
      if limit and n > limit then return rows, true end
      -- six fields, then the subject (which may hold the separator itself)
      local f, at = {}, 1
      for i = 1, 6 do
        local s = rest:find('\31', at, true)
        if not s then break end
        f[i] = rest:sub(at, s - 1)
        at = s + 1
      end
      if #f == 6 then
        local parents = {}
        for p in f[6]:gmatch('%x+') do parents[#parents + 1] = p end
        rows[#rows + 1] = { graph = graph, hash = f[1], short = f[2], refs = graph_refs(f[3]), time = tonumber(f[4]) or 0,
          author = f[5], parents = parents, subject = (rest:sub(at):gsub('[%c]', ' ')) }
      else
        rows[#rows + 1] = { graph = (graph:gsub('%s+$', '')) }
      end
    end
  end
  return rows, false
end

return M
