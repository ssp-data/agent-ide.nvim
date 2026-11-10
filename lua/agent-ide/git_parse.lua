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

---Default branch from `for-each-ref --format=%(refname)%00%(symref)` over origin/HEAD, main
---and master: origin/HEAD's target, else main, else master.
---@param out string
---@return string|nil ref, string|nil name e.g. 'origin/main', 'main'
function M.default_ref(out)
  local refs = {}
  for line in (out or ''):gmatch('[^\n]+') do
    local name, target = line:match('^([^%z]*)%z?(.*)$')
    refs[name] = target
  end
  local target = refs['refs/remotes/origin/HEAD']
  if target and target ~= '' then
    local short = target:gsub('^refs/remotes/', '')
    return short, (short:gsub('^origin/', ''))
  end
  if refs['refs/heads/main'] then return 'main', 'main' end
  if refs['refs/heads/master'] then return 'master', 'master' end
  return nil, nil
end

---@param s string
---@return string first line without the line end
function M.line(s) return ((s or ''):match('^[^\r\n]*')) end

return M
