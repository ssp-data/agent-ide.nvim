-- Small JSON files of the plugin's own (hidden sessions, last command lists): read whole, written
-- atomically (temp file + rename) as 0600 in a 0700 folder, never under a `.claude` folder. A
-- missing, unreadable or corrupt file reads as nil, never as an error.
-- Also the safe writer the trash uses: every byte written (short writes continued), the size
-- checked with fstat, fsync before the rename and of the folder after, the temp file removed on
-- any failure.
local uv = vim.uv

local M = {}

local FILE_MODE, DIR_MODE = 384, 448 -- 0600, 0700

-- Test seam: one write call (returns the bytes written, or nil and an error).
M._write = function(fd, data, offset) return uv.fs_write(fd, data, offset) end

---Write all of `data` to `fd` from `offset` (nil or -1: the current position / the end of an
---O_APPEND file), continuing short writes; a call that writes nothing is a failure.
---@return true|nil ok, string|nil err
function M.write_all(fd, data, offset)
  local pos, off = 1, offset or -1
  while pos <= #data do
    local n, err = M._write(fd, pos == 1 and data or data:sub(pos), off)
    if not n then return nil, tostring(err or 'write failed') end
    if n <= 0 then return nil, 'write made no progress' end
    pos = pos + n
    if off >= 0 then off = off + n end
  end
  return true
end

-- fsync a folder, so a rename in it survives a crash; not every system allows it (ignored).
local function sync_dir(dir)
  local fd = uv.fs_open(dir, 'r', 0)
  if fd then
    pcall(uv.fs_fsync, fd)
    uv.fs_close(fd)
  end
end

---Write `text` to a new temporary file next to `path` (name `<prefix><pid>-<time>.tmp`, mode
---`mode`): every byte, size checked, fsynced. Its path, or nil and an error (nothing left).
---@param path string
---@param text string
---@param mode integer
---@param prefix? string default '.agent-ide-'
---@return string|nil tmp, string|nil err
function M.write_tmp(path, text, mode, prefix)
  local tmp = ('%s/%s%d-%d.tmp'):format(vim.fs.dirname(path), prefix or '.agent-ide-', uv.os_getpid(), uv.hrtime())
  local fd, oerr = uv.fs_open(tmp, 'wx', mode)
  if not fd then return nil, tostring(oerr) end
  local ok, err = M.write_all(fd, text, 0)
  if ok then
    uv.fs_fchmod(fd, mode) -- the mode asked for, not the umask's
    local st = uv.fs_fstat(fd)
    if not st or st.size ~= #text then
      ok, err = nil, ('size check failed: %s of %d bytes'):format(st and st.size or '?', #text)
    elseif not uv.fs_fsync(fd) then
      ok, err = nil, 'fsync failed'
    end
  end
  uv.fs_close(fd)
  if not ok then
    uv.fs_unlink(tmp)
    return nil, err
  end
  return tmp
end

---Rename `tmp` over `path` and fsync the folder; the temp file is removed when that fails.
---@return true|nil ok, string|nil err
function M.commit(tmp, path)
  local ok, err = uv.fs_rename(tmp, path)
  if not ok then
    uv.fs_unlink(tmp)
    return nil, tostring(err)
  end
  sync_dir(vim.fs.dirname(path))
  return true
end

---Replace (or create) `path` with `text` atomically, as `mode`.
---@return true|nil ok, string|nil err
function M.write_atomic(path, text, mode, prefix)
  local tmp, err = M.write_tmp(path, text, mode, prefix)
  if not tmp then return nil, err end
  return M.commit(tmp, path)
end

---Append `text` to the existing file `path` (O_APPEND: whole lines from other writers stay
---whole), fsynced. A failure may leave part of `text` appended.
---@return true|nil ok, string|nil err
function M.append(path, text)
  local fd, oerr = uv.fs_open(path, 'a', FILE_MODE)
  if not fd then return nil, tostring(oerr) end
  local ok, err = M.write_all(fd, text, -1)
  if ok and not uv.fs_fsync(fd) then ok, err = nil, 'fsync failed' end
  uv.fs_close(fd)
  return ok, err
end

-- Under a `.claude` folder (as given or with links resolved)?
local function under_claude(path)
  local function has(p) return p and (('/' .. p .. '/'):find('/.claude/', 1, true) ~= nil) end
  if has(path) then return true end
  local dir = vim.fs.dirname(path)
  while dir and dir ~= '/' and not uv.fs_stat(dir) do dir = vim.fs.dirname(dir) end
  return has(dir and uv.fs_realpath(dir))
end

---Modification stamp of `path` ('' when it does not exist): changes with every write.
---@param path string
---@return string
function M.stamp(path)
  local st = uv.fs_stat(path)
  return st and (st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.size .. ':' .. st.ino) or ''
end

---Decode `text`; nil unless it is a JSON object with `version` 1.
---@param text string|nil
---@return table|nil
function M.decode(text)
  if not text or text == '' then return nil end
  local ok, t = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(t) ~= 'table' or t.version ~= 1 then return nil end
  return t
end

---Content of `path` (see `decode`) and its stamp, synchronously.
---@param path string
---@return table|nil data, string stamp
function M.read(path)
  local stamp = M.stamp(path)
  local f = stamp ~= '' and io.open(path, 'rb')
  if not f then return nil, stamp end
  local text = f:read('a')
  f:close()
  return M.decode(text), stamp
end

---Same, asynchronously; `cb(data, stamp)` runs on the main loop.
---@param path string
---@param cb fun(data: table|nil, stamp: string)
function M.read_async(path, cb)
  local done = vim.schedule_wrap(function(text) cb(M.decode(text), M.stamp(path)) end)
  uv.fs_open(path, 'r', 438, function(err, fd)
    if err or not fd then return done(nil) end
    uv.fs_fstat(fd, function(serr, st)
      if serr or not st then return uv.fs_close(fd, function() done(nil) end) end
      uv.fs_read(fd, st.size, 0, function(rerr, data)
        uv.fs_close(fd, function() done(not rerr and data or nil) end)
      end)
    end)
  end)
end

---Write `data` as JSON to `path` atomically, 0600 in a 0700 folder.
---@param path string
---@param data table
---@return string|nil stamp of the written file, nil on failure
---@return string|nil err
function M.write(path, data)
  if under_claude(path) then return nil, 'refusing to write under a .claude folder' end
  local dir = vim.fs.dirname(path)
  if vim.fn.isdirectory(dir) ~= 1 then pcall(vim.fn.mkdir, dir, 'p', DIR_MODE) end
  if vim.fn.isdirectory(dir) ~= 1 then return nil, 'cannot create ' .. dir end
  local st = uv.fs_stat(dir)
  if st and st.mode % 512 ~= DIR_MODE and st.uid == uv.getuid() then pcall(uv.fs_chmod, dir, DIR_MODE) end
  local ok, json = pcall(vim.json.encode, data)
  if not ok then return nil, json end
  local written, err = M.write_atomic(path, json, FILE_MODE)
  if not written then return nil, err end
  return M.stamp(path)
end

return M
