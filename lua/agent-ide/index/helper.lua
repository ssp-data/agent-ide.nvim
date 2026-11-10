-- Client for the `agent-ide-helper` process: one JSON object per line over stdin/stdout.
-- The process starts lazily on first request. Everything is asynchronous; failures are
-- reported to callers as error strings, and the caller decides what to do about them.
local M = {}

M._timeout_ms = 5000 -- tests shorten it

local state = { proc = nil, gen = 0, next_id = 1, pending = {}, buf = '', handlers = {} }
local augroup

local DECODE_OPTS = { luanil = { object = true, array = true } }

---@return string
function M.path()
  local p = require('agent-ide.config').get().helper.path
  if p and p ~= '' then return vim.fn.expand(p) end
  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h:h')
  return root .. '/helper/target/release/agent-ide-helper'
end

---@return boolean
function M.available()
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
    state.buf = state.buf .. data
    while true do
      local nl = state.buf:find('\n', 1, true)
      if not nl then break end
      local line = state.buf:sub(1, nl - 1)
      state.buf = state.buf:sub(nl + 1)
      handle_line(line)
    end
  end)
end

---@return boolean ok
local function start()
  if state.proc then return true end
  local cache = vim.fn.stdpath('cache') .. '/agent-ide'
  pcall(vim.fn.mkdir, cache, 'p')
  state.gen = state.gen + 1
  local gen = state.gen
  state.buf = ''
  local ok, proc = pcall(vim.system, { M.path(), '--cache-dir', cache }, {
    stdin = true, stdout = on_stdout(gen), stderr = false,
  }, vim.schedule_wrap(function(obj)
    if gen ~= state.gen then return end -- stopped on purpose
    state.proc = nil
    fail_all('process exited (' .. tostring(obj.signal ~= 0 and ('signal ' .. obj.signal) or ('code ' .. obj.code)) .. ')')
  end))
  if not ok then
    state.gen = state.gen + 1
    return false, tostring(proc)
  end
  state.proc = proc
  if not augroup then
    augroup = vim.api.nvim_create_augroup('agent-ide.helper', { clear = true })
    vim.api.nvim_create_autocmd('VimLeavePre', { group = augroup, callback = function() M.stop() end })
  end
  return true
end

---@param method string
---@param params table
---@param cb fun(err: string|nil, result: table|nil)
function M.request(method, params, cb)
  local ok, why = start()
  if not ok then
    vim.schedule(function() cb('cannot start helper: ' .. tostring(why)) end)
    return
  end
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

---Close the helper's stdin so it exits; pending requests are answered with 'stopped'. Idempotent.
function M.stop()
  local proc = state.proc
  if not proc then return end
  state.proc = nil
  state.gen = state.gen + 1
  state.buf = ''
  pcall(proc.write, proc, nil)
  fail_all('stopped')
end

---Test-only: kill the process, forget handlers and pending requests.
function M._reset()
  local proc = state.proc
  M.stop()
  if proc then pcall(proc.kill, proc, 15) end
  state.handlers = {}
  state.pending = {}
  state.next_id = 1
  M._timeout_ms = 5000
end

return M
