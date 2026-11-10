-- Client for the `agent-ide-helper` process: one JSON object per line over stdin/stdout.
-- The process starts lazily on first request. Everything is asynchronous; failures are
-- reported to callers as error strings, and the caller decides what to do about them.
local M = {}

M._timeout_ms = 5000 -- tests shorten it
-- Error given to requests when the helper follows other parse/scan rules than this plugin
-- (`hello` reports another `rules_version`, or does not exist in an old binary).
M.OUT_OF_DATE = 'out of date'
local OUTDATED_NOTICE = 'Agent-IDE: the helper is out of date; run `make helper`'
M._grace_ms = 500 -- after closing stdin, wait this long before SIGTERM

local lines = require('agent-ide.util.lines')
local state = { proc = nil, cur = nil, exit_fns = {}, gen = 0, next_id = 1, pending = {}, lines = lines.splitter(), handlers = {},
  outdated = false }
local augroup

local DECODE_OPTS = require('agent-ide.transcript.parse').DECODE_OPTS

---@return string
function M.path()
  local p = require('agent-ide.config').get().helper.path
  if p and p ~= '' then return vim.fn.expand(p) end
  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h:h')
  return root .. '/helper/target/release/agent-ide-helper'
end

---@return boolean
function M.available()
  if state.outdated then return false end
  local p = M.path()
  local st = vim.uv.fs_stat(p)
  return st ~= nil and st.type == 'file' and vim.uv.fs_access(p, 'X') == true
end

local function finish(entry, err, result)
  if entry.timer then
    entry.timer:stop()
    if not entry.timer:is_closing() then entry.timer:close() end
    entry.timer = nil
  end
  pcall(entry.cb, err, result)
end

--- Answer every pending request with `err`.
local function fail_all(err)
  local list = state.pending
  state.pending = {}
  for _, entry in pairs(list) do finish(entry, err) end
end

local function handle_line(line)
  if line == '' then return end
  local ok, msg = pcall(vim.json.decode, line, DECODE_OPTS)
  if not ok or type(msg) ~= 'table' then return end
  if msg.id ~= nil then
    local entry = state.pending[msg.id]
    if not entry then return end
    state.pending[msg.id] = nil
    if msg.error ~= nil then
      finish(entry, type(msg.error) == 'table' and msg.error.message or tostring(msg.error))
    else
      finish(entry, nil, msg.result or {})
    end
  elseif type(msg.method) == 'string' then
    for _, fn in ipairs(state.handlers[msg.method] or {}) do pcall(fn, msg.params or {}) end
  end
end

local function on_stdout(gen)
  return vim.schedule_wrap(function(err, data)
    if gen ~= state.gen or err or not data then return end
    state.lines:push(data, function(line)
      handle_line(line)
      return gen ~= state.gen -- a handler stopped the helper
    end)
  end)
end

---@return boolean ok
local function start()
  if state.proc then return true end
  local cache = vim.fn.stdpath('cache') .. '/agent-ide'
  pcall(vim.fn.mkdir, cache, 'p')
  state.gen = state.gen + 1
  local gen = state.gen
  local cur = { exited = false }
  state.cur = cur
  state.lines:reset()
  local ok, proc = pcall(vim.system, { M.path(), '--cache-dir', cache }, {
    stdin = true, stdout = on_stdout(gen), stderr = false,
  }, vim.schedule_wrap(function(obj)
    cur.exited = true
    if gen ~= state.gen then return end -- stopped on purpose
    state.proc = nil
    local reason = 'process exited (' .. tostring(obj.signal ~= 0 and ('signal ' .. obj.signal) or ('code ' .. obj.code)) .. ')'
    fail_all(reason)
    for _, fn in ipairs(state.exit_fns) do pcall(fn, reason) end
  end))
  if not ok then
    state.gen = state.gen + 1
    return false, tostring(proc)
  end
  state.proc = proc
  M._hello(gen)
  if not augroup then
    augroup = vim.api.nvim_create_augroup('agent-ide.helper', { clear = true })
    vim.api.nvim_create_autocmd('VimLeavePre', { group = augroup, callback = function() M.stop(true) end })
  end
  return true
