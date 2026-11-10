-- Overall status (four levels), statusline text, status file for a desktop bar, persisted quota.
local session = require('agent-ide.session')
local live = require('agent-ide.live')

local M = {}

local NAMES = { 'ok', 'running', 'review', 'input' }
local STALE_SECONDS = 3600 -- quota values older than this are shown dimmed with `?`
local AGE_SHOWN_SECONDS = 600 -- older than this: the footer says how old
local QUOTA_FILE_READ_SECONDS = 60 -- `quota.file` is read at most this often
local QUOTA_FILE_MAX_AGE = 30 * 60 -- an older `quota.file` is not used
local FILE_THROTTLE_MS = 200
local REDRAW_THROTTLE_MS = 100
local QUOTA_DEBOUNCE_MS = 1000

-- Sources can be replaced in tests: sessions, live map, clock, focused session.
M._src = {
  sessions = function() return session.all() end,
  live = function() return live.fresh() end, -- entries not refreshed for two poll intervals do not count
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

---Percent used, rounded and clamped to 0..100, of a fraction used (0..1).
local function percent_used(used) return math.min(100, math.max(0, math.floor(used * 100 + 0.5))) end

---Bar of five cells filling with use; `dim`: the values are too old to trust (lighter cells).
local function bar(pct, dim)
  local n = math.floor(pct / 20 + 0.5)
  return (dim and '▪' or '▰'):rep(n) .. (dim and '▫' or '▱'):rep(5 - n)
end

---`5h`, `week`, `week <model>` for `seven_day_<model>`, else the key's words.
local function label_of(name)
  if name == 'five_hour' then return '5h' end
  if name == 'seven_day' then return 'week' end
  local rest = name:match('^seven_day_(.+)$')
  if rest then return 'week ' .. rest:gsub('_', ' ') end
  rest = name:match('^five_hour_(.+)$')
  if rest then return '5h ' .. rest:gsub('_', ' ') end
  return (name:gsub('_', ' '))
end

local function order_of(name)
  if name == 'five_hour' then return 1 end
  if name == 'seven_day' then return 2 end
  if name:find('^seven_day_') then return 3 end
  return 4
end

---` · 25m old` once the values are older than 10 minutes.
local function age_text(age)
  if not age or age <= AGE_SHOWN_SECONDS then return '' end
  if age < 3600 then return (' · %dm old'):format(math.floor(age / 60)) end
  if age < 2 * 86400 then return (' · %dh old'):format(math.floor(age / 3600)) end
  return (' · %dd old'):format(math.floor(age / 86400))
end

---One part: `label ▰▰▱▱▱ 40%`, or dimmed with `?` when it cannot be trusted.
local function part(label, used, stale)
  local pct = percent_used(used)
  if stale then return ('%s %s ?'):format(label, bar(pct, true)) end
  return ('%s %s %d%%%%'):format(label, bar(pct), pct)
end

-- `quota.file`: limits written by another tool, read at most every 60 s, asynchronously.
local ext -- { limits = { label, used, resets_at|nil }[], updated = epoch seconds } of the last good read
local ext_read_at -- M._src.now() of the last read started
local ext_reading = false

---Epoch seconds of an ISO 8601 time (`2026-11-10T12:00:00.5+01:00`, `…Z`) or of a number
---(seconds or milliseconds); nil when it is neither.
function M._parse_time(v)
  if type(v) == 'number' then return v > 1e11 and v / 1000 or v end
  if type(v) ~= 'string' then return nil end
  local y, mo, d, h, mi, s, rest = v:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$')
  if not y then return nil end
  rest = rest:gsub('^%.%d+', '')
  local offset = 0
  if rest ~= '' and rest ~= 'Z' and rest ~= 'z' then
    local sign, oh, om = rest:match('^([+-])(%d%d):?(%d%d)$')
    if not sign then return nil end
    offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == '-' and -1 or 1)
  end
  -- days from 1970-01-01 of a proleptic Gregorian date (no time zone involved)
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  if mo <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s) - offset
end

