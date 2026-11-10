-- Keepers (lua/agent-ide/keeper/main.lua): starting one for a new Claude process, finding the
-- ones that run (their json files in the runtime folder), attaching to them. A keeper's Claude
-- is the plugin's own process, however many Neovims came and went.
local rundir = require('agent-ide.util.rundir')
local client = require('agent-ide.keeper.client')

local M = {}

local known = {} ---@type table<string, table> session id -> info (the json file's content)
local main = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/main.lua'

local function cfg()
  local k = require('agent-ide.config').get().keeper
  return type(k) == 'table' and k or {}
end

---Keepers are on: the setting, and this Neovim's binary can run the keeper script.
---@return boolean
function M.enabled()
  local k = cfg()
  return k.enabled ~= false and type(vim.v.progpath) == 'string' and vim.v.progpath ~= ''
end

function M.dir() return rundir.dir() end

function M.json_path(id) return M.dir() .. '/keeper-' .. id .. '.json' end
function M.sock_path(id) return M.dir() .. '/keeper-' .. id .. '.sock' end

local function pid_alive(pid)
  return type(pid) == 'number' and pid > 0 and vim.uv.kill(pid, 0) == 0
end

---Start a keeper for `opts` (as `claude/process.start` gets them: `argv`, `cwd`, `session_id`,
---`path`, `env`) and attach; `handlers` as for `keeper/client.connect`. Returns the client at
---once; sends made before it is up are kept.
---@param opts table
---@param handlers table
---@return table|nil client, string|nil err
function M.start(opts, handlers)
  local dir = M.dir()
  if not rundir.ensure(dir) then return nil, 'cannot create ' .. dir end
  local id = opts.session_id
  local json, sock = M.json_path(id), M.sock_path(id)
  pcall(os.remove, json)
  pcall(os.remove, sock)
  local k = cfg()
  local idle = k.idle_minutes == false and 0 or tonumber(k.idle_minutes) or 30
  local argv = { vim.v.progpath, '--headless', '--clean', '-l', main, json, sock, id, opts.path or '', tostring(idle),
    opts.cwd or '', '--' }
  vim.list_extend(argv, opts.argv)
  local ok, err = pcall(vim.system, argv, { detach = true, stdin = false, stdout = false, stderr = false,
    env = opts.env, clear_env = opts.env ~= nil })
  if not ok then return nil, tostring(err) end
  known[id] = { session_id = id, cwd = opts.cwd, path = opts.path, state = 'busy', attached = true, started = os.time() }
  return client.connect(sock, handlers, client.CONNECT_MS)
end

---Attach to the keeper of session `id` (one found by `refresh`).
---@param id string
---@param handlers table
---@return table client
function M.attach(id, handlers)
  return client.connect(M.sock_path(id), handlers, 1000)
end

---The keeper of session `id` as last read, nil when none runs.
---@param id string
---@return table|nil
function M.info(id) return known[id] end

---Every keeper known: session id -> info.
---@return table<string, table>
function M.all() return known end

---The Claude pids of the keepers known (they are the plugin's, never `elsewhere`).
---@return table<integer, boolean>
function M.claude_pids()
  local out = {}
  for _, k in pairs(known) do
    if type(k.claude_pid) == 'number' then out[k.claude_pid] = true end
  end
  return out
end

---Read the json files again, asynchronously; stale ones (their keeper is gone) are removed.
---@param cb? fun(all: table<string, table>)
function M.refresh(cb)
  local dir = M.dir()
  vim.uv.fs_scandir(dir, function(err, req)
    local names = {}
    if not err and req then
      while true do
        local name, kind = vim.uv.fs_scandir_next(req)
        if not name then break end
        local id = kind == 'file' and name:match('^keeper%-(.+)%.json$')
        if id then names[#names + 1] = id end
      end
    end
    vim.schedule(function()
      local jsonfile = require('agent-ide.util.jsonfile')
      local fresh = {}
      for _, id in ipairs(names) do
        local data = jsonfile.read(dir .. '/keeper-' .. id .. '.json')
        if type(data) == 'table' and data.session_id == id and pid_alive(data.keeper_pid) then
          fresh[id] = data
        elseif type(data) == 'table' then
          pcall(os.remove, dir .. '/keeper-' .. id .. '.json')
          pcall(os.remove, dir .. '/keeper-' .. id .. '.sock')
        end
      end
      -- a keeper started here moments ago may not have written its file yet
      for id, k in pairs(known) do
        if not fresh[id] and k.started and os.time() - k.started < 10 and not k.claude_pid then fresh[id] = k end
      end
      known = fresh
      if cb then cb(known) end
    end)
  end)
end

---Forget a keeper (its Claude exited).
---@param id string
function M.forget(id) known[id] = nil end

---Test only.
function M._reset() known = {} end
M._main = main

return M
