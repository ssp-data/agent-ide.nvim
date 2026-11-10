-- Overall status (four levels), statusline text, status file for a desktop bar, persisted quota.
local session = require('agent-ide.session')
local live = require('agent-ide.live')

local M = {}

local NAMES = { 'ok', 'running', 'review', 'input' }
local STALE_SECONDS = 6 * 3600
local FILE_THROTTLE_MS = 200
local REDRAW_THROTTLE_MS = 100
local QUOTA_DEBOUNCE_MS = 1000

-- Sources can be replaced in tests: sessions, live map, clock, focused session.
M._src = {
  sessions = function() return session.all() end,
  live = function() return live.get() end,
  now = function() return os.time() end,
  current = function()
    local chat = package.loaded['agent-ide.ui.chat']
    return chat and chat.current() or nil
  end,
}

local windows, updated -- quota: name -> { utilization, resets_at|nil }, unix seconds of the last report
local q_seen -- last table seen from session.quota()
local q_dirty = false
local last_sig
local file_writes = 0 -- test counter

-- Level -------------------------------------------------------------------------------------

---@param sessions? table[]
---@param live_map? table
---@return { level: integer, name: string, waiting: integer, review: integer, busy: integer }
function M.level(sessions, live_map)
  sessions = sessions or M._src.sessions()
  live_map = live_map or M._src.live()
  local waiting, review, busy = 0, 0, 0
  local owned = {}
  for _, s in ipairs(sessions) do
    if s.owned then owned[s.id] = true end
    if s.state == 'waiting' then waiting = waiting + 1
    elseif s.state == 'done' or s.state == 'failed' then review = review + 1
    elseif s.state == 'busy' then busy = busy + 1 end
  end
  for id, e in pairs(live_map) do
    if not owned[id] then
      if e.status == 'waiting' then waiting = waiting + 1
      elseif e.status == 'busy' then busy = busy + 1 end
    end
  end
  local level = waiting > 0 and 4 or review > 0 and 3 or busy > 0 and 2 or 1
  return { level = level, name = NAMES[level], waiting = waiting, review = review, busy = busy }
end

-- Statusline --------------------------------------------------------------------------------

local function bar(left)
  local n = math.floor(left * 5 + 0.5)
  return ('▰'):rep(n) .. ('▱'):rep(5 - n)
end

local LABELS = { five_hour = '5h', seven_day = 'week' }

