-- The Neovim side of a keeper (lua/agent-ide/keeper/main.lua): a socket connection with the
-- interface of a direct Claude process (`send`, `stop`, `alive`, `handle.pid`), so a Session
-- drives both the same way. Lines from the keeper (the replay, then live) reach the handlers in
-- batches of BATCH per tick, so a long replay never blocks the editor. Sends made before the
-- socket is up are kept and written in order once attached.
local api = vim.api
local lines = require('agent-ide.util.lines')

local M = {}

M.BATCH = 200
M.CONNECT_MS = 8000 -- how long a fresh keeper may take to come up
M.DETACH_WAIT_MS = 3000 -- at quit: how long to wait for a keeper that is still coming up

local Client = {}
Client.__index = Client

---@return boolean
function Client:alive() return not self.exited end

---Write one JSON object to Claude (through the keeper).
---@param obj table
---@return boolean
function Client:send(obj)
  if self.exited or self.closed then return false end
  local ok, text = pcall(vim.json.encode, obj)
  if not ok then return false end
  return self:_op({ op = 'send', line = text })
end

function Client:_op(msg)
  local line = vim.json.encode(msg) .. '\n'
  if not self.attached then
    self.pending[#self.pending + 1] = line
    return true
  end
  return pcall(self.pipe.write, self.pipe, line)
end

---Hand over the queued prompts (the keeper sends them at the end of a turn while nobody is attached).
---@param items string[]
function Client:queue(items) self:_op({ op = 'queue', items = items }) end

---End Claude: close its stdin, SIGTERM after the keeper's grace period (`now`: at once).
---@param cb? fun()
---@param now? boolean
function Client:stop(cb, now)
  if self.exited then
    if cb then vim.schedule(cb) end
    return
  end
  if cb then table.insert(self.stop_cbs, cb) end
  self.closed = true
  self:_op({ op = 'stop', now = now == true })
end

---Leave Claude running under the keeper; `items`: the prompts still queued here. Called while
---Neovim quits: a keeper still coming up is waited for (at most DETACH_WAIT_MS), and the lines
---are flushed before the socket closes, so nothing sent just before the quit is lost.
---@param items? string[]
function Client:detach(items)
  if self.detached then return end
  if not self.synced and not self.exited then
    vim.wait(M.DETACH_WAIT_MS, function() return self.synced or self.exited end, 10)
  end
  self.detached = true -- only now: the connect retries stop at this flag
  if self.exited then return self:_close() end
  if not self.synced then return self:_close() end
  for _, l in ipairs(self.pending) do pcall(self.pipe.write, self.pipe, l) end
  self.pending = {}
  if items and #items > 0 then self:queue(items) end
  local written = false
  pcall(self.pipe.write, self.pipe, vim.json.encode({ op = 'detach' }) .. '\n', function() written = true end)
  vim.wait(1000, function() return written end, 5)
  self:_close()
end

function Client:_close()
  if self.pipe and not self.pipe:is_closing() then
    pcall(self.pipe.read_stop, self.pipe)
    self.pipe:close()
  end
end

-- Messages are handled on the main loop, `BATCH` per tick.
function Client:_pump()
  if self.pumping then return end
  self.pumping = true
  local n = 0
  while #self.inbox > 0 and n < M.BATCH do
    local msg = table.remove(self.inbox, 1)
    n = n + 1
    self:_handle(msg)
  end
  self.pumping = false
  if #self.inbox > 0 then vim.schedule(function() self:_pump() end) end
end

function Client:_handle(msg)
  local h = self.handlers
  if msg.op == 'hello' then
    self.attached = true
    self.handle = { pid = msg.claude_pid }
    if h.on_hello then h.on_hello(msg) end
  elseif msg.op == 'line' then
    if h.on_line then h.on_line(msg.dir, msg.line, not self.synced) end
  elseif msg.op == 'synced' then
    self.synced = true
    for _, l in ipairs(self.pending) do pcall(self.pipe.write, self.pipe, l) end
    self.pending = {}
    if h.on_synced then h.on_synced() end
  elseif msg.op == 'busy' then
    self.exited = true
    self:_close()
    if h.on_busy then h.on_busy() end
  elseif msg.op == 'exit' then
    if self.handled_exit then return end
    self.handled_exit, self.exited = true, true
    self:_close()
    if h.on_exit then h.on_exit(msg.code, msg.signal, msg.stderr or '') end
    for _, cb in ipairs(self.stop_cbs) do pcall(cb) end
    self.stop_cbs = {}
  elseif msg.op == 'lost' then
    if self.exited then return end
    self.exited = true
    self:_close()
    if h.on_lost then h.on_lost() end
    for _, cb in ipairs(self.stop_cbs) do pcall(cb) end
    self.stop_cbs = {}
  end
end

-- Runs in the socket's read callback (no editor calls): the messages go to the inbox, and the
-- `attached` / `synced` flags are set at once, so a quit that waits for them (`detach`) does not
-- depend on scheduled callbacks, which Neovim no longer runs while leaving.
function Client:_receive(data)
  self.splitter:push(data, function(line)
    if line:find('^%s*$') then return end
    local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(msg) == 'table' then
      if msg.op == 'hello' then
        self.attached = true
        self.handle = { pid = msg.claude_pid }
      elseif msg.op == 'synced' then
        self.synced = true
      end
      self.inbox[#self.inbox + 1] = msg
    end
  end)
  vim.schedule(function() self:_pump() end)
end

---Connect to the keeper at `sock` and attach. `handlers`: `on_hello(info)`, `on_line(dir, line,
---replay)`, `on_synced()`, `on_busy()` (another client drives it), `on_exit(code, signal,
---stderr)`, `on_lost()` (the keeper went away without an exit). `wait`: keep trying for that
---long while the socket does not exist yet (a keeper starting up).
---@param sock string
---@param handlers table
---@param wait? integer ms
---@return table client
function M.connect(sock, handlers, wait)
  local self = setmetatable({ sock = sock, handlers = handlers, pending = {}, inbox = {}, stop_cbs = {},
    splitter = lines.splitter(), attached = false, synced = false, exited = false, closed = false, keeper = true,
    handle = { pid = nil } }, Client)
  local deadline = vim.uv.now() + (wait or 0)
  local function try()
    if self.detached or self.exited then return end
    local pipe = vim.uv.new_pipe(false)
    self.pipe = pipe
    pipe:connect(sock, function(err)
      if err then
        if not pipe:is_closing() then pipe:close() end
        -- the retry stays in libuv callbacks (no scheduler): a quit waits for it with vim.wait
        if vim.uv.now() < deadline then
          local t = vim.uv.new_timer()
          t:start(50, 0, function() t:close(); try() end)
        else
          self.exited = true
          self.inbox[#self.inbox + 1] = { op = 'exit', code = -1, signal = 0, stderr = 'cannot reach the keeper: ' .. tostring(err) }
          vim.schedule(function() self:_pump() end)
        end
        return
      end
      pipe:read_start(function(rerr, data)
        if rerr or not data then
          if not self.detached then
            self.inbox[#self.inbox + 1] = { op = 'lost' }
            vim.schedule(function() self:_pump() end)
          end
          return
        end
        self:_receive(data)
      end)
      pipe:write(vim.json.encode({ op = 'attach' }) .. '\n')
    end)
  end
  try()
  return self
end

M._Client = Client
return M