---Limits of a `quota.file` text, nil when malformed. `percent` is the fraction used (0..1, as
---Omarchy's agents panel writes it); a value above 1 is taken as percent (0..100).
---@return { limits: table[], updated: number|nil }|nil
function M._parse_quota_file(text, mtime)
  local ok, obj = pcall(vim.json.decode, text or '', { luanil = { object = true, array = true } })
  if not ok or type(obj) ~= 'table' or type(obj.limits) ~= 'table' or not vim.islist(obj.limits) then return nil end
  local limits = {}
  for _, l in ipairs(obj.limits) do
    if type(l) ~= 'table' or type(l.label) ~= 'string' or l.label == '' or type(l.percent) ~= 'number' then return nil end
    local used = l.percent > 1 and l.percent / 100 or l.percent
    limits[#limits + 1] = { label = l.label, used = used, resets_at = M._parse_time(l.resetsAt) }
  end
  if #limits == 0 then return nil end
  return { limits = limits, updated = M._parse_time(obj.updatedAt) or mtime }
end

local function quota_file_path()
  local q = require('agent-ide.config').get().quota
  local f = type(q) == 'table' and q.file or nil
  return type(f) == 'string' and f ~= '' and vim.fn.expand(f) or nil
end

local function read_quota_file(path, now)
  if ext_reading or (ext_read_at and now - ext_read_at < QUOTA_FILE_READ_SECONDS) then return end
  ext_reading, ext_read_at = true, now
  local function done(v)
    vim.schedule(function()
      ext_reading = false
      local before = vim.json.encode(ext or {})
      ext = v
      if vim.json.encode(ext or {}) ~= before then M.refresh() end
    end)
  end
  vim.uv.fs_open(path, 'r', 438, function(err, fd)
    if err then return done(nil) end
    vim.uv.fs_fstat(fd, function(_, st)
      if not st or st.size > 1024 * 1024 then return vim.uv.fs_close(fd, function() done(nil) end) end
      vim.uv.fs_read(fd, st.size, 0, function(_, data)
        vim.uv.fs_close(fd, function()
          vim.schedule(function() done(M._parse_quota_file(data, st.mtime.sec)) end)
        end)
      end)
    end)
  end)
end

---The `quota.file` text when it is set, read and fresh (not older than 30 minutes), else nil.
local function file_quota_text(now)
  local path = quota_file_path()
  if not path then return nil end
  read_quota_file(path, now)
  if not ext or not ext.updated or now - ext.updated > QUOTA_FILE_MAX_AGE then return nil end
  local parts = {}
  for _, l in ipairs(ext.limits) do
    parts[#parts + 1] = part(l.label, l.used, l.resets_at ~= nil and now > l.resets_at)
  end
  return ' · ' .. table.concat(parts, ' · ') .. age_text(now - ext.updated)
end

local function quota_text()
  local now = M._src.now()
  local from_file = file_quota_text(now)
  if from_file then return from_file end
  if not windows then return '' end
  local names, overage = {}, {}
  for name, w in pairs(windows) do
    if type(w) == 'table' and type(w.utilization) == 'number' then
      if name:find('overage', 1, true) then overage[#overage + 1] = name else names[#names + 1] = name end
    end
  end
  if #names == 0 then names = overage end -- overage windows only when they are all there is
  table.sort(names, function(a, b)
    local oa, ob = order_of(a), order_of(b)
    if oa ~= ob then return oa < ob end
    return a < b
  end)
  local age = updated and now - updated
  local old = age and age > STALE_SECONDS
  local parts = {}
  for _, name in ipairs(names) do
    local w = windows[name]
    parts[#parts + 1] = part(label_of(name), w.utilization, old or (type(w.resets_at) == 'number' and now > w.resets_at))
  end
  if #parts == 0 then return '' end
  return ' · ' .. table.concat(parts, ' · ') .. age_text(age)
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
  ext, ext_read_at, ext_reading = nil, nil, false
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
