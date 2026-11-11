-- The ACP adapter (lua/agent-ide/agents/acp): the pure translation of ACP messages into
-- Actions, and a Session driving the fake ACP agent through it.
local config = require('agent-ide.config')
local session = require('agent-ide.session')
local translate = require('agent-ide.agents.acp.translate')
local fs = require('agent-ide.agents.acp.fs')
local acp = dofile(vim.fn.getcwd() .. '/tests/acp.lua')
local eq = MiniTest.expect.equality

local dir, orig_notify, notes

local function wait(pred, ms) return vim.wait(ms or 5000, pred, 10) end
local function children()
  vim.fn.system({ 'pgrep', '-P', tostring(vim.fn.getpid()), '-f', 'fake_acp' })
  return vim.v.shell_error == 0
end

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    config.setup({})
    notes = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
  end,
  post_case = function()
    session._reset()
    vim.notify = orig_notify
    vim.uv.os_unsetenv('FAKE_ACP_LOG')
    config.setup({})
    vim.fn.delete(dir, 'rf')
    assert(wait(function() return not children() end, 3000), 'a fake ACP agent is still running')
  end,
} })

local function kinds(events)
  return vim.tbl_map(function(e) return e.kind end, events)
end

---Configure agent `fake` with the fake running `steps`; returns the log path.
local function script(steps, extra)
  local cmd, log = acp.cmd(steps)
  config.setup({ agents = { fake = vim.tbl_extend('force', { kind = 'acp', cmd = cmd, label = 'Fake' }, extra or {}) } })
  return log
end

local function open(opts) return session.open(vim.tbl_extend('force', { cwd = dir, agent = 'fake' }, opts or {})) end

-- Translation (pure) ------------------------------------------------------------------------

T['translate: chunks stream as deltas and end as one text; thoughts become one thinking event'] = function()
  local t = translate.new()
  local out = {}
  for _, u in ipairs({ acp.thought('think '), acp.thought('more'), acp.chunk('Hel'), acp.chunk('lo') }) do
    vim.list_extend(out, t:update(u.update, 'raw'))
  end
  vim.list_extend(out, t:result(nil, { stopReason = 'end_turn' }))
  eq(vim.tbl_map(function(a) return a.type end, out), { 'event', 'delta', 'delta', 'event', 'result' })
  eq(out[1].event, { kind = 'thinking', text = 'think more' })
  eq({ out[2].text, out[3].text }, { 'Hel', 'lo' })
  eq({ out[4].event, out[4].streamed }, { { kind = 'text', text = 'Hello' }, true })
  eq(out[5], { type = 'result', is_error = false })
end

T['translate: a tool call with updates is one call and one result; diff content reads as an edit'] = function()
  local t = translate.new()
  local out = {}
  local steps = {
    acp.chunk('before'),
    acp.tool_call('t1', 'echo hi', 'execute'),
    acp.tool_update('t1', 'in_progress', { rawInput = { command = 'echo hi' } }),
    acp.tool_update('t1', 'completed', { content = { acp.text_content('hi') } }),
    acp.tool_call('t2', 'edit', 'edit', { name = 'edit', rawInput = {} }),
    acp.tool_update('t2', 'in_progress', { locations = { { path = '/x/notes.txt' } } }),
    acp.tool_update('t2', 'completed', { content = { acp.text_content('Edited notes.txt'), acp.diff_content('/x/notes.txt', 'a\n', 'a\nb\n') } }),
    acp.tool_update('t2', 'completed', {}), -- repeated: no second result
    acp.tool_call('t3', 'rm -rf', 'execute'),
    acp.tool_update('t3', 'failed', { content = { acp.text_content('Tool was canceled by the user.') } }),
  }
  for _, u in ipairs(steps) do vim.list_extend(out, t:update(u.update, 'raw')) end
  local evs = vim.tbl_map(function(a) return a.event end, vim.tbl_filter(function(a) return a.type == 'event' end, out))
  eq(kinds(evs), { 'text', 'tool_call', 'tool_result', 'tool_call', 'tool_result', 'tool_call', 'tool_result' })
  eq(evs[1].text, 'before')
  eq(evs[2], { kind = 'tool_call', id = 't1', name = 'execute', input = { command = 'echo hi' } })
  eq(evs[3], { kind = 'tool_result', id = 't1', text = 'hi', is_error = false })
  eq(evs[4], { kind = 'tool_call', id = 't2', name = 'edit', input = { description = 'edit' } })
  eq(evs[5].text, 'Edited notes.txt\n--- /x/notes.txt\n- a\n- \n+ a\n+ b\n+ ')
  eq(evs[7].is_error, true)
