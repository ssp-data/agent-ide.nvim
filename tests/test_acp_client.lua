-- The JSON-RPC 2.0 client (lua/agent-ide/agents/acp/client.lua) against the fake ACP agent.
local client = require('agent-ide.agents.acp.client')
local acp = dofile(vim.fn.getcwd() .. '/tests/acp.lua')
local eq = MiniTest.expect.equality

local function wait(pred, ms) return vim.wait(ms or 5000, pred, 10) end

local function children()
  vim.fn.system({ 'pgrep', '-P', tostring(vim.fn.getpid()), '-f', 'fake_acp' })
  return vim.v.shell_error == 0
end

local started = {}
local T = MiniTest.new_set({ hooks = {
  post_case = function()
    for _, c in ipairs(started) do c:stop(nil, true) end
    started = {}
    vim.uv.os_unsetenv('FAKE_ACP_LOG')
    assert(wait(function() return not children() end, 3000), 'a fake ACP agent is still running')
  end,
} })

---Start the fake with `steps`; `opts` as for `client.start`.
local function start(steps, opts)
  local cmd, log = acp.cmd(steps)
  local c, err = client.start(cmd, opts or {})
  assert(c, err)
  started[#started + 1] = c
  return c, log
end

T['requests are answered by id, also out of order; a notification reaches its handler'] = function()
  local c, log = start({
    { expect = '"one"' }, { expect = '"two"' },
    { respond = { n = 2 } }, -- the last expected: id 2
    { respond = { n = 1 }, to = 1 },
    { emit = { jsonrpc = '2.0', method = 'session/update', params = { sessionId = 's', update = { sessionUpdate = 'x' } } } },
  })
  local got, notes = {}, {}
  c:on_notification('session/update', function(p) notes[#notes + 1] = p end)
  c:request('one', { a = 1 }, function(err, result) got[#got + 1] = { 'one', err, result } end)
  c:request('two', vim.empty_dict(), function(err, result) got[#got + 1] = { 'two', err, result } end)
  assert(wait(function() return #got == 2 and #notes == 1 end))
  eq(got, { { 'two', nil, { n = 2 } }, { 'one', nil, { n = 1 } } })
  eq(notes[1].update.sessionUpdate, 'x')
  local ins = acp.ins(log)
  eq({ ins[1].jsonrpc, ins[1].id, ins[1].method, ins[1].params }, { '2.0', 1, 'one', { a = 1 } })
  eq({ ins[2].id, ins[2].method }, { 2, 'two' })
  eq(c:alive(), true)
  eq(type(c.pid), 'number')
end

T['a request of the agent is answered through its handler; an unknown one gets -32601'] = function()
  local c, log = start({
    { request = { method = 'fs/read_text_file', params = { path = '/x' } } },
    { request = { method = 'terminal/create', params = { command = 'ls' } } },
    { emit = { jsonrpc = '2.0', method = 'strange/thing', params = { k = 1 } } },
  })
  local unhandled = {}
  c:on_request('fs/read_text_file', function(params, respond)
    eq(params.path, '/x')
    respond({ content = 'hi' })
  end)
  c:on_unhandled(function(msg) unhandled[#unhandled + 1] = msg end)
  assert(wait(function() return #unhandled == 2 end))
  eq({ unhandled[1].method, unhandled[2].method }, { 'terminal/create', 'strange/thing' })
  local ins = acp.ins(log)
  eq(ins[1], { jsonrpc = '2.0', id = 'a1', result = { content = 'hi' } })
  eq(ins[2].id, 'a2')
  eq(ins[2].error.code, -32601)
  eq(ins[2].error.message:find('terminal/create', 1, true) ~= nil, true)
end

T['a JSON-RPC error response surfaces as err; a handler may answer with an error'] = function()
  local c, log = start({
    { expect = '"session/prompt"' }, { respond_error = { code = 429, message = 'quota', data = { k = 1 } } },
    { request = { method = 'fs/write_text_file', params = { path = '/x' } } },
  })
  local err, result
  c:on_request('fs/write_text_file', function(_, respond) respond(nil, { code = -32000, message = 'refused' }) end)
  c:request('session/prompt', {}, function(e, r) err, result = e, r end)
  assert(wait(function() return err ~= nil end))
  eq({ err.code, err.message, err.data, result }, { 429, 'quota', { k = 1 }, nil })
  assert(wait(function() return #acp.ins(log) == 2 end))
  eq(acp.ins(log)[2].error, { code = -32000, message = 'refused' })
end

T['a malformed line is reported and skipped; every line reaches on_raw in order'] = function()
  local raw, garbage = {}, {}
  local c = start({
    { expect = '"ping"' },
    { emit_raw = 'not json at all\n' },
    { emit_raw = '{"jsonrpc":"2.0",\n' },
    { respond = { ok = true } },
  }, {
    on_raw = function(dir, line) raw[#raw + 1] = dir .. ' ' .. line end,
    on_garbage = function(line) garbage[#garbage + 1] = line end,
  })
  local result
  c:request('ping', {}, function(_, r) result = r end)
  assert(wait(function() return result ~= nil end))
  eq(result, { ok = true })
  eq(garbage, { 'not json at all', '{"jsonrpc":"2.0",' })
  eq(#raw, 4)
  eq(raw[1]:sub(1, 4), 'out ')
  eq(raw[2], 'in not json at all')
  eq(raw[4]:find('"ok":true', 1, true) ~= nil, true)
end

T['a request times out; a request with timeout false waits'] = function()
  local c = start({ { expect = '"slow"' }, { sleep_ms = 600 }, { respond = { late = true } } }, { timeout_ms = 100 })
  local err, later
  c:request('slow', {}, function(e) err = e end)
  c:request('never-answered', {}, function(e, r) later = { e, r } end, false)
  assert(wait(function() return err ~= nil end))
  eq(err.code, 'timeout')
  vim.wait(300)
  eq(later, nil)
  -- the late answer to the timed-out request is not delivered twice: it is unhandled
  local unhandled = {}
  c:on_unhandled(function(msg) unhandled[#unhandled + 1] = msg end)
  assert(wait(function() return #unhandled == 1 end))
  eq(unhandled[1].result, { late = true })
end

T['the agent exiting fails every pending request once and reports the exit with stderr'] = function()
  local exits, fails = {}, {}
  local c = start({ { expect = '"a"' }, { expect = '"b"' }, { emit_raw = '' }, { exit = 3 } }, {
    on_exit = function(code, signal, tail) exits[#exits + 1] = { code, signal, tail } end,
  })
  c:request('a', {}, function(e) fails[#fails + 1] = e end, false)
  c:request('b', {}, function(e) fails[#fails + 1] = e end, false)
  assert(wait(function() return #exits == 1 end))
  assert(wait(function() return #fails == 2 end))
  vim.wait(100)
  eq(#fails, 2)
  eq({ fails[1].code, fails[2].code }, { 'exit', 'exit' })
  eq(exits[1][1], 3)
  eq(c:alive(), false)
  eq(c:request('late', {}, function() end), false)
end

T['stop ends the process (stdin closed, then SIGTERM) and runs the callback once'] = function()
  local c = start({ { ignore_stdin = true } })
  client._grace_ms = 100
  local n = 0
  c:stop(function() n = n + 1 end)
  assert(wait(function() return not c:alive() end))
  assert(wait(function() return n == 1 end))
  c:stop(function() n = n + 1 end)
  assert(wait(function() return n == 2 end))
  client._grace_ms = 500
  assert(wait(function() return not children() end, 3000))
end

T['a missing program is an error, not a crash'] = function()
  local c, err = client.start({ '/nonexistent/acp-agent' }, {})
  eq(c, nil)
  eq(type(err), 'string')
end

return T
