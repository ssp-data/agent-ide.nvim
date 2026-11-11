-- The plugin's own record of a session run through an agent without a readable transcript
-- (the ACP agents): `stdpath('state')/agent-ide/sessions/<agent>/<session id>.jsonl`, 0600 in
-- 0700 folders. The first line is a header `{ version, agent, id, cwd, title, created }`;
-- a later line without `kind` adds to it (`{ agent_session_id }` once the agent named its
-- session); every other line is one stored Event (never a `live_only` one), appended in order,
-- asynchronously, one write chain per file, so a crash loses at most the last event. The
-- drawer lists these sessions (`scan`) and the chat reads them back (`history`).
local M = {}

M.VERSION = 1
local FILE_MODE, DIR_MODE = 384, 448 -- 0600, 0700
local HEAD = 16 * 1024 -- bytes of a file read for its header and first prompt
local FILES_PER_TICK = 8
local TITLE_MAX = 60
local DECODE_OPTS = require('agent-ide.transcript.parse').DECODE_OPTS

---@return string the folder of every log
function M.dir() return vim.fn.stdpath('state') .. '/agent-ide/sessions' end

---@param agent string
---@param id string
---@return string
function M.path(agent, id) return M.dir() .. '/' .. agent .. '/' .. id .. '.jsonl' end

local function ensure_dir(dir)
  if vim.fn.isdirectory(dir) == 1 then return true end
  local ok = pcall(vim.fn.mkdir, dir, 'p', DIR_MODE)
  return ok and vim.fn.isdirectory(dir) == 1
end

local function decode(line)
  local ok, obj = pcall(vim.json.decode, line, DECODE_OPTS)
  return ok and type(obj) == 'table' and obj or nil
end

-- Log -----------------------------------------------------------------------------------------

local Log = {}
Log.__index = Log

-- Write what is queued, then what was queued meanwhile; one open file at a time.
function Log:_drain()
  if self.writing or #self.queue == 0 then return end
  self.writing = true
  local text = table.concat(self.queue)
  self.queue = {}
  vim.uv.fs_open(self.path, 'a', FILE_MODE, function(err, fd)
    if err then
      self.writing = false
      return vim.schedule(function() self:_fail(err) end)
    end
    local off = 0
    local function step()
      if off >= #text then
        return vim.uv.fs_close(fd, function()
          self.writing = false
          vim.schedule(function() self:_drain() end)
        end)
      end
      vim.uv.fs_write(fd, text:sub(off + 1), -1, function(werr, n)
        if werr or not n or n <= 0 then
          return vim.uv.fs_close(fd, function()
            self.writing = false
            vim.schedule(function() self:_fail(werr or 'write made no progress') end)
          end)
        end
        off = off + n
        step()
      end)
    end
    step()
  end)
end

function Log:_fail(err)
  if not self.warned then
    self.warned = true
    vim.notify('Agent-IDE: cannot write the session log ' .. self.path .. ': ' .. tostring(err), vim.log.levels.WARN)
  end
  self:_drain()
end

