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
local function throttle(ms, fn)
  local timer, dirty = nil, false
  local function arm()
    timer = timer or vim.uv.new_timer()
    timer:start(ms, 0, vim.schedule_wrap(function()
      if dirty then dirty = false; fn(); arm() else timer:close(); timer = nil end
    end))
  end
  return setmetatable({}, {
    __call = function()
      if timer then dirty = true; return end
      fn()
      arm()
    end,
    __index = { reset = function()
      dirty = false
      if timer then timer:stop(); timer:close(); timer = nil end
    end },
  })
end

-- Files -------------------------------------------------------------------------------------

local warned = false
local function warn(msg)
  if warned then return end
  warned = true
  vim.schedule(function() vim.notify('agent-ide: cannot write status (' .. tostring(msg) .. ')', vim.log.levels.WARN) end)
end

local function runtime_dir()
  local base = vim.uv.os_getenv('XDG_RUNTIME_DIR')
  if not base or base == '' then base = vim.fn.stdpath('run') end
  return base .. '/agent-ide'
end

---@return string per-instance status file
function M.file() return runtime_dir() .. '/status-' .. vim.fn.getpid() .. '.json' end

---@return string file holding the most recent write of any Neovim
function M.latest_file() return runtime_dir() .. '/status.json' end

local made = {}
local function ensure_dir(dir)
  if made[dir] then return true end
  local ok = pcall(vim.fn.mkdir, dir, 'p', '0700')
  if ok and vim.fn.isdirectory(dir) == 1 then made[dir] = true; return true end
  return false
end

---Write `data` to `path` through a temp file and rename, asynchronously.
local function write_atomic(path, data, cb)
  local tmp = path .. '.' .. vim.fn.getpid() .. '.tmp'
  local function fail(err) warn(err); if cb then cb(false) end end
  vim.uv.fs_open(tmp, 'w', 384, function(err, fd)
    if err then return fail(err) end
    vim.uv.fs_write(fd, data, 0, function(werr)
      vim.uv.fs_close(fd, function()
        if werr then return fail(werr) end
        vim.uv.fs_rename(tmp, path, function(rerr)
          if rerr then return fail(rerr) end
          if cb then cb(true) end
        end)
      end)
    end)
  end)
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
    version = 1, pid = vim.fn.getpid(), updated = M._src.now(), level = l.level, name = l.name,
    waiting = l.waiting, review = l.review, busy = l.busy,
    sessions = #list > 0 and list or vim.empty_dict(),
  }
end

local function encode(snap)
  local json = vim.json.encode(snap)
  if #snap.sessions == 0 then json = json:gsub('"sessions":{}', '"sessions":[]') end
  return json
end

local function write_status()
  file_writes = file_writes + 1
  local dir = runtime_dir()
  if not ensure_dir(dir) then return warn('cannot create ' .. dir) end
  local ok, json = pcall(function() return encode(M.snapshot()) end)
  if not ok then return warn(json) end
  write_atomic(M.file(), json, function(done)
    if done then write_atomic(M.latest_file(), json) end
  end)
end

local request_write = throttle(FILE_THROTTLE_MS, write_status)

-- Quota persistence -------------------------------------------------------------------------

local function quota_file() return vim.fn.stdpath('state') .. '/agent-ide/quota.json' end

local function write_quota()
  q_dirty = false
  if not windows then return end
  local dir = vim.fn.stdpath('state') .. '/agent-ide'
  if not ensure_dir(dir) then return warn('cannot create ' .. dir) end
  write_atomic(quota_file(), vim.json.encode({ updated = updated, windows = windows }))
end

local quota_timer
local function persist_quota_soon()
  q_dirty = true
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
                w[name] = { utilization = v.utilization, resets_at = type(v.resets_at) == 'number' and v.resets_at or nil }
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

local redraw = throttle(REDRAW_THROTTLE_MS, function() pcall(vim.cmd.redrawstatus) end)

local function sync_quota()
  local q = session.quota()
  if q == q_seen then return end
  q_seen = q
  if type(q) ~= 'table' then return end
  windows, updated = vim.deepcopy(q), M._src.now()
  persist_quota_soon()
end

---Recompute; redraw the statusline and rewrite the status file when something changed.
function M.refresh()
  if vim.in_fast_event() then return vim.schedule(M.refresh) end
  pcall(sync_quota)
  local ok, l = pcall(M.level)
  if not ok then return end
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

local function on_change() M.refresh() end

local function cleanup()
  if q_dirty then pcall(write_quota) end
  pcall(vim.uv.fs_unlink, M.file())
  local f = io.open(M.latest_file(), 'r')
  if f then
    local data = f:read('*a')
    f:close()
    local ok, obj = pcall(vim.json.decode, data)
    if ok and type(obj) == 'table' and obj.pid == vim.fn.getpid() then pcall(vim.uv.fs_unlink, M.latest_file()) end
  end
end

---Subscribe once (calling again does not double-subscribe), load the persisted quota.
function M.setup()
  session.off_change(on_change)
  session.on_change(on_change)
  local group = vim.api.nvim_create_augroup('agent-ide.status', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = cleanup })
  M.load_quota()
  M.refresh()
end

-- Test only.
function M._cleanup() cleanup() end
function M._writes() return file_writes end
function M._reset()
  windows, updated, q_seen, q_dirty, last_sig, M._file_sig, warned = nil, nil, nil, false, nil, nil, false
  file_writes = 0
  made = {}
  request_write.reset()
  redraw.reset()
end
function M._quota() return windows, updated end
function M._flush_quota() write_quota() end

return M