end

local send

---First request of every helper process: its rules must be this plugin's. A helper that answers
---with another `rules_version`, or with an error (an old binary without `hello`), is out of date:
---it is stopped and not used again in this Neovim, and requests get `M.OUT_OF_DATE`. No answer
---(timeout, exit) is left to the requests' own failure handling.
function M._hello(gen)
  send('hello', {}, function(err, result)
    if gen ~= state.gen then return end
    if err == 'timeout' or err == 'stopped' or (err and err:match('^process exited')) then return end
    local want = require('agent-ide.transcript.parse').RULES_VERSION
    if not err and type(result) == 'table' and result.rules_version == want then return end
    state.outdated = true
    vim.notify(OUTDATED_NOTICE, vim.log.levels.WARN)
    fail_all(M.OUT_OF_DATE)
    M.stop(true)
  end)
end

---@param method string
---@param params table
---@param cb fun(err: string|nil, result: table|nil)
function M.request(method, params, cb)
  if state.outdated then return vim.schedule(function() cb(M.OUT_OF_DATE) end) end
  local ok, why = start()
  if not ok then
    vim.schedule(function() cb('cannot start helper: ' .. tostring(why)) end)
    return
  end
  send(method, params, cb)
end

-- Write one request to the running process.
function send(method, params, cb)
  local id = state.next_id
  state.next_id = id + 1
  local entry = { cb = cb, timer = vim.uv.new_timer() }
  state.pending[id] = entry
  entry.timer:start(M._timeout_ms, 0, vim.schedule_wrap(function()
    if state.pending[id] ~= entry then return end
    state.pending[id] = nil
    finish(entry, 'timeout')
  end))
  local line = vim.json.encode({ id = id, method = method, params = params }) .. '\n'
  local wok, werr = pcall(state.proc.write, state.proc, line, function(err)
    if err then
      vim.schedule(function()
        if state.pending[id] ~= entry then return end
        state.pending[id] = nil
        finish(entry, 'write failed: ' .. tostring(err))
      end)
    end
  end)
  if not wok then
    state.pending[id] = nil
    vim.schedule(function() finish(entry, 'write failed: ' .. tostring(werr)) end)
  end
end

---Register a handler for notifications (messages without `id`), e.g. `changed`.
---@param method string
---@param fn fun(params: table)
function M.on(method, fn)
  state.handlers[method] = state.handlers[method] or {}
  table.insert(state.handlers[method], fn)
end

---Register a handler for an unexpected process exit (not caused by `stop`), after pending requests were answered.
---@param fn fun(reason: string)
function M.on_exit(fn) table.insert(state.exit_fns, fn) end

---@return boolean
function M.running() return state.proc ~= nil end

---Close the helper's stdin so it exits; pending requests are answered with 'stopped'. Idempotent.
---A process still alive after the grace period (or at once with `now`) gets SIGTERM.
---@param now? boolean
function M.stop(now)
  local proc, cur = state.proc, state.cur
  if not proc then return end
  state.proc = nil
  state.cur = nil
  state.gen = state.gen + 1
  state.lines:reset()
  pcall(proc.write, proc, nil)
  local function terminate() if not cur.exited then pcall(proc.kill, proc, 15) end end
  if now then
    terminate()
  else
    vim.defer_fn(terminate, M._grace_ms)
  end
  fail_all('stopped')
end

---Test-only: kill the process, forget handlers and pending requests.
function M._reset()
  local proc = state.proc
  M.stop()
  if proc then pcall(proc.kill, proc, 15) end
  state.handlers = {}
  state.exit_fns = {}
  state.pending = {}
  state.next_id = 1
  state.outdated = false
  M._timeout_ms = 5000
  M._grace_ms = 500
end

return M
