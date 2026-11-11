-- The plugin's own session log (lua/agent-ide/agents/log.lua): what an ACP session records,
-- how it is read back (history equals live), how the drawer's scan lists it, and how a
-- session resumes (the agent loads it, or starts afresh with a notice).
local config = require('agent-ide.config')
local session = require('agent-ide.session')
local index = require('agent-ide.index')
local log = require('agent-ide.agents.log')
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
    config.setup({ helper = { enabled = false } })
    notes = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    vim.fn.delete(log.dir(), 'rf')
  end,
  post_case = function()
    -- a log still being written must not find its folder gone
    for _, s in ipairs(session.all()) do
      if s.log then vim.wait(2000, function() return s.log:idle() end, 10) end
    end
    session._reset()
    vim.notify = orig_notify
    vim.uv.os_unsetenv('FAKE_ACP_LOG')
    config.setup({})
    vim.fn.delete(dir, 'rf')
    vim.fn.delete(log.dir(), 'rf')
    assert(wait(function() return not children() end, 3000), 'a fake ACP agent is still running')
  end,
} })

local function kinds(events) return vim.tbl_map(function(e) return e.kind end, events) end

local function script(steps, extra)
  local cmd, lg = acp.cmd(steps)
  config.setup({ helper = { enabled = false },
    agents = { fake = vim.tbl_extend('force', { kind = 'acp', cmd = cmd, label = 'Fake' }, extra or {}) } })
  return lg
end

local function stored(events)
  return vim.tbl_filter(function(e) return not e.live_only end, events)
end

local function strip(events)
  return vim.tbl_map(function(e)
    local c = {}
    for k, v in pairs(e) do if k ~= 'streamed' then c[k] = v end end
    return c
  end, events)
end

-- A turn with every stored kind: thinking, text, a tool call and its result, a plan.
local function turn_steps()
  return acp.flat({ expect = '"session/prompt"' }, acp.thought('hmm'), acp.chunk('Hel'), acp.chunk('lo'),
    acp.tool_call('t1', 'echo hi', 'execute'), acp.tool_update('t1', 'completed', { content = { acp.text_content('hi') } }),
    { update = { sessionUpdate = 'plan', entries = { { content = 'x', status = 'pending' } } } },
    acp.chunk('done'), acp.end_turn())
end

T['parse: header lines merge, events keep their order, a corrupt last line is skipped'] = function()
  local header, events = log.parse(table.concat({
    '{"version":1,"agent":"fake","id":"abc","cwd":"/x","created":1}',
    '{"kind":"prompt","text":"hi"}',
    '{"agent_session_id":"s-1"}',
    '{"kind":"text","text":"yo"}',
    '{"kind":"text","tex', -- cut while being written
  }, '\n'))
  eq(header, { version = 1, agent = 'fake', id = 'abc', cwd = '/x', created = 1, agent_session_id = 's-1' })
  eq(events, { { kind = 'prompt', text = 'hi' }, { kind = 'text', text = 'yo' } })
end

