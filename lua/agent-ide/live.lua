-- Live session state: polls `claude agents --json` asynchronously.
-- Read-only: never signals or stops any process.
local M = {}

local RANK = { waiting = 4, busy = 3, idle = 2, parked = 1 }
local PASSTHROUGH = { busy = true, waiting = true, idle = true }

local map = {}
local timer = nil
local generation = 0 -- bumped by stop(); results from older generations are dropped
local running = false -- a command run is still in flight
local notified = false -- one failure notice per Neovim session

---@param text string
---@return table<string, { status: string, pid: integer, cwd: string, name: string|nil }>
function M.parse(text)
  local ok, data = pcall(vim.json.decode, text or '', { luanil = { object = true, array = true } })
  if not ok or type(data) ~= 'table' or not vim.islist(data) then return {} end
  local out = {}
  for _, e in ipairs(data) do
    if type(e) == 'table' and type(e.sessionId) == 'string' then
      out[e.sessionId] = { status = e.status, pid = e.pid, cwd = e.cwd, name = e.name }
    end
  end
  return out
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

function M.get() return map end

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
    if not vim.deep_equal(new, map) then
      map = new
      if opts.on_change then opts.on_change(map) end
    end
    if opts.on_poll then opts.on_poll(map) end
  end
  running = true
  -- a hung command is killed after the timeout, so polling never stalls
  local ok = pcall(vim.system, opts.cmd, { text = true, timeout = opts.timeout_ms }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        finish({}, 'exit code ' .. tostring(res.code))
      else
        finish(M.parse(res.stdout))
      end
    end)
  end)
  if not ok then finish({}, 'command not found') end
end

---`on_change` runs when the map changed, `on_poll` after every finished poll.
---@param opts { interval_ms: integer, cmd?: string[], timeout_ms?: integer, on_change?: fun(map: table), on_poll?: fun(map: table) }
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
  timer = vim.uv.new_timer()
  timer:start(opts.interval_ms, opts.interval_ms, vim.schedule_wrap(tick))
  tick()
end

---@return boolean polling
function M.active() return timer ~= nil end

function M.stop()
  generation = generation + 1
  running = false
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
end

return M
