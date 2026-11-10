--- Group sessions into projects: one project per git repository.
local M = {}

local uv = vim.uv

local function stat(path) return uv.fs_stat(path) end

local function dirname(p) return (p:gsub('/[^/]*$', '')) end

local function basename(p) return p:match('([^/]*)$') end

-- Byte-wise string order (Lua's `<` follows the locale's collation).
local function bytes_lt(a, b)
  for i = 1, math.min(#a, #b) do
    local x, y = a:byte(i), b:byte(i)
    if x ~= y then return x < y end
  end
  return #a < #b
end

--- Resolve the repository root for a directory holding a `.git` entry.
local function resolve_dotgit(dir)
  local dotgit = dir .. '/.git'
  local st = stat(dotgit)
  if not st then return nil end
  if st.type == 'file' then
    local f = io.open(dotgit, 'r')
    local line = f and f:read('*l')
    if f then f:close() end
    local gitdir = line and line:match('^gitdir:%s*(.-)%s*$')
    if gitdir then
      if gitdir:sub(1, 1) ~= '/' then gitdir = dir .. '/' .. gitdir end
      gitdir = uv.fs_realpath(gitdir) or vim.fs.normalize(gitdir)
      local repo = gitdir:match('^(.*)/%.git/worktrees/[^/]+/?$')
      if repo and repo ~= '' then return repo end
    end
  end
  return dir
end

--- Walk up from `cwd` looking for a git repository.
---@return string|nil root, boolean exists
function M.git_root(cwd, home)
  local exists = stat(cwd) ~= nil
  local dir = cwd
  while dir ~= '' and not stat(dir) do dir = dirname(dir) end
  while dir ~= '' do
    -- a .git at home or above is ignored unless cwd is home itself
    if cwd ~= home and (dir == home or vim.startswith(home, dir .. '/')) then return nil, exists end
    local root = resolve_dotgit(dir)
    if root then return root, exists end
    dir = dirname(dir)
  end
  return nil, exists
end

local function cached_root_of(home)
  local cache = {}
  return function(cwd)
    local hit = cache[cwd]
    if not hit then
      local root, exists = M.git_root(cwd, home)
      hit = { root, exists }
      cache[cwd] = hit
    end
    return hit[1], hit[2]
  end
end

---@param sessions table[] SessionMeta
---@param opts? { home: string, root_of: fun(cwd: string): string|nil, boolean }
---@return table[] Project
function M.group(sessions, opts)
  opts = opts or {}
  local home = opts.home or uv.os_homedir() or ''
  local root_of = opts.root_of or cached_root_of(home)

  local by_key, projects = {}, {}
  for _, meta in ipairs(sessions) do
    local s = vim.deepcopy(meta)
    local key, root, is_git, missing
    if s.cwd then
      local r, exists = root_of(s.cwd)
      if r then
        key, root, is_git = r, r, true
        if s.cwd ~= r and vim.startswith(s.cwd, r .. '/') then s.subpath = s.cwd:sub(#r + 2) end
      else
        key, is_git = s.cwd, false
        missing = not exists
      end
    else
      key, is_git, missing = basename(dirname(s.path or '')), false, true
    end
    local p = by_key[key]
    if not p then
      if is_git then missing = stat(root) == nil end
      p = { key = key, name = basename(key), root = root, is_git = is_git, missing = missing, mtime = 0, sessions = {} }
      by_key[key] = p
      projects[#projects + 1] = p
    end
    p.sessions[#p.sessions + 1] = s
    p.mtime = math.max(p.mtime, s.mtime or 0)
  end

  local counts = {}
  for _, p in ipairs(projects) do counts[p.name] = (counts[p.name] or 0) + 1 end
  for _, p in ipairs(projects) do
    if counts[p.name] > 1 then
      local parent = basename(dirname(p.key))
      if parent ~= '' then p.name = parent .. '/' .. p.name end
    end
    -- ties are broken by path, then id, so the order never depends on the backend's file order
    table.sort(p.sessions, function(a, b)
      if (a.mtime or 0) ~= (b.mtime or 0) then return (a.mtime or 0) > (b.mtime or 0) end
      if (a.path or '') ~= (b.path or '') then return bytes_lt(a.path or '', b.path or '') end
      return bytes_lt(tostring(a.id), tostring(b.id))
    end)
  end
  table.sort(projects, function(a, b)
    if a.mtime ~= b.mtime then return a.mtime > b.mtime end
    return bytes_lt(a.key, b.key)
  end)
  return projects
end

return M
