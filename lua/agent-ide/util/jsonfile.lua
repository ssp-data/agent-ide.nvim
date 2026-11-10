-- Small JSON files of the plugin's own (hidden sessions, last command lists): read whole, written
-- atomically (temp file + rename) as 0600 in a 0700 folder, never under a `.claude` folder. A
-- missing, unreadable or corrupt file reads as nil, never as an error.
local uv = vim.uv

local M = {}

local FILE_MODE, DIR_MODE = 384, 448 -- 0600, 0700

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
  local dir = vim.fs.dirname(path)
  if vim.fn.isdirectory(dir) ~= 1 then pcall(vim.fn.mkdir, dir, 'p', DIR_MODE) end
  local st = uv.fs_stat(dir)
  if st and st.mode % 512 ~= DIR_MODE and st.uid == uv.getuid() then pcall(uv.fs_chmod, dir, DIR_MODE) end
  local ok, json = pcall(vim.json.encode, data)
  if not ok then return nil, json end
  local written, err = require('agent-ide.prompts.store').replace(path, json)
  if not written then return nil, err end
  pcall(uv.fs_chmod, path, FILE_MODE)
  return M.stamp(path)
end

return M
