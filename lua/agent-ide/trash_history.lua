-- Claude's `history.jsonl` for the trash (trash.lua): split out one session's lines, merge them
-- back in time order, and rewrite the file without losing lines other Claudes append meanwhile.
--
-- How Claude Code writes the file (observed, never by reading it): no lock file or lock folder
-- next to it, and no running Claude keeps it open, so each write opens, appends and closes. The
-- rewrite therefore keeps one fd on the original for the whole operation and compares with
-- fstat (size, mtime, inode); after the rename it reads whatever was still appended to the old
-- file through that fd and appends it to the new one. A writer that keeps the file open would
-- write into the old, unlinked file: on Linux, `holders` finds such a process in /proc and the
-- trash refuses; elsewhere only the re-check after the rename covers it.
-- Synchronous on purpose: a whole delete with a synthetic 50 MB history.jsonl (read twice,
-- split, written, fsynced) measured about 120 ms (tests/test_delete.lua, "measure"), on an
-- explicit, confirmed action; typical files are a few MB.
local uv = vim.uv
local jsonfile = require('agent-ide.util.jsonfile')

local M = {}

M.TMP_PREFIX = '.agent-ide-trash-' -- our temp files next to history.jsonl
local TRIES = 5
local STALE_TMP_S = 600

-- Test seams: run between writing the temp file and the check before the rename, and after the
-- rename (before each re-check of the old file).
M._before_rename = nil
M._after_rename = nil

