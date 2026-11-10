-- The keeper: a headless Neovim (`nvim --headless --clean -l main.lua …`), started detached by
-- the plugin, that owns the pipes of one `claude -p` process so the process outlives the Neovim
-- that started it (docs/superpowers/specs/2026-11-10-keeper-design.md). It keeps every line
-- sent to and received from Claude (the last LOG_KEEP) and serves one client at a time over a
-- Unix socket: `attach` replays the log and then streams; `send` writes a line to Claude;
-- `queue` hands over prompts the keeper sends itself at the end of a turn while no client is
-- attached; `stop` ends Claude (close stdin, SIGTERM after a grace period); `detach` or a closed
-- socket leaves Claude running. An idle Claude with no client is closed after IDLE minutes.
--
-- Arguments: <json file> <socket> <session id> <transcript path or ""> <idle minutes> <cwd> -- <claude argv…>
local uv = vim.uv
local script = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(script, ':p:h:h:h:h')
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
local lines = require('agent-ide.util.lines')
local jsonfile = require('agent-ide.util.jsonfile')
local kstate = require('agent-ide.keeper.state')

local LOG_KEEP = 5000
local GRACE_MS, LINGER_MS = 500, 2000 -- linger: a client may still attach and collect the exit

local args = vim.deepcopy(_G.arg or {})
local json_path, sock_path, session_id, transcript, idle_minutes, cwd = args[1], args[2], args[3], args[4], tonumber(args[5]) or 0, args[6]
local argv = {}
local after = false
for _, a in ipairs(args) do
  if after then argv[#argv + 1] = a elseif a == '--' then after = true end
end
if not json_path or not sock_path or not session_id or #argv == 0 then
  io.stderr:write('usage: main.lua <json> <socket> <session id> <transcript> <idle minutes> <cwd> -- <argv…>\n')
  os.exit(2)
end
if transcript == '' then transcript = nil end

local done = false
local log, dropped = {}, 0
local st = kstate.new()
local client ---@type table|nil { pipe, splitter }
local queue = {} ---@type string[] prompts handed over, sent at the end of a turn while nobody is attached
local proc, exited, stdin_closed = nil, false, false
local exit_msg ---@type table|nil kept for a client that attaches after Claude ended
local err_chunks, err_len = {}, 0
local idle_timer

local info = {
  version = 1, session_id = session_id, cwd = cwd, path = transcript, keeper_pid = uv.os_getpid(),
  claude_pid = nil, started = os.time(), offset = 0, state = 'idle', attached = false, queued = 0, updated = os.time(),
}
if transcript then
  local s = uv.fs_stat(transcript)
  info.offset = s and s.size or 0
end

local function write_info()
  if exited then return end
  info.updated = os.time()
  info.state, info.attached, info.queued = st.state, client ~= nil, #queue
  jsonfile.write(json_path, info)
end

local function push_log(dir, line)
  log[#log + 1] = { dir = dir, line = line }
  if #log > LOG_KEEP then
    table.remove(log, 1)
    dropped = dropped + 1
  end
end

local function to_client(obj)
  if not client then return end
  pcall(client.pipe.write, client.pipe, vim.json.encode(obj) .. '\n')
end

local function close_stdin()
  if stdin_closed or exited or not proc then return end
  stdin_closed = true
  pcall(proc.write, proc, nil)
end

local function stop_claude(now)
  close_stdin()
  local function term() if not exited and proc then pcall(proc.kill, proc, 15) end end
  if now then term() else vim.defer_fn(term, GRACE_MS) end
end

local function send_to_claude(line)
  if exited or stdin_closed or not proc then return false end
  push_log('in', line)
  if kstate.step(st, 'in', line) then write_info() end
  pcall(proc.write, proc, line .. '\n')
  return true
end

local function arm_idle()
  if idle_timer then idle_timer:stop() end
  if idle_minutes <= 0 or client or st.state ~= 'idle' or exited then return end
  idle_timer = idle_timer or uv.new_timer()
  idle_timer:start(math.floor(idle_minutes * 60000), 0, vim.schedule_wrap(function()
    if not client and st.state == 'idle' then stop_claude(false) end
  end))
end

-- A turn ended while nobody is attached: the next handed-over prompt goes out.
local function next_queued()
  if client or #queue == 0 or exited then return end
  local text = table.remove(queue, 1)
  send_to_claude(vim.json.encode({ type = 'user', message = { role = 'user', content = text } }))
  write_info()
end

local function on_claude_line(line)
  if line:find('^%s*$') then return end
  push_log('out', line)
  local changed = kstate.step(st, 'out', line)
  to_client({ op = 'line', dir = 'out', line = line })
  if changed then write_info() end
  if kstate.ends_turn(line) then
    vim.schedule(next_queued)
    arm_idle()
  end
end

local function detach()
  if not client then return end
  local c = client
  client = nil
  pcall(c.pipe.read_stop, c.pipe)
  if not c.pipe:is_closing() then c.pipe:close() end
  write_info()
  if st.state == 'idle' then vim.schedule(next_queued) end
  arm_idle()
end

local function on_message(c, line)
  if line:find('^%s*$') then return end
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= 'table' then return end
  if msg.op == 'attach' then
    if client and client ~= c then
      pcall(c.pipe.write, c.pipe, vim.json.encode({ op = 'busy' }) .. '\n')
      vim.defer_fn(function() if not c.pipe:is_closing() then c.pipe:close() end end, 50)
      return
    end
    client = c
    if idle_timer then idle_timer:stop() end
    local hello = vim.tbl_extend('force', info, { op = 'hello', queue = queue, dropped = dropped, state = st.state,
      attached = true, queued = #queue })
    queue = {}
    to_client(hello)
    for _, e in ipairs(log) do to_client({ op = 'line', dir = e.dir, line = e.line }) end
    to_client({ op = 'synced' })
    if exit_msg then to_client(exit_msg) end
    write_info()
  elseif c ~= client then
    return
  elseif msg.op == 'send' and type(msg.line) == 'string' then
    send_to_claude(msg.line)
  elseif msg.op == 'queue' and type(msg.items) == 'table' then
    queue = vim.tbl_filter(function(t) return type(t) == 'string' end, msg.items)
    write_info()
  elseif msg.op == 'stop' then
    stop_claude(msg.now == true)
  elseif msg.op == 'detach' then
    detach()
  end
end

local server = uv.new_pipe(false)
pcall(os.remove, sock_path)
local bound, berr = server:bind(sock_path)
if not bound then
  io.stderr:write('cannot bind ' .. sock_path .. ': ' .. tostring(berr) .. '\n')
  os.exit(1)
end
uv.fs_chmod(sock_path, 384)
server:listen(8, function(err)
  if err then return end
  local pipe = uv.new_pipe(false)
  server:accept(pipe)
  local c = { pipe = pipe, splitter = lines.splitter() }
  pipe:read_start(function(rerr, data)
    if rerr or not data then
      vim.schedule(function()
        if client == c then detach() elseif not pipe:is_closing() then pipe:close() end
      end)
      return
    end
    vim.schedule(function() c.splitter:push(data, function(l) on_message(c, l) end) end)
  end)
end)

-- The environment is the one the plugin started this keeper with (the API key already stripped
-- when the setting says so): passed on as it is.
local splitter = lines.splitter()
local ok, handle = pcall(vim.system, argv, {
  cwd = cwd ~= '' and cwd or nil, stdin = true,
  stdout = function(e, data)
    if e or not data then return end
    vim.schedule(function() splitter:push(data, on_claude_line) end)
  end,
  stderr = function(e, data)
    if e or not data then return end
    err_chunks[#err_chunks + 1] = data
    err_len = err_len + #data
    if err_len > 8192 then
      local all = table.concat(err_chunks):sub(-2048)
      err_chunks, err_len = { all }, #all
    end
  end,
}, function(r)
  exited = true
  vim.schedule(function()
    local rest = splitter:take_rest()
    if rest then on_claude_line(rest) end
    exit_msg = { op = 'exit', code = r.code, signal = r.signal, stderr = table.concat(err_chunks):sub(-2048) }
    to_client(exit_msg)
    pcall(os.remove, json_path)
    vim.defer_fn(function()
      if client and not client.pipe:is_closing() then client.pipe:close() end
      if not server:is_closing() then server:close() end
      pcall(os.remove, sock_path)
      done = true
    end, LINGER_MS)
  end)
end)
if not ok then
  io.stderr:write('cannot start claude: ' .. tostring(handle) .. '\n')
  pcall(os.remove, sock_path)
  os.exit(1)
end
proc = handle
info.claude_pid = handle.pid
write_info()
arm_idle()

vim.wait(math.huge, function() return done end, 100)
os.exit(0)