T['a session records its stored events; the history read back equals the live events'] = function()
  script(acp.flat(acp.handshake(), turn_steps()))
  local s = session.open({ cwd = dir, agent = 'fake' })
  eq(s:send('hello'), true)
  assert(wait(function() return s.state == 'done' end))
  eq(kinds(s.events), { 'prompt', 'thinking', 'text', 'tool_call', 'tool_result', 'meta', 'text' })
  eq(s.path, log.path('fake', s.id))
  assert(wait(function() return s.log:idle() end))
  -- the file: 0600 in 0700 folders, header, the agent's session id, the events
  eq(vim.fn.getfperm(s.path), 'rw-------')
  eq(vim.fn.getfperm(vim.fs.dirname(s.path)), 'rwx------')
  eq(vim.fn.getfperm(log.dir()), 'rwx------')
  local lines = vim.fn.readfile(s.path)
  local header = vim.json.decode(lines[1])
  eq({ header.version, header.agent, header.id, header.cwd, type(header.created) }, { 1, 'fake', s.id, dir, 'number' })
  eq(vim.json.decode(lines[3]), { agent_session_id = 'fake-session-1' })
  -- read back into a fresh Session of the same id (another Neovim): history equals live
  session._reset()
  local t = session.open({ id = s.id, cwd = dir, agent = 'fake' })
  eq(t.state, 'parked')
  local loaded = false
  t:load(function() loaded = true end)
  assert(wait(function() return loaded end))
  eq(strip(t.events), strip(stored(s.events)))
  eq(t.agent_session_id, 'fake-session-1')
  eq(t.turn_start, #t.events + 1)
  -- unchanged file: not read again; a load while a process runs is skipped too
  local key = t.loaded_key
  loaded = false
  t:load(function() loaded = true end)
  assert(wait(function() return loaded end))
  eq(t.loaded_key, key)
end

T['scan lists logged sessions with agent, title (the first prompt), cwd and activity'] = function()
  script(acp.flat(acp.handshake(), { expect = '"session/prompt"' }, acp.chunk('a'), acp.end_turn()))
  local s = session.open({ cwd = dir, agent = 'fake' })
  s:send('first question\nsecond line')
  assert(wait(function() return s.state == 'done' and s.log:idle() end))
  local metas
  log.scan(function(list) metas = list end)
  assert(wait(function() return metas ~= nil end))
  eq(#metas, 1)
  local m = metas[1]
  eq({ m.id, m.agent, m.agent_session_id, m.cwd, m.title, m.path, type(m.activity) },
    { s.id, 'fake', 'fake-session-1', dir, 'first question second line', s.path, 'number' })
  -- through the index facade, merged with Claude's transcripts (none here)
  local all
  index.scan(function(list) all = list end, dir .. '/no-projects')
  assert(wait(function() return all ~= nil end))
  eq(#all, 1)
  eq(all[1].agent, 'fake')
  -- a header title wins over the first prompt
  s.log:meta({ title = 'named' })
  assert(wait(function() return s.log:idle() end))
  metas = nil
  log.scan(function(list) metas = list end)
  assert(wait(function() return metas ~= nil end))
  eq(metas[1].title, 'named')
end

T['resume: the agent loads its session (history first, then the load with its id)'] = function()
  script(acp.flat(acp.handshake(), { expect = '"session/prompt"' }, acp.chunk('one'), acp.end_turn()))
  local s = session.open({ cwd = dir, agent = 'fake' })
  s:send('q1')
  assert(wait(function() return s.state == 'done' and s.log:idle() end))
  session._reset()
  local lg = script(acp.flat({ expect = '"initialize"' }, { respond = acp.init_result() },
    { expect = '"session/load"' },
    { update = { sessionUpdate = 'user_message_chunk', content = { type = 'text', text = 'q1' } } }, -- the replay
    acp.chunk('one'),
    { respond = acp.new_result() },
    { expect = '"session/prompt"' }, acp.chunk('two'), acp.end_turn()))
  local t = session.open({ id = s.id, cwd = dir, agent = 'fake', agent_session_id = 'fake-session-1' })
  local loaded = false
  t:load(function() loaded = true end)
  assert(wait(function() return loaded end))
  eq(kinds(t.events), { 'prompt', 'text' })
  t:send('q2')
  assert(wait(function() return t.state == 'done' end))
  -- the replay added nothing (the log had it); the new turn follows the history
  eq(kinds(t.events), { 'prompt', 'text', 'prompt', 'text' })
  eq(t.events[4].text, 'two')
  local ins = acp.ins(lg)
  eq(ins[2].method, 'session/load')
  eq(ins[2].params, { sessionId = 'fake-session-1', cwd = dir, mcpServers = {} })
  -- the replay lines are in the raw view
  eq(#vim.tbl_filter(function(r) return r.line:find('user_message_chunk', 1, true) end, t.raw), 1)
end

T['resume: an agent that cannot load starts afresh with a notice; replay_context sends the past'] = function()
  script(acp.flat(acp.handshake(), { expect = '"session/prompt"' }, acp.chunk('one'), acp.end_turn()))
  local s = session.open({ cwd = dir, agent = 'fake' })
  s:send('q1')
  assert(wait(function() return s.state == 'done' and s.log:idle() end))
  session._reset()
  -- no loadSession: a new agent session, said so in the transcript (and the log)
  local lg = script(acp.flat(acp.handshake({ load = false }), { expect = '"session/prompt"' }, acp.chunk('two'), acp.end_turn()))
  local t = session.open({ id = s.id, cwd = dir, agent = 'fake', agent_session_id = 'fake-session-1' })
  local loaded = false
  t:load(function() loaded = true end)
  assert(wait(function() return loaded end))
  t:send('q2')
  assert(wait(function() return t.state == 'done' end))
  eq(kinds(t.events), { 'prompt', 'text', 'prompt', 'meta', 'text' })
  eq(t.events[4], { kind = 'meta', label = 'new session', text = 'New Fake session: the agent cannot reload the earlier conversation' })
  eq(acp.ins(lg)[2].method, 'session/new')
  eq(acp.ins(lg)[3].params.prompt[1].text, 'q2') -- replay_context off: the prompt as typed
  assert(wait(function() return t.log:idle() end))
  -- the load refused: the same, with the agent's reason; replay_context on: the past goes first
  session._reset()
  lg = script(acp.flat({ expect = '"initialize"' }, { respond = acp.init_result() },
    { expect = '"session/load"' }, { respond_error = { code = -32000, message = 'unknown session' } },
    { expect = '"session/new"' }, { respond = acp.new_result({ sid = 'fake-session-2' }) },
    { expect = '"session/prompt"' }, acp.chunk('three'), acp.end_turn()), { replay_context = true })
  local u = session.open({ id = s.id, cwd = dir, agent = 'fake' })
  loaded = false
  u:load(function() loaded = true end)
  assert(wait(function() return loaded end))
  eq(u.agent_session_id, 'fake-session-1') -- from the log's header
  eq(kinds(u.events), { 'prompt', 'text', 'prompt', 'meta', 'text' })
  u:send('q3')
  assert(wait(function() return u.state == 'done' end))
  -- the prompt was stored when sent (as typed), the notice came with the handshake after it
  eq(kinds(u.events), { 'prompt', 'text', 'prompt', 'meta', 'text', 'prompt', 'meta', 'text' })
  eq(u.events[6].text, 'q3')
  eq(u.events[7].text, 'New Fake session: the agent cannot reload the earlier conversation (unknown session)')
  eq(u.agent_session_id, 'fake-session-2')
  local wire = acp.ins(lg)[4].params.prompt[1].text
  eq(wire:sub(1, 40), 'Earlier conversation, for context (this ')
  eq(wire:find('User: q1\n\nAssistant: one\n\nUser: q2', 1, true) ~= nil, true)
  eq(vim.endswith(wire, 'Assistant: two\n\n---\n\nq3'), true) -- the prompt itself last, as typed
  assert(wait(function() return u.log:idle() end))
end

return T