---Lines of `text` (each with its newline) split into those of session `id` and the rest.
---Byte-exact: lines are only decoded to test their `sessionId`; one that does not decode stays.
---@return string kept, string removed, integer n
function M.split(text, id)
  local kept, removed, n = {}, {}, 0
  local pos = 1
  while pos <= #text do
    local nl = text:find('\n', pos, true)
    local line = text:sub(pos, nl or #text)
    pos = (nl or #text) + 1
    local mine = false
    if line:find(id, 1, true) then
      local ok, rec = pcall(vim.json.decode, line)
      mine = ok and type(rec) == 'table' and rec.sessionId == id
    end
    if mine then
      removed[#removed + 1] = line:sub(-1) == '\n' and line or (line .. '\n')
      n = n + 1
    else
      kept[#kept + 1] = line
    end
  end
  return table.concat(kept), table.concat(removed), n
end

local function stamp_of(line) return tonumber(line:match('"timestamp"%s*:%s*(%d+)')) end

local function lines_of(text)
  local out = {}
  for line in text:gmatch('[^\n]*\n?') do
    if line ~= '' then out[#out + 1] = line end
  end
  return out
end

---`lines` (each ending in a newline) put back into history `text` in time order: each right
---after the last line with a `timestamp` not later than its own (else at the start; a line
---without a timestamp goes at the end).
---@param text string
---@param lines string
---@return string
function M.merge(text, lines)
  local kept, back = lines_of(text), lines_of(lines)
  if #kept > 0 and kept[#kept]:sub(-1) ~= '\n' then kept[#kept] = kept[#kept] .. '\n' end
  local stamps = {}
  for i, k in ipairs(kept) do stamps[i] = stamp_of(k) end
  local out, i = {}, 1 -- kept[i..] not written yet
  for _, r in ipairs(back) do
    local t = stamp_of(r)
    local j = t and i - 1 or #kept
    if t then
      for x = i, #kept do
        if stamps[x] and stamps[x] <= t then j = x elseif stamps[x] and stamps[x] > t then break end
      end
    end
    for x = i, j do out[#out + 1] = kept[x] end
    i = math.max(i, j + 1)
    out[#out + 1] = r
  end
  for x = i, #kept do out[#out + 1] = kept[x] end
  return table.concat(out)
end

-- `len` bytes of `fd` from `off` (reads continued until all arrived); nil when it cannot.
local function read_fd(fd, off, len)
  local parts, got = {}, 0
  while got < len do
    local data = uv.fs_read(fd, len - got, off + got)
    if not data or #data == 0 then return nil end
    parts[#parts + 1] = data
    got = got + #data
  end
  return table.concat(parts)
end

---Processes other than this Neovim that have `path` open (Linux, from /proc); nil when this
---system has no /proc to ask.
---@param path string
---@return integer[]|nil pids
function M.holders(path)
  local real = uv.fs_realpath(path)
  if not uv.fs_stat('/proc/self/fd') then return nil end
  if not real then return {} end
  local me, out = tostring(uv.os_getpid()), {}
  local h = uv.fs_scandir('/proc')
  while h do
    local pid = uv.fs_scandir_next(h)
    if not pid then break end
    if pid:match('^%d+$') and pid ~= me then
      local d = uv.fs_scandir('/proc/' .. pid .. '/fd') -- other users' processes: not listable, skipped
      while d do
        local fd = uv.fs_scandir_next(d)
        if not fd then break end
        if uv.fs_readlink('/proc/' .. pid .. '/fd/' .. fd) == real then
          out[#out + 1] = tonumber(pid)
          break
        end
      end
    end
  end
  return out
end

---Remove temp files of ours next to `path` left by an earlier run that did not finish (older
---than ten minutes, so a delete running in another Neovim keeps its own).
function M.remove_stale_tmp(path)
  local dir = vim.fs.dirname(path)
  local h = uv.fs_scandir(dir)
  local now = os.time()
  while h do
    local name, typ = uv.fs_scandir_next(h)
    if not name then break end
    if typ == 'file' and vim.startswith(name, M.TMP_PREFIX) and name:match('^.+%-%d+%-%d+%.tmp$') then
      local st = uv.fs_lstat(dir .. '/' .. name)
      if st and now - st.mtime.sec > STALE_TMP_S then uv.fs_unlink(dir .. '/' .. name) end
    end
  end
end

---Rewrite `path` as `transform(text)`, never losing lines appended meanwhile.
---`transform(text)` returns the new text (nil: nothing to change) or nil and an error; it runs
---again whenever lines were appended before the rename. After the rename, lines still appended
---to the old file go through `on_extra(extra)` (returns the part to append, or nil and an
---error) and are appended to the new file.
---The result: ok, err, and on failure `renamed` (the new file is in place, so the caller must
---undo it) and `pending` (text that should be in the file but could not be appended).
---@param path string
---@param opts { transform: fun(text: string): string|nil, string|nil, on_extra?: fun(extra: string): string|nil, string|nil, create?: boolean }
---@return true|nil ok, string|nil err, { renamed: boolean, pending: string }|nil
function M.rewrite(path, opts)
  local lst = uv.fs_lstat(path)
  if lst and lst.type ~= 'file' then return nil, 'history.jsonl is not a plain file' end
  if not lst and not opts.create then return true end
  local fd, st, text
  if lst then
    fd = uv.fs_open(path, 'r', 0)
    st = fd and uv.fs_fstat(fd)
    if not st or st.ino ~= lst.ino then
      if fd then uv.fs_close(fd) end
      return nil, 'cannot read ' .. path
    end
    text = read_fd(fd, 0, st.size)
    if not text then
      uv.fs_close(fd)
      return nil, 'cannot read ' .. path
    end
  end
  local function fail(err, info)
    if fd then uv.fs_close(fd) end
    return nil, err, info
  end
  text = text or ''
  local len, mtime = st and st.size or 0, st and st.mtime
  local mode = st and st.mode % 4096 or 384
  local done = false
  for _ = 1, TRIES do
    local new, terr = opts.transform(text)
    if terr then return fail(terr) end
    if new == nil then
      if fd then uv.fs_close(fd) end
      return true
    end
    local tmp, werr = jsonfile.write_tmp(path, new, mode, M.TMP_PREFIX)
    if not tmp then return fail('cannot write next to ' .. path .. ': ' .. tostring(werr)) end
    if M._before_rename then M._before_rename(path) end
    if fd then
      local now, at = uv.fs_fstat(fd), uv.fs_lstat(path)
      if not now or not at or at.ino ~= now.ino then
        uv.fs_unlink(tmp)
        return fail(path .. ' was replaced meanwhile; try again')
      end
      if now.size > len then -- appended meanwhile: take it in and transform again
        local extra = read_fd(fd, len, now.size - len)
        uv.fs_unlink(tmp)
        if not extra then return fail('cannot read ' .. path) end
        text, len, mtime = text .. extra, now.size, now.mtime
      elseif now.size < len or now.mtime.sec ~= mtime.sec or now.mtime.nsec ~= mtime.nsec then
        uv.fs_unlink(tmp)
        return fail(path .. ' changed meanwhile; try again')
      else
        local ok, rerr = jsonfile.commit(tmp, path)
        if not ok then return fail(tostring(rerr)) end
        done = true
      end
    else
      -- creating it: a link fails when the name was taken meanwhile
      local ok, lerr = uv.fs_link(tmp, path)
      uv.fs_unlink(tmp)
      if not ok then return fail(path .. ' appeared meanwhile; try again (' .. tostring(lerr) .. ')') end
      done = true
    end
    if done then break end
  end
  if not done then return fail(path .. ' kept changing; try again') end
  if not fd then return true end
  -- lines written into the old file after our last look: carried over until it stays still
  local still = 0
  for _ = 1, 20 do
    if M._after_rename then M._after_rename(path) end
    local now = uv.fs_fstat(fd)
    if now and now.size > len then
      still = 0
      local extra = read_fd(fd, len, now.size - len)
      if not extra then return fail('cannot read the old ' .. path, { renamed = true, pending = '' }) end
      len = now.size
      local add, eerr = extra, nil
      if opts.on_extra then add, eerr = opts.on_extra(extra) end
      if not add then return fail(eerr, { renamed = true, pending = extra }) end
      if add ~= '' then
        local ok, aerr = jsonfile.append(path, add)
        if not ok then return fail('cannot append to ' .. path .. ': ' .. tostring(aerr), { renamed = true, pending = add }) end
      end
    else
      still = still + 1
      if still >= 3 then break end
      uv.sleep(1)
    end
  end
  uv.fs_close(fd)
  return true
end

return M
