-- JSON-RPC 2.0 over the stdio of one agent process (the Agent Client Protocol's transport):
-- requests we send (answered by id, with a timeout), notifications we send, requests and
-- notifications the agent sends (dispatched by method; an unknown request is answered with
-- "method not found"), and the process itself (spawn, stop as claude/process.lua does). No
-- protocol knowledge beyond JSON-RPC lives here. All callbacks run on the main loop, in
-- arrival order; every line sent or received goes to `on_raw`.
local lines = require('agent-ide.util.lines')

local M = {}

M._grace_ms = 500 -- after closing stdin, wait this long before SIGTERM
M.TIMEOUT_MS = 60000 -- default for a request with no timeout of its own
local STDERR_KEEP = 2048
local DECODE_OPTS = require('agent-ide.transcript.parse').DECODE_OPTS

local Client = {}
Client.__index = Client

---@return boolean
function Client:alive() return not self.exited end

local function guard(self, fn, ...)
  if not fn then return end
  local ok, e = pcall(fn, ...)
  if not ok and not self.warned then
    self.warned = true
    vim.notify('agent-ide: error in agent callback: ' .. tostring(e), vim.log.levels.WARN)
  end
end

---Write one JSON-RPC object. False when the process is gone (or stdin is closed).
function Client:_send(msg)
  if self.exited or self.closed then return false end
  msg.jsonrpc = '2.0'
  local ok, text = pcall(vim.json.encode, msg)
  if not ok then return false end
  local wok = pcall(self.handle.write, self.handle, text .. '\n')
  if wok then guard(self, self.opts.on_raw, 'out', text) end
  return wok
end

---Send a request; `cb(err, result)` once, with `err = { code, message, data? }` on a JSON-RPC
---error, `{ code = 'timeout' }` after `timeout_ms` (nil: the client's default; false: never),
---`{ code = 'exit' }` when the process ends first. False when nothing could be sent.
---@param method string
---@param params table|nil
---@param cb fun(err: table|nil, result: any)
---@param timeout_ms? integer|false
---@return boolean sent
function Client:request(method, params, cb, timeout_ms)
  if self.exited or self.closed then return false end
  self.next_id = self.next_id + 1
  local id = self.next_id
  if not self:_send({ id = id, method = method, params = params }) then return false end
  local p = { cb = cb }
  self.pending[id] = p
  local ms = timeout_ms == nil and (self.opts.timeout_ms or M.TIMEOUT_MS) or timeout_ms
  if ms then
    p.timer = vim.uv.new_timer()
    p.timer:start(ms, 0, vim.schedule_wrap(function()
      if self.pending[id] ~= p then return end
      self:_settle(id, { code = 'timeout', message = ('%s: no answer within %d ms'):format(method, ms) })
    end))
  end
  return true
end

---Send a notification (no answer expected).
---@param method string
---@param params table|nil
---@return boolean sent
function Client:notify(method, params) return self:_send({ method = method, params = params }) end

function Client:_respond(id, result, err)
  local msg = { id = id }
  if err then msg.error = err else msg.result = result == nil and vim.empty_dict() or result end
  return self:_send(msg)
end

---Handle requests of the agent for `method`: `fn(params, respond)`, where `respond(result)` or
---`respond(nil, { code, message })` answers (once).
function Client:on_request(method, fn) self.req_handlers[method] = fn end

---Handle notifications of the agent for `method`: `fn(params)`.
function Client:on_notification(method, fn) self.notif_handlers[method] = fn end

---See every message no handler took: unknown requests (already answered with -32601),
---unknown notifications, responses to nothing pending.
function Client:on_unhandled(fn) self.unhandled = fn end

-- Deliver the answer of request `id` once and forget it.
function Client:_settle(id, err, result)
  local p = self.pending[id]
  if not p then return false end
  self.pending[id] = nil
  if p.timer then
    p.timer:stop()
    if not p.timer:is_closing() then p.timer:close() end
  end
  guard(self, p.cb, err, result)
  return true
end

function Client:_dispatch(msg)
  if msg.method ~= nil then
    if msg.id ~= nil then
      local h = self.req_handlers[msg.method]
      if not h then
        self:_respond(msg.id, nil, { code = -32601, message = 'Method not found: ' .. tostring(msg.method) })
        return guard(self, self.unhandled, msg)
      end
      local answered = false
      local id = msg.id
      return guard(self, h, msg.params, function(result, err)
        if answered then return end
        answered = true
        self:_respond(id, result, err)
      end)
    end
    local h = self.notif_handlers[msg.method]
    if h then return guard(self, h, msg.params) end
    return guard(self, self.unhandled, msg)
  end
  if msg.id ~= nil and self:_settle(msg.id, msg.error, msg.result) then return end
  guard(self, self.unhandled, msg)
end

function Client:_line(line)
  if line:find('^%s*$') then return end
  guard(self, self.opts.on_raw, 'in', line)
  local ok, msg = pcall(vim.json.decode, line, DECODE_OPTS)
  if ok and type(msg) == 'table' and (msg.method ~= nil or msg.id ~= nil) then
    self:_dispatch(msg)
  else
    guard(self, self.opts.on_garbage, line)
  end
end

---Close stdin; SIGTERM after the grace period if still alive. `cb` runs after exit. Safe to repeat.
---@param cb? fun()
---@param now? boolean SIGTERM at once instead of after the grace period
function Client:stop(cb, now)
  if self.exited then
    if cb then vim.schedule(cb) end
    return
  end
  if cb then table.insert(self.stop_cbs, cb) end
  if not self.closed then
    self.closed = true
    pcall(self.handle.write, self.handle, nil)
  end
  local function terminate() if not self.exited then pcall(self.handle.kill, self.handle, 15) end end
  if now then
    terminate()
  elseif not self.stopping then
    vim.defer_fn(terminate, M._grace_ms)
  end
  self.stopping = true
end

---Start the agent `cmd` (argv). `opts`: `cwd`, `env` (a full environment, nil to inherit),
---`on_raw(dir, line)`, `on_garbage(line)`, `on_exit(code, signal, stderr_tail)`, `timeout_ms`.
---@param cmd string[]
---@param opts table
---@return table|nil client, string|nil err
function M.start(cmd, opts)
  opts = opts or {}
  if type(cmd) ~= 'table' or type(cmd[1]) ~= 'string' then return nil, 'no command' end
  if vim.fn.executable(cmd[1]) ~= 1 then return nil, 'not executable: ' .. tostring(cmd[1]) end
  local self = setmetatable({ opts = opts, exited = false, closed = false, stop_cbs = {}, next_id = 0, pending = {},
    req_handlers = {}, notif_handlers = {} }, Client)
  local splitter = lines.splitter()
  local err_chunks, err_len = {}, 0
  -- what the agent wrote to stderr so far (the last STDERR_KEEP bytes): its own notices
  self.stderr_tail = function() return table.concat(err_chunks):sub(-STDERR_KEEP) end
  local ok, handle = pcall(vim.system, cmd, {
    cwd = opts.cwd, stdin = true, env = opts.env, clear_env = opts.env ~= nil,
    stdout = vim.schedule_wrap(function(err, data)
      if err or not data then return end
      splitter:push(data, function(line) self:_line(line) end)
    end),
    stderr = function(err, data)
      if err or not data then return end
      err_chunks[#err_chunks + 1] = data
      err_len = err_len + #data
      if err_len > 4 * STDERR_KEEP then -- compact now and then so memory stays bounded
        local all = table.concat(err_chunks):sub(-STDERR_KEEP)
        err_chunks, err_len = { all }, #all
      end
    end,
  }, function(obj)
    self.exited = true
    vim.schedule(function()
      local rest = splitter:take_rest()
      if rest then self:_line(rest) end
      local tail = table.concat(err_chunks):sub(-STDERR_KEEP)
      -- requests in flight die with the process, each told once
      local ids = vim.tbl_keys(self.pending)
      table.sort(ids)
      for _, id in ipairs(ids) do
        self:_settle(id, { code = 'exit', message = ('agent exited (code %s)'):format(tostring(obj.code)) })
      end
      guard(self, opts.on_exit, obj.code, obj.signal, tail)
      for _, cb in ipairs(self.stop_cbs) do guard(self, cb) end
      self.stop_cbs = {}
    end)
  end)
  if not ok then return nil, tostring(handle) end
  self.handle = handle
  self.pid = handle.pid
  return self
end

M._Client = Client
return M
