-- The agent registry (lua/agent-ide/agents) and the Claude adapter: a Session drives Claude
-- through the adapter exactly as it did before the adapter existed.
local config = require('agent-ide.config')
local session = require('agent-ide.session')
local agents = require('agent-ide.agents')
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality

local dir, orig_notify

local function wait(pred, ms) return vim.wait(ms or 5000, pred, 10) end

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    config.setup({})
    orig_notify = vim.notify
    vim.notify = function() end
    dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
  end,
  post_case = function()
    session._reset()
    vim.notify = orig_notify
    vim.uv.os_unsetenv('FAKE_CLAUDE_LOG')
    config.setup({})
    vim.fn.delete(dir, 'rf')
  end,
} })

T['claude is the built-in adapter: name, label, capabilities'] = function()
  local a, err = agents.get('claude')
  eq(err, nil)
  eq({ a.name, a.label }, { 'claude', 'Claude' })
  for _, c in ipairs({ 'resume', 'modes', 'models', 'commands', 'interrupt', 'quota', 'native', 'live', 'transcript' }) do
    eq({ c, a.capabilities[c] }, { c, true })
  end
  eq(a.capabilities.images, false)
  eq(type(a.start), 'function')
  eq(type(a.history), 'function')
  eq(type(a.attach), 'function')
  eq(agents.get('claude'), a) -- one instance
end

T['an unknown agent is nil with a clear reason; default and names come from the config'] = function()
  local a, err = agents.get('nope')
  eq(a, nil)
  eq(err:find('nope', 1, true) ~= nil, true)
  eq(agents.default(), 'claude')
  eq(agents.names(), { 'claude', 'gemini', 'opencode' }) -- the built-in entries
  config.setup({ default_agent = 'claude', agents = { zed = { kind = 'what' } } })
  eq(agents.names(), { 'claude', 'gemini', 'opencode', 'zed' })
  local z, zerr = agents.get('zed')
  eq(z, nil)
  eq(zerr:find('kind', 1, true) ~= nil, true)
end

T['a session opened without an agent is a Claude session'] = function()
  local s = session.open({ cwd = dir })
  eq(s.agent, 'claude')
  eq(s.adapter, agents.get('claude'))
  eq(s.capabilities.modes, true)
  eq(s.capabilities.live, true)
  local t = session.open({ cwd = dir, agent = 'claude' })
  eq(t.agent, 'claude')
end

-- Golden: the Action and wire sequence of one streamed turn, as the Session produced it
-- before the adapter (tests/test_session.lua holds the full set; this is the shape).
T['golden: one turn through the Claude adapter keeps events, raw lines and sent lines'] = function()
  local cmd, log = fake.cmd({
    { expect = 'hello' },
    { emit = { type = 'system', subtype = 'init', session_id = 'x', model = 'claude-haiku-5-5', permissionMode = 'default',
      slash_commands = { 'compact' }, claude_code_version = '2.1.306' } },
    { emit = { type = 'user', message = { role = 'user', content = 'hello' }, isReplay = true } },
    { emit = { type = 'stream_event', event = { type = 'content_block_start', index = 0, content_block = { type = 'text', text = '' } } } },
    { emit = { type = 'stream_event', event = { type = 'content_block_delta', index = 0, delta = { type = 'text_delta', text = 'Hi' } } } },
    { emit = { type = 'assistant', message = { id = 'm', type = 'message', role = 'assistant', content = { { type = 'text', text = 'Hi' } } } } },
    { emit = { type = 'result', subtype = 'success', is_error = false, result = 'Hi' } },
  })
  config.setup({ claude = { cmd = cmd }, keeper = { enabled = false } })
  local s = session.open({ cwd = dir })
  eq(s:send('hello'), true)
  assert(wait(function() return s.state == 'done' end)) -- not on screen: done, unread
  eq(vim.tbl_map(function(e) return e.kind end, s.events), { 'prompt', 'text' })
  eq({ s.model, s.mode, s.slash_commands, s.streaming }, { 'claude-haiku-5-5', 'manual', { 'compact' }, '' })
  -- what went over the wire, in order: initialize, the prompt, then Claude's six lines
  eq(vim.tbl_map(function(r) return r.dir end, s.raw), { 'out', 'out', 'in', 'in', 'in', 'in', 'in', 'in' })
  eq(vim.json.decode(s.raw[1].line).request.subtype, 'initialize')
  eq(vim.json.decode(s.raw[2].line), { type = 'user', message = { role = 'user', content = 'hello' } })
  local ins = fake.ins(log)
  eq(#ins, 1)
  eq(ins[1].message.content, 'hello')
  eq(fake.is_init(fake.log(log)[2]['in']), true)
end

return T