function Log:_line(obj)
  local ok, text = pcall(vim.json.encode, obj)
  if not ok then return end
  self.queue[#self.queue + 1] = text .. '\n'
  self:_drain()
end

---Record one stored Event (callers leave `live_only` ones out).
---@param ev table
function Log:append(ev)
  local copy = {}
  for k, v in pairs(ev) do
    if k ~= 'live_only' and k ~= 'streamed' then copy[k] = v end
  end
  self:_line(copy)
end

---Add to the header: `{ agent_session_id = … }`, `{ title = … }`.
---@param fields table
function Log:meta(fields) self:_line(fields) end

---Nothing is waiting to be written (tests).
function Log:idle() return not self.writing and #self.queue == 0 end

---Open (or create) the log of Session `s`; `s.path` becomes the file. Returns nil when the
---folder cannot be made.
---@param s table Session
---@return table|nil log, string|nil err
function M.open(s)
  local path = M.path(s.agent, s.id)
  local dir = vim.fs.dirname(path)
  if not ensure_dir(M.dir()) or not ensure_dir(dir) then return nil, 'cannot create ' .. dir end
  local log = setmetatable({ path = path, queue = {}, writing = false }, Log)
  if not vim.uv.fs_stat(path) then
    log:_line({ version = M.VERSION, agent = s.agent, id = s.id, cwd = s.cwd, title = s.title, created = os.time() })
  end
  s.path = path
  return log
end

-- Reading ------------------------------------------------------------------------------------

---Header fields and events of the text of a log. A line that does not decode is skipped
---(the last one may still be being written); a line without `kind` is a header line.
---@param text string
---@return table header, table[] events
function M.parse(text)
  local header, events = {}, {}
  for line in text:gmatch('[^\n]+') do
    local obj = decode(line)
    if obj then
      if obj.kind ~= nil then
        events[#events + 1] = obj
      else
        for k, v in pairs(obj) do header[k] = v end
      end
    end
  end
  return header, events
end

local function read_file(path, limit, cb)
  vim.uv.fs_open(path, 'r', 438, function(err, fd)
    if err then return cb(nil) end
    vim.uv.fs_fstat(fd, function(_, st)
      local n = st and st.size or 0
      if limit and n > limit then n = limit end
      vim.uv.fs_read(fd, n, 0, function(_, data)
        vim.uv.fs_close(fd, function() cb(data or '', st) end)
      end)
    end)
  end)
end

---Load the log of `s` into `s.events` (and `agent_session_id`, `title` from the header),
---reading again only when the file changed and no process runs; always calls `cb` (scheduled).
---Events added while loading are kept after the history.
---@param s table Session
---@param cb fun()
function M.history(s, cb)
  local path = s.path or M.path(s.agent, s.id)
  vim.uv.fs_stat(path, vim.schedule_wrap(function(_, st)
    local key = st and (st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.size)
    if not st or s:_alive() or key == s.loaded_key then return cb() end
    local count = #s.events
    read_file(path, nil, vim.schedule_wrap(function(text)
      local header, history = M.parse(text or '')
      if type(header.agent_session_id) == 'string' and not s.agent_session_id then s.agent_session_id = header.agent_session_id end
      if type(header.title) == 'string' and not s.title then s.title = header.title end
      local extra = vim.list_slice(s.events, count + 1)
      local ts = s.turn_start
      if #extra > 0 and ts > count then
        ts = ts - count + #history
      else
        ts = math.max(ts, #history + 1)
        s.streaming = ''
      end
      s.events = vim.list_extend(history, extra)
      s.turn_start, s.loaded_key = ts, key
      s:_emit('events')
      cb()
    end))
  end))
end

---Metadata of the log at `path` (its first HEAD bytes and its stat): what the drawer shows.
---@param path string
---@param st table
---@param text string
---@return table|nil SessionMeta
function M.meta(path, st, text)
  local header, events = M.parse(text)
  local agent, id = path:match('([^/]+)/([^/]+)%.jsonl$')
  if type(header.agent) == 'string' then agent = header.agent end
  if type(header.id) == 'string' then id = header.id end
  if not agent or not id then return nil end
  local title = type(header.title) == 'string' and header.title ~= '' and header.title or nil
  if not title then
    for _, ev in ipairs(events) do
      if ev.kind == 'prompt' and type(ev.text) == 'string' and ev.text:find('%S') then
        title = vim.fn.strcharpart((ev.text:gsub('%s*\n%s*', ' ')), 0, TITLE_MAX)
        break
      end
    end
  end
  return { id = id, path = path, agent = agent, agent_session_id = header.agent_session_id,
    cwd = type(header.cwd) == 'string' and header.cwd or nil, title = title or '(untitled)',
    mtime = st.mtime.sec, activity = st.mtime.sec, size = st.size }
end

local function yield(fn) vim.defer_fn(fn, 0) end

---Every logged session, a few files per event-loop turn; `cb(sessions)` (scheduled).
---@param cb fun(sessions: table[])
function M.scan(cb)
  local files = {}
  local top = vim.uv.fs_scandir(M.dir())
  while top do
    local name, kind = vim.uv.fs_scandir_next(top)
    if not name then break end
    if kind == 'directory' then
      local sub = vim.uv.fs_scandir(M.dir() .. '/' .. name)
      while sub do
        local f, fk = vim.uv.fs_scandir_next(sub)
        if not f then break end
        if fk == 'file' and f:sub(-6) == '.jsonl' then files[#files + 1] = M.dir() .. '/' .. name .. '/' .. f end
      end
    end
  end
  local out, i = {}, 1
  local function step()
    local last = math.min(i + FILES_PER_TICK - 1, #files)
    local left = last - i + 1
    if left <= 0 then return cb(out) end
    for k = i, last do
      local path = files[k]
      read_file(path, HEAD, vim.schedule_wrap(function(text, st)
        if text and st then
          local ok, meta = pcall(M.meta, path, st, text)
          if ok and meta then out[#out + 1] = meta end
        end
        left = left - 1
        if left == 0 then
          i = last + 1
          if i <= #files then yield(step) else cb(out) end
        end
      end))
    end
  end
  vim.schedule(step)
end

return M
