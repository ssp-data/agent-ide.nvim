-- Live session state: polls `claude agents --json` asynchronously.
-- Read-only: never signals or stops any process.
local M = {}

-- `done`/`failed` come from Sessions of this Neovim (a result waits to be read), never from the live map.
local RANK = { waiting = 6, failed = 5, done = 4, busy = 3, idle = 2, parked = 1 }
local PASSTHROUGH = { busy = true, waiting = true, idle = true }

local map = {}
local timer = nil
local generation = 0 -- bumped by stop(); results from older generations are dropped
local running = false -- a command run is still in flight
local notified = false -- one failure notice per Neovim session
local interval -- ms between polls while polling, nil when stopped
local refreshed_at -- vim.uv.now() of the last finished poll (or query), nil before the first
local stale_after -- ms after `refreshed_at` the map stops counting (two poll intervals)

---Sessions by id, and whether `text` decoded as a JSON array at all: anything else (a banner,
---a future format, an empty wrapper object) is not "nothing runs" but an answer we cannot read.
---`[]` is valid and means nothing runs.
---@param text string
---@return table<string, { status: string, pid: integer, cwd: string, name: string|nil }> map
---@return boolean readable
function M.parse(text)
  local ok, data = pcall(vim.json.decode, text or '', { luanil = { object = true, array = true } })
  -- `luanil` turns an empty array into an empty table, which vim.islist accepts
  if not ok or type(data) ~= 'table' or not vim.islist(data) or not vim.trim(text):match('^%[') then return {}, false end
  local out = {}
  for _, e in ipairs(data) do
    if type(e) == 'table' and type(e.sessionId) == 'string' then
      out[e.sessionId] = { status = e.status, pid = e.pid, cwd = e.cwd, name = e.name }
    end
  end
  return out, true
end

---@param m table
---@param session_id string
---@return string
function M.state_of(m, session_id)
  local e = m[session_id]
  if e and PASSTHROUGH[e.status] then return e.status end
  return 'parked'
end

---@param states string[]
---@return string
function M.rollup(states)
  local best = 'parked'
  for _, s in ipairs(states) do
    if (RANK[s] or 0) > RANK[best] then best = s end
  end
  return best
end

---The last map polled, however old (the drawer shows it while polling runs).
function M.get() return map end

---@return boolean the map was not refreshed for longer than two poll intervals
function M.stale()
  return refreshed_at ~= nil and stale_after ~= nil and vim.uv.now() - refreshed_at > stale_after
end

---The map when it is current, else empty: what the footer level, "next waiting" and the
---"running elsewhere" check count. Entries not refreshed for two poll intervals do not count.
function M.fresh()
  if M.stale() then return {} end
  return M.get()
end

local function store(new, on_change)
  refreshed_at = vim.uv.now()
  if not vim.deep_equal(new, map) then
    map = new
    if on_change then on_change(map) end
  end
end

local function fail(reason)
  if notified then return end
  notified = true
  vim.notify('agent-ide: cannot read live sessions (' .. reason .. ')', vim.log.levels.WARN)
end

local function poll(gen, opts)
  if gen ~= generation or running then return end
  local function finish(new, reason)
    if gen ~= generation then return end -- stopped meanwhile: `running` belongs to a newer start
    running = false
    if reason then fail(reason) end
    store(new, opts.on_change)
    if opts.on_poll then opts.on_poll(map) end
  end
  running = true
  -- a hung command is killed after the timeout, so polling never stalls
  local ok = pcall(vim.system, opts.cmd, { text = true, timeout = opts.timeout_ms }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then return finish({}, 'exit code ' .. tostring(res.code)) end
      local new, readable = M.parse(res.stdout)
      if readable then return finish(new) end
      -- a failed poll: the previous map stays unrefreshed and ages out (`fresh`)
      if gen ~= generation then return end
      running = false
      fail('unexpected output')
      if opts.on_poll then opts.on_poll(map) end
    end)
  end)
  if not ok then finish({}, 'command not found') end
end

---`on_change` runs when the map changed, `on_poll` after every finished poll.
---`defer`: the first poll after one interval, not now.
---@param opts { interval_ms: integer, cmd?: string[], timeout_ms?: integer, defer?: boolean, on_change?: fun(map: table), on_poll?: fun(map: table) }
function M.start(opts)
  M.stop()
  local gen = generation
  local p = {
    cmd = opts.cmd or { 'claude', 'agents', '--json' },
    timeout_ms = opts.timeout_ms or math.max(opts.interval_ms, 2000),
    on_change = opts.on_change,
    on_poll = opts.on_poll,
  }
  local function tick() poll(gen, p) end
  interval, stale_after = opts.interval_ms, 2 * opts.interval_ms
  timer = vim.uv.new_timer()
  timer:start(opts.interval_ms, opts.interval_ms, vim.schedule_wrap(tick))
  if not opts.defer then tick() end
end

---@return boolean polling
function M.active() return timer ~= nil end

---@return integer|nil ms between polls, nil when stopped
function M.interval() return interval end

---Run the live command once, now, asynchronously (not the cached map): `cb(true)` with the
---map stored when it answered, `cb(false, reason)` when it could not be run, failed, or
---printed something that is not a JSON list ('unexpected output'; the map is left as it was).
---@param opts { cmd?: string[], interval_ms: integer }
---@param cb fun(ok: boolean, reason?: string)
function M.query(opts, cb)
  local cmd = opts.cmd or { 'claude', 'agents', '--json' }
  local ok = pcall(vim.system, cmd, { text = true, timeout = math.max(opts.interval_ms, 2000) }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then return cb(false, 'exit code ' .. tostring(res.code)) end
      local new, readable = M.parse(res.stdout)
      if not readable then return cb(false, 'unexpected output') end
      stale_after = stale_after or 2 * opts.interval_ms
      store(new)
      cb(true)
    end)
  end)
  if not ok then vim.schedule(function() cb(false, 'command not found') end) end
end

---Stop polling. The map stays; it stops counting (`fresh`) two intervals after the last poll.
function M.stop()
  generation = generation + 1
  running = false
  interval = nil
  if timer then
    timer:stop()
    if not timer:is_closing() then timer:close() end
    timer = nil
  end
end

-- Test only: stop polling, clear the map and the notice flag.
function M._reset()
  M.stop()
  map = {}
  notified = false
  refreshed_at, stale_after = nil, nil
end

return M
