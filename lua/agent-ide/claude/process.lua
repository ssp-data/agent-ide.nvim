-- Wrapper around one long-lived `claude -p` child process speaking line-delimited JSON.
-- Spawn, send a line, receive decoded objects, stop. No protocol knowledge lives here.
-- All callbacks run on the main loop, in arrival order.
local M = {}

M._grace_ms = 500 -- after closing stdin, wait this long before SIGTERM
local STDERR_KEEP = 2048

local DECODE_OPTS = require('agent-ide.transcript.parse').DECODE_OPTS
local lines = require('agent-ide.util.lines')

local FIXED = {
  '-p', '--verbose', '--input-format', 'stream-json', '--output-format', 'stream-json',
  '--include-partial-messages', '--replay-user-messages',
  '--permission-prompts', 'host', '--permission-prompt-tool', 'stdio',
}

local live = {} -- proc -> true, every process started here that has not exited yet
local augroup

---Full argv: configured command, fixed flags, optional model (new and resumed sessions), session flag.
---@param opts { session_id: string, resume?: boolean, model?: string }
---@return string[]
function M.args(opts)
  local argv = vim.deepcopy(require('agent-ide.config').get().claude.cmd)
  vim.list_extend(argv, FIXED)
  if opts.model then vim.list_extend(argv, { '--model', opts.model }) end
  vim.list_extend(argv, { opts.resume and '--resume' or '--session-id', opts.session_id })
  return argv
end

---@return table|nil env  a full environment without the API key, or nil to inherit as is
function M.child_env()
  if not require('agent-ide.config').get().claude.strip_api_key then return nil end
  local env = vim.fn.environ()
  env.ANTHROPIC_API_KEY = nil
  return env
end

local Proc = {}
Proc.__index = Proc

---@return boolean
function Proc:alive() return not self.exited end

---Write one JSON line. False when the process is not alive (or stdin is closed).
---@param obj table
---@return boolean
function Proc:send(obj)
  if self.exited or self.closed then return false end
  local ok, text = pcall(vim.json.encode, obj)
  if not ok then return false end
  local wok = pcall(self.handle.write, self.handle, text .. '\n')
  return wok
end

---Close stdin; SIGTERM after the grace period if still alive. `cb` runs after exit. Safe to repeat.
---@param cb? fun()
---@param now? boolean SIGTERM at once instead of after the grace period
function Proc:stop(cb, now)
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

local function make_guard()
  local warned = false
  return function(fn, ...)
    if not fn then return end
    local ok, e = pcall(fn, ...)
    if not ok and not warned then
      warned = true
      vim.notify('agent-ide: error in Claude callback: ' .. tostring(e), vim.log.levels.WARN)
    end
  end
end

local function line_handler(opts, guarded)
  return function(line)
    if line:find('^%s*$') then return end
    local ok, obj = pcall(vim.json.decode, line, DECODE_OPTS)
    if ok and type(obj) == 'table' then
      guarded(opts.on_object, obj, line)
    else
      guarded(opts.on_garbage, line)
    end
  end
end

local function watch_exit()
  if augroup then return end
  augroup = vim.api.nvim_create_augroup('agent-ide.claude.process', { clear = true })
  -- quitting: a Claude under a keeper stays (its queue handed over), a child is stopped
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    callback = function()
      for p in pairs(live) do
        if p.keeper then p:detach(p.queue_source and p.queue_source() or nil) else p:stop(nil, true) end
      end
    end,
  })
end

-- Start through a keeper (lua/agent-ide/keeper): the client has this module's interface.
local function start_kept(opts, guarded, handle_line)
  local keeper = require('agent-ide.keeper')
  local argv = M.args(opts)
  -- the keeper would report a missing program only later: say it now, as the direct start does
  if vim.fn.executable(argv[1]) ~= 1 then return nil, 'not executable: ' .. tostring(argv[1]) end
  local client
  client = keeper.start({ session_id = opts.session_id, cwd = opts.cwd, path = opts.path, argv = argv,
    env = M.child_env() }, {
    on_hello = function(h) guarded(opts.on_pid, h.claude_pid) end,
    on_line = function(dir, line) if dir == 'out' then handle_line(line) end end,
    on_exit = function(code, signal, tail)
      live[client] = nil
      keeper.forget(opts.session_id)
      guarded(opts.on_exit, code, signal, tail)
    end,
    on_lost = function()
      live[client] = nil
      keeper.forget(opts.session_id)
      guarded(opts.on_exit, nil, nil, 'keeper lost')
    end,
  })
  if client then live[client] = true end
  return client
end

---@param opts { cwd?: string, session_id: string, resume?: boolean, model?: string, path?: string, on_object?: fun(obj: table, raw: string), on_garbage?: fun(line: string), on_exit?: fun(code: integer, signal: integer, stderr_tail: string), on_pid?: fun(pid: integer) }
---@return table|nil proc, string|nil err
function M.start(opts)
  local guarded = make_guard()
  local handle_line = line_handler(opts, guarded)
  watch_exit()
  if require('agent-ide.keeper').enabled() then return start_kept(opts, guarded, handle_line) end
  local self = setmetatable({ exited = false, closed = false, stop_cbs = {} }, Proc)
  local splitter = lines.splitter()
  local err_chunks, err_len = {}, 0

  local env = M.child_env()
  local ok, handle = pcall(vim.system, M.args(opts), {
    cwd = opts.cwd, stdin = true, env = env, clear_env = env ~= nil,
    stdout = vim.schedule_wrap(function(err, data)
      if err or not data then return end
      splitter:push(data, function(line) handle_line(line) end)
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
      live[self] = nil
      local rest = splitter:take_rest()
      if rest then handle_line(rest) end
      local tail = table.concat(err_chunks):sub(-STDERR_KEEP)
      guarded(opts.on_exit, obj.code, obj.signal, tail)
      for _, cb in ipairs(self.stop_cbs) do guarded(cb) end
      self.stop_cbs = {}
    end)
  end)
  if not ok then return nil, tostring(handle) end
  self.handle = handle
  live[self] = true
  return self
end

---Register a process started elsewhere (a keeper reattached to) for the quit hand-over.
---@param proc table
function M.track(proc) live[proc] = true end
function M.untrack(proc) live[proc] = nil end

return M