end

T['translate: plan, commands, mode, usage, unknown kinds, permission options'] = function()
  local t = translate.new()
  local plan = t:update({ sessionUpdate = 'plan', entries = { { content = 'read', status = 'completed', priority = 'high' },
    { content = 'write', status = 'pending' } } }, 'raw')
  eq(plan[1].event, { kind = 'meta', label = 'plan', text = '- [completed] read (high)\n- [pending] write' })
  eq(t:update(acp.commands({ 'init', 'review' }).update, 'raw'), { { type = 'commands', slash_commands = { 'init', 'review' } } })
  eq(t:update({ sessionUpdate = 'current_mode_update', currentModeId = 'plan' }, 'raw'), { { type = 'status', mode = 'plan' } })
  eq(t:update({ sessionUpdate = 'usage_update', used = 1, size = 2 }, 'raw'), {})
  eq(t:update({ sessionUpdate = 'something_new', x = 1 }, '{"raw":1}'), { { type = 'unknown', label = 'session/update/something_new', raw = '{"raw":1}' } })
  eq(t:update('nope', 'raw')[1].label, 'session/update/nil')
  eq(t:update({ sessionUpdate = 'agent_message_chunk', content = { type = 'image' } }, 'raw')[1].type, 'unknown')
  local p = t:permission(7, acp.permission('t9', 'ls -la').request.params)
  eq({ p.type, p.request_id, p.tool_name, p.input, p.description, #p.options, p.tool_call_id },
    { 'permission', '7', 'execute', { command = 'ls -la' }, 'ls -la', 3, 't9' })
  eq(translate.pick_option(p.options, true), 'proceed_once')
  eq(translate.pick_option(p.options, false), 'cancel')
  eq(translate.pick_option({ { optionId = 'yes', kind = 'allow_always' } }, true), 'yes')
  eq(translate.pick_option({ { optionId = 'yes', kind = 'allow_always' } }, false), nil)
  eq(t:result({ code = 429, message = 'quota' }, nil)[1], { type = 'result', is_error = true, text = 'quota' })
  eq(t:result(nil, { stopReason = 'refusal' })[1], { type = 'result', is_error = true, text = 'Turn ended: refusal' })
  eq(t:result(nil, { stopReason = 'cancelled' })[1].is_error, false)
end

T['fs: scope cwd allows the folder and below, refuses outside, links out and relative paths'] = function()
  vim.fn.mkdir(dir .. '/sub', 'p')
  vim.fn.writefile({ 'x' }, dir .. '/sub/a.txt')
  eq(fs.allowed('cwd', dir, dir .. '/sub/a.txt'), true)
  eq(fs.allowed('cwd', dir, dir .. '/new.txt'), true)
  eq(fs.allowed('cwd', dir, dir), true)
  eq((fs.allowed('cwd', dir, dir .. '/../etc/passwd')), false)
  eq((fs.allowed('cwd', dir, '/etc/passwd')), false)
  eq((fs.allowed('cwd', dir, 'relative.txt')), false)
  eq((fs.allowed(false, dir, dir .. '/a')), false)
  eq(fs.allowed('any', dir, '/etc/hostname'), true)
  vim.uv.fs_symlink('/etc', dir .. '/etc-link')
  eq((fs.allowed('cwd', dir, dir .. '/etc-link/hostname')), false)
  -- the handlers: a read with line/limit, a refused read, a write
  local got
  fs.read_handler('cwd', dir)({ path = dir .. '/sub/a.txt' }, function(r, e) got = { r, e } end)
  assert(wait(function() return got ~= nil end))
  eq(got, { { content = 'x\n' } })
  got = nil
  fs.read_handler('cwd', dir)({ path = '/etc/passwd' }, function(r, e) got = { r, e } end)
  eq(got[1], nil)
  eq(got[2].message:find('refused', 1, true) ~= nil, true)
  got = nil
  fs.write_handler('cwd', dir)({ path = dir .. '/w.txt', content = 'written\n' }, function(r, e) got = { r, e } end)
  assert(wait(function() return got ~= nil end))
  eq(got[2], nil)
  eq(vim.fn.readfile(dir .. '/w.txt'), { 'written' })
end

-- Through a Session --------------------------------------------------------------------------

T['start: initialize, session/new, capabilities, init action; a turn streams and ends'] = function()
  local log = script(acp.flat(acp.handshake(), acp.commands({ 'memory', 'help' }),
    { expect = '"session/prompt"' }, acp.thought('hmm'), acp.chunk('Hel'), acp.chunk('lo'), acp.end_turn()))
  local s = open()
  eq({ s.agent, s.adapter.label, s.capabilities.live, s.capabilities.native, s.capabilities.quota }, { 'fake', 'Fake', false, false, false })
  eq(s:send('hello'), true)
  eq(s.state, 'busy')
  assert(wait(function() return s.state == 'done' end))
  eq(kinds(s.events), { 'prompt', 'thinking', 'text' })
  eq(s.events[3].text, 'Hello')
  eq({ s.streaming, s.model, s.mode, s.agent_session_id }, { '', 'm-small', 'default', 'fake-session-1' })
  eq({ s.capabilities.resume, s.capabilities.modes, s.capabilities.models, s.capabilities.commands }, { true, true, true, true })
  eq(s.slash_commands, { 'memory', 'help' })
  eq(vim.tbl_map(function(m) return m.value end, s.models), { 'm-small', 'm-big' })
  eq(vim.tbl_map(function(m) return m.id end, s.modes), { 'default', 'plan' })
  local ins = acp.ins(log)
  eq(vim.tbl_map(function(m) return m.method end, ins), { 'initialize', 'session/new', 'session/prompt' })
  eq(ins[1].params.clientCapabilities, { fs = { readTextFile = true, writeTextFile = true }, terminal = false })
  eq(ins[2].params, { cwd = dir, mcpServers = {} })
  eq(ins[3].params, { sessionId = 'fake-session-1', prompt = { { type = 'text', text = 'hello' } } })
  -- every wire line is in the raw view: three sent (the handshake and the prompt), seven received
  local dirs = vim.tbl_map(function(r) return r.dir end, s.raw)
  eq(#vim.tbl_filter(function(d) return d == 'out' end, dirs), 3)
  eq(#dirs, 10)
  eq({ dirs[1], dirs[2], dirs[3], dirs[4] }, { 'out', 'in', 'out', 'in' })
end

T['a permission ask: options kept, allow answers with the allow option, deny with the reject one'] = function()
  local log = script(acp.flat(acp.handshake(),
    { expect = '"session/prompt"' }, acp.tool_call('t1', 'echo hi', 'execute'), acp.permission('t1', 'echo hi'),
    acp.tool_update('t1', 'completed', { content = { acp.text_content('hi') } }), acp.end_turn(),
    { expect = '"session/prompt"' }, acp.tool_call('t2', 'rm x', 'execute'), acp.permission('t2', 'rm x'),
    acp.tool_update('t2', 'failed', { content = { acp.text_content('cancelled by the user') } }), acp.chunk('sorry'), acp.end_turn()))
  local s = open()
  s:send('do it')
  assert(wait(function() return s.state == 'waiting' end))
  local p = s.pending_permissions[1]
  eq({ p.request_id, p.tool_name, p.input, #p.options, p.suggestions }, { 'p1', 'execute', { command = 'echo hi' }, 3, nil })
  eq(s:answer('p1', true), true)
  assert(wait(function() return s.state == 'done' end))
  s:send('again')
  assert(wait(function() return s.state == 'waiting' end))
  eq(s:answer('p2', false), true)
  assert(wait(function() return s.state == 'done' end))
  eq(kinds(s.events), { 'prompt', 'tool_call', 'tool_result', 'prompt', 'tool_call', 'tool_result', 'text' })
  eq(s.events[6].is_error, true)
  local answers = vim.tbl_filter(function(m) return m.result and m.result.outcome end, acp.ins(log))
  eq(vim.tbl_map(function(m) return m.result.outcome.optionId end, answers), { 'proceed_once', 'cancel' })
  eq(answers[1].id, 'a1')
end

T['interrupt sends session/cancel; the cancelled turn keeps its text and ends idle'] = function()
  local log = script(acp.flat(acp.handshake(),
    { expect = '"session/prompt"' }, acp.chunk('once upon'), { expect = '"session/cancel"' }, acp.end_turn('cancelled'),
    { expect = '"session/prompt"' }, acp.chunk('4'), acp.end_turn()))
  local s = open()
  s.visible = true
  s:send('essay')
  assert(wait(function() return s.streaming == 'once upon' end))
  local dropped, sent = s:interrupt()
  eq({ dropped, sent }, { {}, true })
  assert(wait(function() return s.state == 'idle' end))
  eq(kinds(s.events), { 'prompt', 'text' })
  eq(s.events[2].text, 'once upon')
  eq(#acp.sent(log, 'session/cancel'), 1)
  s:send('2+2')
  assert(wait(function() return #s.events == 4 end))
  eq(s.events[4].text, '4')
end

T['a failed prompt (JSON-RPC error) and an odd stop reason end the turn with an error line'] = function()
  script(acp.flat(acp.handshake(),
    { expect = '"session/prompt"' }, { respond_error = { code = 429, message = 'daily quota exhausted' } },
    { expect = '"session/prompt"' }, acp.chunk('part'), acp.end_turn('max_tokens')))
  local s = open()
  s:send('hi')
  assert(wait(function() return s.state == 'failed' end))
  eq(s.events[2], { kind = 'meta', label = 'error', text = 'daily quota exhausted', live_only = true })
  s:send('again')
  assert(wait(function() return s.state == 'failed' end))
  eq(kinds(s.events), { 'prompt', 'meta', 'prompt', 'text', 'meta' })
  eq(s.events[5].text, 'Turn ended: max_tokens')
end

T['unknown updates, requests and notifications show as unknown folds; a declined method is named'] = function()
  local log = script(acp.flat(acp.handshake(),
    { expect = '"session/prompt"' },
    { update = { sessionUpdate = 'brand_new', k = 1 } },
    { request = { method = 'terminal/create', params = { command = 'ls' } } },
    { emit = { jsonrpc = '2.0', method = 'odd/notice', params = {} } },
    { respond_error = { code = -32000, message = 'client declined terminal/create' } }))
  local s = open()
  s:send('hi')
  assert(wait(function() return s.state == 'failed' end))
  eq(kinds(s.events), { 'prompt', 'unknown', 'unknown', 'unknown', 'meta' })
  eq(s.events[2].label, 'session/update/brand_new')
  eq(s.events[2].raw:find('"brand_new"', 1, true) ~= nil, true)
  eq(s.events[3].label, 'terminal/create')
  eq(s.events[4].label, 'odd/notice')
  eq(s.events[5].text, 'client declined terminal/create')
  local decline = acp.ins(log)[4] -- after initialize, session/new, session/prompt
  eq({ decline.id, decline.error.code }, { 'a1', -32601 })
end

T['the agent exiting mid-turn: text kept, an error line, failed; the next send starts afresh'] = function()
  script(acp.flat(acp.handshake(), { expect = '"session/prompt"' }, acp.chunk('half'), { exit = 3 }))
  local s = open()
  s:send('hi')
  assert(wait(function() return s.state == 'failed' end))
  eq(kinds(s.events), { 'prompt', 'text', 'meta' })
  eq(s.events[2].text, 'half')
  eq(s.events[3].text:find('Fake exited (code 3)', 1, true) ~= nil, true)
  eq(s.proc, nil)
  -- the next send starts a new process and loads the agent's session (it can)
  local log = script(acp.flat({ expect = '"initialize"' }, { respond = acp.init_result() },
    { expect = '"session/load"' }, { respond = acp.new_result() },
    { expect = '"session/prompt"' }, acp.chunk('ok'), acp.end_turn()))
  s = session.get(s.id)
  s.adapter = require('agent-ide.agents').get('fake')
  s:send('again')
  assert(wait(function() return s.state == 'failed' or s.state == 'done' end))
  eq(s.state, 'done')
  eq(acp.ins(log)[2].method, 'session/load')
  eq(acp.ins(log)[2].params.sessionId, 'fake-session-1')
end

T['a handshake that fails: the error names the auth methods, the process ends, the turn fails'] = function()
  script({ { expect = '"initialize"' }, { respond = acp.init_result({ auth = { { id = 'login', name = 'Log in with X' } } }) },
    { expect = '"session/new"' }, { respond_error = { code = -32000, message = 'not authenticated' } } })
  local s = open()
  s:send('hi')
  assert(wait(function() return s.state == 'failed' end))
  eq(s.events[2].text, 'session/new: not authenticated (the agent offers: Log in with X)')
  eq(s.events[3].text:find('exited', 1, true) ~= nil, true)
end

T['mode and model: set through the agent, refused with a notice, deferred before the start'] = function()
  local log = script(acp.flat(acp.handshake(),
    { expect = '"session/set_mode"' }, { respond = vim.empty_dict() },
    { expect = '"session/prompt"' }, acp.chunk('a'), acp.end_turn(),
    { expect = '"session/set_mode"' }, { respond_error = { code = -32603, message = 'Internal error', data = { details = 'untrusted folder' } } },
    { expect = '"session/set_model"' }, { respond = vim.empty_dict() }))
  local s = open()
  eq(s:set_mode('plan'), true) -- before any process: deferred
  eq(s.deferred, { { op = 'set_mode', value = 'plan' } })
  eq(s.mode_requested, 'plan')
  s:send('hi')
  assert(wait(function() return s.state == 'done' end))
  eq({ s.mode, s.mode_requested }, { 'plan', nil })
  eq(acp.ins(log)[3].method, 'session/set_mode')
  eq(acp.ins(log)[3].params, { sessionId = 'fake-session-1', modeId = 'plan' })
  eq(s:set_mode('yolo'), true)
  assert(wait(function() return s.control_error ~= nil end))
  eq(s.control_error, { what = 'mode', value = 'yolo', error = 'Internal error: untrusted folder' })
  eq({ s.mode, s.mode_requested }, { 'plan', nil })
  eq(s.events[#s.events].text, 'set_mode: Internal error: untrusted folder')
  eq(s:set_model('m-big'), true)
  assert(wait(function() return s.model == 'm-big' end))
  eq({ s.model_chosen, s.model_requested }, { 'm-big', nil })
end

T['config options (opencode style): modes and models from them, set through set_config_option'] = function()
  local log = script(acp.flat(acp.handshake({ config = true }),
    { expect = '"session/prompt"' }, acp.chunk('a'), acp.end_turn(),
    { expect = '"session/set_config_option"' }, { respond = { configOptions = {} } }))
  local s = open()
  s:send('hi')
  assert(wait(function() return s.state == 'done' end))
  eq({ s.model, s.mode, s.capabilities.modes, s.capabilities.models }, { 'prov/m-small', 'build', true, true })
  eq(vim.tbl_map(function(m) return m.id end, s.modes), { 'build', 'plan' })
  s:set_mode('plan')
  assert(wait(function() return s.mode == 'plan' end))
  eq(acp.ins(log)[4].params, { sessionId = 'fake-session-1', configId = 'mode', value = 'plan' })
end

T['client-side files: a read inside the folder is answered, one outside refused; fs = false declines'] = function()
  vim.fn.writefile({ 'inside' }, dir .. '/in.txt')
  local log = script(acp.flat(acp.handshake(),
    { expect = '"session/prompt"' },
    { request = { method = 'fs/read_text_file', params = { path = dir .. '/in.txt' } } },
    { request = { method = 'fs/read_text_file', params = { path = '/etc/passwd' } } },
    { request = { method = 'fs/write_text_file', params = { path = dir .. '/out.txt', content = 'o' } } },
    acp.end_turn()))
  local s = open()
  s:send('read')
  assert(wait(function() return s.state == 'done' end))
  local ins = acp.ins(log)
  eq(ins[4].result, { content = 'inside\n' })
  eq(ins[5].error.message:find('refused', 1, true) ~= nil, true)
  eq(ins[6].result, vim.empty_dict())
  eq(vim.fn.readfile(dir .. '/out.txt'), { 'o' })
  eq(kinds(s.events), { 'prompt' }) -- file calls are not events
  -- fs = false: the capability is not offered and a call is declined
  local log2 = script(acp.flat(acp.handshake(), { expect = '"session/prompt"' },
    { request = { method = 'fs/read_text_file', params = { path = dir .. '/in.txt' } } }, acp.end_turn()), { fs = false })
  local s2 = open({ id = 'other' })
  s2:send('read')
  assert(wait(function() return s2.state == 'done' end))
  eq(acp.ins(log2)[1].params.clientCapabilities.fs, { readTextFile = false, writeTextFile = false })
  eq(acp.ins(log2)[4].error.code, -32601)
end

return T
