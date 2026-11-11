-- Scriptable fake ACP agent (JSON-RPC 2.0 over stdio). Run: nvim -l tests/fake_acp.lua <scenario.jsonl>
-- (Use tests/acp.lua: acp.cmd(lines) writes the scenario and returns the cmd for an agent's `cmd`.)
-- Scenario: one JSON object per line, executed in order:
--   {"expect": "<substring>"}      block until an input line containing it arrives (earlier lines are
--                                  kept); the id of that line, if any, becomes the target of `respond`
--   {"respond": <result>[, "to": <id>]}        a success response to the last expected request (or `to`)
--   {"respond_error": {"code":n,"message":"…"}[, "to": <id>]}   an error response
--   {"update": <update object>}    a session/update notification; sessionId is the last one this fake
--                                  gave in a `respond` result (else "fake-session")
--   {"request": {"method":"…","params":{…}}}   an agent→client request (ids a1, a2, …); blocks
--                                  until the client's response arrives
--   {"emit": <object>}  {"emit_raw": "<text>"}  {"sleep_ms": n}  {"exit": code}  {"ignore_stdin": true}
-- After the last step it keeps reading stdin until EOF, then exits 0.
-- Env FAKE_ACP_LOG=<file>: appends {"argv":[...],"cwd":"..."} first, then {"in":"<line>"} per line
--   received. `--version` anywhere in argv prints "fake-acp 0.1" and exits 0.
local args = {}
for i = 1, #arg do args[i] = arg[i] end

if vim.tbl_contains(args, '--version') then
  io.stdout:write('fake-acp 0.1\n')
  io.stdout:flush()
  os.exit(0)
end

local log = os.getenv('FAKE_ACP_LOG')
local function log_line(obj)
  if not log or log == '' then return end
  local f = io.open(log, 'a')
  if f then f:write(vim.json.encode(obj), '\n'); f:close() end
end
log_line({ argv = args, cwd = vim.uv.cwd() })

local steps = {}
for line in io.lines(args[1]) do
  if line:find('%S') then steps[#steps + 1] = vim.json.decode(line, { luanil = { object = true } }) end
end

local pending = {} -- input lines not yet consumed by an expect
local eof = false
local function read_line()
  local l = io.stdin:read('*l')
  if l == nil then eof = true; return nil end
  log_line({ ['in'] = l })
  return l
end

-- The first input line (received earlier or now) containing `text`; nil at EOF.
local function take(text)
  while true do
    for i, l in ipairs(pending) do
      if l:find(text, 1, true) then return table.remove(pending, i) end
    end
    local l = read_line()
    if l == nil then return nil end
    pending[#pending + 1] = l
  end
end

local function write(obj)
  io.stdout:write(vim.json.encode(obj), '\n')
  io.stdout:flush()
end

local last_id, sid, agent_n = nil, 'fake-session', 0

local function decode(l)
  local ok, obj = pcall(vim.json.decode, l, { luanil = { object = true } })
  return ok and type(obj) == 'table' and obj or {}
end

for _, step in ipairs(steps) do
  if step.expect then
    local l = take(step.expect)
    if not l then os.exit(0) end
    local obj = decode(l)
    if obj.id ~= nil then last_id = obj.id end
  elseif step.respond ~= nil then
    local r = step.respond
    if type(r) == 'table' and type(r.sessionId) == 'string' then sid = r.sessionId end
    write({ jsonrpc = '2.0', id = step.to ~= nil and step.to or last_id, result = r })
  elseif step.respond_error ~= nil then
    write({ jsonrpc = '2.0', id = step.to ~= nil and step.to or last_id, error = step.respond_error })
  elseif step.update ~= nil then
    write({ jsonrpc = '2.0', method = 'session/update', params = { sessionId = sid, update = step.update } })
  elseif step.request ~= nil then
    agent_n = agent_n + 1
    local id = 'a' .. agent_n
    write({ jsonrpc = '2.0', id = id, method = step.request.method, params = step.request.params })
    if not take('"id":"' .. id .. '"') then os.exit(0) end
  elseif step.emit ~= nil then
    write(step.emit)
  elseif step.emit_raw ~= nil then
    io.stdout:write(step.emit_raw); io.stdout:flush()
  elseif step.sleep_ms then
    vim.uv.sleep(step.sleep_ms)
  elseif step.exit ~= nil then
    os.exit(step.exit)
  elseif step.ignore_stdin then
    vim.wait(math.huge, function() return false end, 50)
  end
end

while not eof do read_line() end
os.exit(0)
