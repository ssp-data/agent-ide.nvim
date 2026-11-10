-- File moves for the trash (trash.lua): a rename, or across file systems a copy that is verified
-- before the source is removed. Symbolic links inside a folder are copied as links, never
-- followed; special files (FIFOs, sockets, devices) are refused before anything moves. Nothing
-- here removes a folder recursively without having checked its copy first.
local uv = vim.uv

local M = {}

local DIR_MODE = 448 -- 0700
-- Files up to this size are compared byte for byte after a copy; larger ones by size only.
M.COMPARE_MAX = 64 * 1024 * 1024
local CHUNK = 1024 * 1024

-- Test seams: the rename used for every move, and a hook run after a copy, before it is verified.
M._rename = function(a, b) return uv.fs_rename(a, b) end
M._after_copy = nil

local TYPES = { file = true, directory = true, link = true }

---Everything below `root` (and `root` itself as rel ''), depth first, parents before children:
---{ rel, type, size, mode, target }; nil and why when a special file is found.
---@param root string
---@return table[]|nil entries, string|nil err
function M.scan(root)
  local out = {}
  local function walk(path, rel)
    local st = uv.fs_lstat(path)
    if not st then return 'cannot read ' .. path end
    if not TYPES[st.type] then return ('a special file (%s): %s'):format(st.type, path) end
    out[#out + 1] = { rel = rel, type = st.type, size = st.size, mode = st.mode % 4096,
      target = st.type == 'link' and uv.fs_readlink(path) or nil }
    if st.type ~= 'directory' then return end
    local h = uv.fs_scandir(path)
    if not h then return 'cannot list ' .. path end
    local names = {}
    while true do
      local name = uv.fs_scandir_next(h)
      if not name then break end
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      local err = walk(path .. '/' .. name, rel == '' and name or (rel .. '/' .. name))
      if err then return err end
    end
  end
  local err = walk(root, '')
  if err then return nil, err end
  return out
end

-- Same bytes in two files of one size.
local function same_content(a, b, size)
  local fa, fb = uv.fs_open(a, 'r', 0), uv.fs_open(b, 'r', 0)
  local same = fa ~= nil and fb ~= nil
  local off = 0
  while same and off < size do
    local da, db = uv.fs_read(fa, CHUNK, off), uv.fs_read(fb, CHUNK, off)
    if not da or not db or da ~= db or #da == 0 then same = false else off = off + #da end
  end
  if fa then uv.fs_close(fa) end
  if fb then uv.fs_close(fb) end
  return same
end

---True when `dst` holds what `src` holds: the same entries with the same types, every file the
---same size (and the same bytes up to COMPARE_MAX), every link the same target.
---@return boolean ok, string|nil why
function M.verify(src, dst)
  local a, aerr = M.scan(src)
  if not a then return false, aerr end
  local b, berr = M.scan(dst)
  if not b then return false, berr end
  if #a ~= #b then return false, 'file count differs' end
  for i, e in ipairs(a) do
    local f = b[i]
    local rel = e.rel == '' and vim.fs.basename(src) or e.rel
    if f.rel ~= e.rel or f.type ~= e.type then return false, 'entries differ: ' .. rel end
    if e.type == 'link' and f.target ~= e.target then return false, 'link target differs: ' .. rel end
    if e.type == 'file' then
      if f.size ~= e.size then return false, 'size differs: ' .. rel end
      local p = e.rel == '' and '' or ('/' .. e.rel)
      if e.size <= M.COMPARE_MAX and not same_content(src .. p, dst .. p, e.size) then
        return false, 'content differs: ' .. rel
      end
    end
  end
  return true
end