local function quota_text()
  if not windows then return '' end
  local names = {}
  for name, w in pairs(windows) do
    if type(w) == 'table' and type(w.utilization) == 'number' then names[#names + 1] = name end
  end
  table.sort(names, function(a, b)
    local oa, ob = a == 'five_hour' and 1 or a == 'seven_day' and 2 or 3, b == 'five_hour' and 1 or b == 'seven_day' and 2 or 3
    if oa ~= ob then return oa < ob end
    return a < b
  end)
  local now = M._src.now()
  local parts = {}
  for _, name in ipairs(names) do
    local w = windows[name]
    local label = LABELS[name] or name
    local stale = (updated and now - updated > STALE_SECONDS) or (type(w.resets_at) == 'number' and now > w.resets_at)
    if stale then
      parts[#parts + 1] = label .. ' ?'
    else
      local left = math.min(1, math.max(0, 1 - w.utilization))
      parts[#parts + 1] = ('%s %s %d%%%%'):format(label, bar(left), math.floor(left * 100 + 0.5))
    end
  end
  if #parts == 0 then return '' end
  return ' · ' .. table.concat(parts, ' · ')
end

local function compute_text()
  local l = M.level()
  local text
  if l.level == 1 then text = 'agents ok'
  elseif l.level == 2 then text = ('agents running (%d)'):format(l.busy)
  elseif l.level == 3 then text = ('review (%d)'):format(l.review)
  else text = ('input required (%d)'):format(l.waiting) end
  local ok, cur = pcall(M._src.current)
  if ok and type(cur) == 'table' and type(cur.model) == 'string' and cur.model ~= '' then
    text = text .. ' · ' .. cur.model:gsub('^claude%-', '')
  end
  return text .. quota_text()
end

---@return string
function M.statusline()
  local ok, text = pcall(compute_text)
  return ok and text or ''
end

---@return string highlight group
function M.statusline_hl()
  local ok, l = pcall(M.level)
  return 'AgentIdeLevel' .. (ok and l.level or 1)
end

---Ready lualine component.
function M.lualine()
  return {
    function() return M.statusline() end,
    color = function()
      local hl = vim.api.nvim_get_hl(0, { name = M.statusline_hl(), link = false })
      return hl.fg and { fg = ('#%06x'):format(hl.fg) } or nil
    end,
  }
end

-- Throttle: run now, then at most once per `ms`; calls during the wait collapse into one trailing run.
-- `reset()` cancels the wait and drops a queued trailing callback.
local function throttle(ms, fn)
  local timer, dirty = nil, false
  local arm
  local function fire(t)
    if timer ~= t then return end -- reset meanwhile
    t:close()
    timer = nil
    if dirty then
      dirty = false
      pcall(fn)
      arm()
    end
  end
  arm = function()
    local t = vim.uv.new_timer()
    timer = t
    t:start(ms, 0, vim.schedule_wrap(function() fire(t) end))
  end
  return setmetatable({}, {
    __call = function()
      if timer then dirty = true; return end
      pcall(fn)
      arm()
    end,
    __index = { reset = function()
      dirty = false
      local t = timer
      timer = nil
      if t then t:stop(); if not t:is_closing() then t:close() end end
    end },
  })
end

-- Files -------------------------------------------------------------------------------------

local leaving = false -- VimLeavePre ran: nothing may be written any more
local warned = false
local function warn(msg)
  if warned then return end
  warned = true
  vim.schedule(function() vim.notify('agent-ide: cannot write status (' .. tostring(msg) .. ')', vim.log.levels.WARN) end)
end

-- Test knobs: heartbeat and sweep intervals.
M._cfg = { heartbeat_ms = 30000, sweep_ms = 60000 }

local function runtime_dir()
  local base = vim.uv.os_getenv('XDG_RUNTIME_DIR')
  if not base or base == '' then base = vim.fn.stdpath('run') end
  return base .. '/agent-ide'
end

---@return string status file of this instance
function M.file() return runtime_dir() .. '/status-' .. vim.uv.os_getpid() .. '.json' end

local made = {}
---Create `dir` (mode 0700); `private`: tighten an existing directory this user owns.
local function ensure_dir(dir, private)
  if made[dir] then return true end
  local ok = pcall(vim.fn.mkdir, dir, 'p', '0700')
  local st = vim.uv.fs_stat(dir)
  if not ok or not st or st.type ~= 'directory' then return false end
  if private and st.mode % 512 ~= 448 and st.uid == vim.uv.getuid() then pcall(vim.uv.fs_chmod, dir, 448) end
  made[dir] = true
  return true
end

---Write `data` to `path` through a temp file and rename, asynchronously. Only luv calls inside:
---everything it needs comes from the main thread. A write that finishes after leaving is undone.
local function write_atomic(path, data, tmp, cb)
  local function fail(err)
    pcall(vim.uv.fs_unlink, tmp, function() end)
    warn(err)
    if cb then cb(false) end
  end
  vim.uv.fs_open(tmp, 'w', 384, function(err, fd)
    if err then return fail(err) end
    vim.uv.fs_write(fd, data, 0, function(werr)
      vim.uv.fs_close(fd, function()
        if werr then return fail(werr) end
        vim.uv.fs_rename(tmp, path, function(rerr)
          if rerr then return fail(rerr) end
          if leaving then pcall(vim.uv.fs_unlink, path, function() end) end
          if cb then cb(true) end
        end)
      end)
    end)
  end)
end

---Same, synchronously (used while leaving).
local function write_sync(path, data, tmp)
  local fd = vim.uv.fs_open(tmp, 'w', 384)
  if not fd then return end
  vim.uv.fs_write(fd, data, 0)
  vim.uv.fs_close(fd)
  if not vim.uv.fs_rename(tmp, path) then vim.uv.fs_unlink(tmp) end
end

---@return table the status file content
function M.snapshot()
  local l = M.level()
  local list = {}
  for _, s in ipairs(M._src.sessions()) do
    if s.state ~= 'parked' then
      local first = s.pending_permissions and s.pending_permissions[1]
      list[#list + 1] = {
        id = s.id,
        project = vim.fs.basename(s.cwd or ''),
        title = s.title or '',
        state = s.state,
        reason = (s.state == 'waiting' and first and first.tool_name) or '',
      }
    end
  end
  return {
    version = 1, pid = vim.uv.os_getpid(), updated = M._src.now(), level = l.level, name = l.name,
    waiting = l.waiting, review = l.review, busy = l.busy,
    sessions = #list > 0 and list or vim.empty_dict(),
  }
end

local function encode(snap)
  local json = vim.json.encode(snap)
  if #snap.sessions == 0 then json = json:gsub('"sessions":{}', '"sessions":[]') end
  return json
end

---Delete `status-<pid>.json` files in `dir` whose pid no longer exists. Asynchronous.
---@param dir string
---@param cb? fun(removed: string[])
local function sweep_dir(dir, cb)
  local own = vim.uv.os_getpid()
  local removed = {}
  vim.uv.fs_scandir(dir, function(err, req)
    if err or not req then return cb and vim.schedule(function() cb(removed) end) end
    while true do
      local name = vim.uv.fs_scandir_next(req)
      if not name then break end
      local pid = tonumber(name:match('^status%-(%d+)%.json$'))
      if pid and pid ~= own then
        local _, _, code = vim.uv.kill(pid, 0) -- signal 0 only checks existence
        if code == 'ESRCH' then
          vim.uv.fs_unlink(dir .. '/' .. name, function() end)
          removed[#removed + 1] = name
        end
      end
    end
    if cb then vim.schedule(function() cb(removed) end) end
  end)
end

---Remove status files of dead instances.
---@param cb? fun(removed: string[])
function M.sweep(cb) sweep_dir(runtime_dir(), cb) end

local last_sweep = 0
local function write_status()
  if leaving then return end
  file_writes = file_writes + 1
  local dir, path = runtime_dir(), M.file()
  if not ensure_dir(dir, true) then return warn('cannot create ' .. dir) end
  local ok, json = pcall(function() return encode(M.snapshot()) end)
  if not ok then return warn(json) end
  write_atomic(path, json, path .. '.' .. vim.uv.os_getpid() .. '.tmp')
  local now = vim.uv.now()
  if now - last_sweep >= M._cfg.sweep_ms then
    last_sweep = now
    sweep_dir(dir)
  end
end

local request_write = throttle(FILE_THROTTLE_MS, write_status)

-- Quota persistence -------------------------------------------------------------------------

local function quota_file() return vim.fn.stdpath('state') .. '/agent-ide/quota.json' end

---Reset times are epoch seconds (docs/protocol.md); a value in milliseconds is converted.
local function norm_reset(v)
  v = tonumber(v)
  if not v then return nil end
  return v > 1e11 and v / 1000 or v
end

local function write_quota(sync)
  q_dirty = false
  if leaving and not sync then return end
  if not windows then return end
  local dir, file = vim.fn.stdpath('state') .. '/agent-ide', quota_file()
  if not ensure_dir(dir) then return warn('cannot create ' .. dir) end
  local data = vim.json.encode({ updated = updated, windows = windows })
  local tmp = file .. '.' .. vim.uv.os_getpid() .. '.tmp'
  if sync then write_sync(file, data, tmp) else write_atomic(file, data, tmp) end
end

local quota_timer
local function persist_quota_soon()
  q_dirty = true
  if leaving then return end
  quota_timer = quota_timer or vim.uv.new_timer()
  quota_timer:start(QUOTA_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if quota_timer then quota_timer:close(); quota_timer = nil end
    write_quota()
  end))
end

---Load the persisted quota (asynchronously); ignored when a fresher report is already known.
---@param cb? fun(loaded: boolean)
function M.load_quota(cb)
  local function done(ok) if cb then vim.schedule(function() cb(ok) end) end end
  vim.uv.fs_open(quota_file(), 'r', 438, function(err, fd)
    if err then return done(false) end
    vim.uv.fs_fstat(fd, function(_, st)
      vim.uv.fs_read(fd, st and st.size or 0, 0, function(_, data)
        vim.uv.fs_close(fd, function()
          vim.schedule(function()
            local ok, obj = pcall(vim.json.decode, data or '', { luanil = { object = true, array = true } })
            if not ok or type(obj) ~= 'table' or type(obj.windows) ~= 'table' or type(obj.updated) ~= 'number' then
              return done(false)
            end
            local w = {}
            for name, v in pairs(obj.windows) do
              if type(v) == 'table' and type(v.utilization) == 'number' then
                w[name] = { utilization = v.utilization, resets_at = norm_reset(v.resets_at) }
              end
            end
            if windows == nil and next(w) then
              windows, updated = w, obj.updated
              M.refresh()
            end
            done(windows ~= nil)
          end)
        end)
      end)
    end)
  end)
end

-- Refresh -----------------------------------------------------------------------------------

local redraw = throttle(REDRAW_THROTTLE_MS, function() if not leaving then pcall(vim.cmd.redrawstatus) end end)

local function sync_quota()
  local q = session.quota()
  if q == q_seen then return end
  q_seen = q
  if type(q) ~= 'table' then return end
  local w = {}
  for name, v in pairs(q) do
    if type(v) == 'table' and type(v.utilization) == 'number' then
      w[name] = { utilization = v.utilization, resets_at = norm_reset(v.resets_at) }
    end
  end
  windows, updated = w, M._src.now()
  persist_quota_soon()
end

local refreshes = 0
local function do_refresh()
  sync_quota()
  local l = M.level()
  local text = M.statusline()
  local file_sig = vim.json.encode({ l, vim.tbl_map(function(s)
    local p = s.pending_permissions and s.pending_permissions[1]
    return { s.id, s.state, s.title, s.cwd, p and p.tool_name }
  end, M._src.sessions()) })
  if text ~= last_sig then
    last_sig = text
    redraw()
  end
  if file_sig ~= M._file_sig then
    M._file_sig = file_sig
    request_write()
  end
end

---Recompute; redraw the statusline and rewrite the status file when something changed.
function M.refresh()
  if leaving then return end
  if vim.in_fast_event() then return vim.schedule(M.refresh) end
  refreshes = refreshes + 1
  pcall(do_refresh)
end

local function on_change(_, what)
  if what == 'delta' then return end -- streaming text does not change the status
  M.refresh()
end

local heartbeat
local function cleanup()
  leaving = true
  request_write.reset()
  redraw.reset()
  for _, t in ipairs({ quota_timer, heartbeat }) do
    if t and not t:is_closing() then t:stop(); t:close() end
  end
  quota_timer, heartbeat = nil, nil
  if q_dirty then pcall(write_quota, true) end
  pcall(vim.uv.fs_unlink, M.file())
end

---Subscribe once (calling again does not double-subscribe), load the persisted quota, sweep
---status files of dead instances, start the heartbeat.
function M.setup()
  leaving = false
  session.off_change(on_change)
  session.on_change(on_change)
  local group = vim.api.nvim_create_augroup('agent-ide.status', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = cleanup })
  -- while the level is above 1 the file is rewritten regularly, so readers can age it out
  if heartbeat and not heartbeat:is_closing() then heartbeat:stop(); heartbeat:close() end
  heartbeat = vim.uv.new_timer()
  heartbeat:start(M._cfg.heartbeat_ms, M._cfg.heartbeat_ms, vim.schedule_wrap(function()
    if leaving then return end
    local ok, l = pcall(M.level)
    if ok and l.level > 1 then request_write() end
  end))
  last_sweep = vim.uv.now()
  M.sweep()
  M.load_quota()
  M.refresh()
end

-- Test only.
function M._cleanup() cleanup() end
function M._writes() return file_writes end
function M._refreshes() return refreshes end
function M._reset()
  windows, updated, q_seen, q_dirty, last_sig, M._file_sig, warned = nil, nil, nil, false, nil, nil, false
  file_writes, refreshes, leaving, last_sweep = 0, 0, false, 0
  made = {}
  request_write.reset()
  redraw.reset()
  for _, t in ipairs({ quota_timer, heartbeat }) do
    if t and not t:is_closing() then t:stop(); t:close() end
  end
  quota_timer, heartbeat = nil, nil
  M._cfg = { heartbeat_ms = 30000, sweep_ms = 60000 }
end
function M._quota() return windows, updated end
function M._flush_quota() write_quota() end

return M
