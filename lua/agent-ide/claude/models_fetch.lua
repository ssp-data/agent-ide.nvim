-- Ask Claude Code for its model list without a session: a one-off
-- `claude -p --verbose --input-format stream-json --output-format stream-json` child in a temp
-- folder that gets only the `initialize` request (no prompt, no turn, no usage). Once the answer
-- is in (or after TIMEOUT), stdin is closed and Claude exits on EOF; a child still running
-- KILL_AFTER later is sent SIGTERM (it is ours). At most one such child runs at a time.
local M = {}

M._timeout_ms = 10000
M._kill_ms = 5000

local FLAGS = { '-p', '--verbose', '--input-format', 'stream-json', '--output-format', 'stream-json',
  '--no-session-persistence' }
local REQUEST_ID = 'models1'

local running -- { handle, cbs, done, exited } of the fetch in flight
local children = {} -- run -> true until its child exited (also after its answer)
local augroup

---Fetch the list; `cb(list|nil, claude_version|nil)` on the main loop. The list (normalized,
---see claude/models.lua) is also recorded as the latest list. Joins a fetch in flight.
---@param cb? fun(list: table[]|nil, version: string|nil)
function M.fetch(cb)
  if running then
    if cb then table.insert(running.cbs, cb) end
    return
  end
  local cfg = require('agent-ide.config').get().claude
  local run = { cbs = { cb }, done = false }
  running = run
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p', 448)

  local function finish(list, version)
    if run.done then return end
    run.done = true
    if running == run then running = nil end
    if list then require('agent-ide.claude.models').record(list, version) end
    if run.handle then
      pcall(run.handle.write, run.handle, nil) -- EOF: Claude exits by itself
      vim.defer_fn(function()
        if not run.exited then pcall(run.handle.kill, run.handle, 15) end
      end, M._kill_ms)
    end
    for _, f in ipairs(run.cbs) do pcall(f, list, version) end
  end

  local DECODE_OPTS = require('agent-ide.transcript.parse').DECODE_OPTS
  local splitter = require('agent-ide.util.lines').splitter()
  local function on_line(line)
    if run.done then return end
    local ok, obj = pcall(vim.json.decode, line, DECODE_OPTS)
    if not ok or type(obj) ~= 'table' or obj.type ~= 'control_response' then return end
    local r = obj.response
    if type(r) ~= 'table' or r.request_id ~= REQUEST_ID then return end
    local answer = r.subtype == 'success' and type(r.response) == 'table' and r.response or {}
    local models = require('agent-ide.claude.models')
    finish(models.normalize(answer.models), type(answer.claude_code_version) == 'string' and answer.claude_code_version or nil)
  end

  local argv = vim.deepcopy(cfg.cmd)
  vim.list_extend(argv, FLAGS)
  local env = require('agent-ide.claude.process').child_env()
  local ok, handle = pcall(vim.system, argv, {
    cwd = dir, stdin = true, env = env, clear_env = env ~= nil,
    stdout = vim.schedule_wrap(function(err, data)
      if err or not data then return end
      splitter:push(data, on_line)
    end),
  }, vim.schedule_wrap(function()
    run.exited = true
    children[run] = nil
    vim.fn.delete(dir, 'rf')
    finish(nil)
  end))
  if not ok then
    vim.fn.delete(dir, 'rf')
    return vim.schedule(function() finish(nil) end)
  end
  run.handle = handle
  children[run] = true
  pcall(handle.write, handle, vim.json.encode({ type = 'control_request', request_id = REQUEST_ID,
    request = { subtype = 'initialize' } }) .. '\n')
  vim.defer_fn(function() finish(nil) end, M._timeout_ms)
  if not augroup then
    augroup = vim.api.nvim_create_augroup('agent-ide.claude.models_fetch', { clear = true })
    vim.api.nvim_create_autocmd('VimLeavePre', { group = augroup, callback = function()
      for r in pairs(children) do pcall(r.handle.kill, r.handle, 15) end
    end })
  end
end

---A fetch is in flight.
---@return boolean
function M.busy() return running ~= nil end

return M