---Create folder `dir` and its missing parents (0700), each new one added to `created`.
---@param dir string
---@param created string[]
---@return boolean
function M.mkdirs(dir, created)
  local missing = {}
  local d = dir
  while d and d ~= '/' and not uv.fs_lstat(d) do
    table.insert(missing, 1, d)
    d = vim.fs.dirname(d)
  end
  for _, m in ipairs(missing) do
    if not uv.fs_mkdir(m, DIR_MODE) then return false end
    created[#created + 1] = m
  end
  local st = uv.fs_stat(dir)
  return st ~= nil and st.type == 'directory'
end

-- Copy the scanned tree `list` from `src` to `dst` (which must not exist).
local function copy(src, dst, list)
  for _, e in ipairs(list) do
    local from = e.rel == '' and src or (src .. '/' .. e.rel)
    local to = e.rel == '' and dst or (dst .. '/' .. e.rel)
    if e.type == 'directory' then
      if not uv.fs_mkdir(to, DIR_MODE) then return false end
    elseif e.type == 'link' then
      if not e.target or not uv.fs_symlink(e.target, to) then return false end
    else
      if not uv.fs_copyfile(from, to, { excl = true }) then return false end
      if not uv.fs_chmod(to, e.mode) then return false end
    end
  end
  -- folder modes last: a read-only folder must not stop its own copy
  for i = #list, 1, -1 do
    local e = list[i]
    if e.type == 'directory' and not uv.fs_chmod(e.rel == '' and dst or (dst .. '/' .. e.rel), e.mode) then return false end
  end
  return true
end

---Remove the scanned tree `list` at `root` bottom-up: files and links unlinked, folders removed
---only when empty. The paths that are still there.
---@return string[] left
function M.remove_tree(root, list)
  local left = {}
  for i = #list, 1, -1 do
    local e = list[i]
    local p = e.rel == '' and root or (root .. '/' .. e.rel)
    local ok = e.type == 'directory' and uv.fs_rmdir(p) or (e.type ~= 'directory' and uv.fs_unlink(p))
    if not ok and uv.fs_lstat(p) then left[#left + 1] = p end
  end
  return left
end

---Move `src` to `dst` (must not exist; its missing parents are created and added to `created`).
---A rename; across file systems a copy, verified, then the source removed. Once the copy is
---verified the move counts, even when part of the source could not be removed: those paths
---come back as `left`.
---@param src string
---@param dst string
---@param created string[]
---@return true|nil ok, string|nil err, string[]|nil left
function M.move(src, dst, created)
  if not M.mkdirs(vim.fs.dirname(dst), created) then return nil, 'cannot create ' .. vim.fs.dirname(dst) end
  if uv.fs_lstat(dst) then return nil, 'already exists: ' .. dst end
  local list, serr = M.scan(src)
  if not list then return nil, serr end
  local ok, err = M._rename(src, dst)
  if ok then return true end
  if not (err and tostring(err):find('EXDEV', 1, true)) then return nil, tostring(err) end
  local copied = copy(src, dst, list)
  if copied and M._after_copy then M._after_copy(dst) end
  local same, why = false, 'copy failed'
  if copied then same, why = M.verify(src, dst) end
  if not same then
    -- only what this copy made: its own scan, removed bottom-up
    local made = M.scan(dst)
    if made then
      for _, e in ipairs(made) do if e.type == 'directory' then pcall(uv.fs_chmod, e.rel == '' and dst or (dst .. '/' .. e.rel), DIR_MODE) end end
      M.remove_tree(dst, made)
    end
    return nil, ('copy of %s does not match (%s)'):format(src, tostring(why))
  end
  local left = M.remove_tree(src, list)
  return true, nil, #left > 0 and left or nil
end

---Remove the folders `created` (deepest first) and then `root`, each only when empty. The ones
---still there.
---@param root string
---@param created string[]
---@return string[] left
function M.cleanup(root, created)
  local dirs = vim.list_extend({}, created)
  table.sort(dirs, function(a, b) return #a > #b end)
  dirs[#dirs + 1] = root
  local left = {}
  for _, d in ipairs(dirs) do
    if uv.fs_lstat(d) and not uv.fs_rmdir(d) then left[#left + 1] = d end
  end
  return left
end

return M
