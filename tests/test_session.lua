local config = require('agent-ide.config')
local session = require('agent-ide.session')
local index = require('agent-ide.index')
local live = require('agent-ide.live')
local process = require('agent-ide.claude.process')
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality

local FIXTURE_ID = '11111111-1111-4111-8111-111111111111'
local FIXTURE = vim.fn.getcwd() .. '/tests/fixtures/projects/-home-u-git-alpha/' .. FIXTURE_ID .. '.jsonl'

local orig_notify, orig_confirm, orig_live_get, orig_history, orig_start, notes, dir

local function children()
  vim.fn.system({ 'pgrep', '-P', tostring(vim.fn.getpid()), '-f', 'fake_claude' })
  return vim.v.shell_error == 0
end

local function wait(pred, ms) return vim.wait(ms or 5000, pred, 10) end

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    config.setup({})
    notes = {}
    orig_notify, orig_confirm, orig_live_get = vim.notify, vim.fn.confirm, live.get
    orig_history, orig_start = index.history, process.start
    vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
  end,
  post_case = function()
    session._reset()
    vim.notify, vim.fn.confirm, live.get = orig_notify, orig_confirm, orig_live_get
    index.history, process.start = orig_history, orig_start
    vim.uv.os_unsetenv('FAKE_CLAUDE_LOG')
    config.setup({})
    vim.fn.delete(dir, 'rf')
  end,
  post_once = function()
    session._reset()
    -- nothing this file started may survive it
    assert(vim.wait(3000, function() return not children() end, 50), 'a fake Claude is still running')
  end,
} })

-- Scenario steps ------------------------------------------------------------------------

local function init(mode)
  return { emit = { type = 'system', subtype = 'init', session_id = 'x', model = 'claude-haiku-5-5',
    permissionMode = mode or 'default', slash_commands = { 'compact', 'context' }, claude_code_version = '2.1.306' } }
end
local function status() return { emit = { type = 'system', subtype = 'status', status = 'requesting' } } end
local function replay(t) return { emit = { type = 'user', message = { role = 'user', content = t }, isReplay = true } } end
local function block_start()
  return { emit = { type = 'stream_event', event = { type = 'content_block_start', index = 0,
    content_block = { type = 'text', text = '' } } } }
end
local function delta(t)
  return { emit = { type = 'stream_event', event = { type = 'content_block_delta', index = 0,
    delta = { type = 'text_delta', text = t } } } }
end
local function say(t)
  return { emit = { type = 'assistant', message = { id = 'm', type = 'message', role = 'assistant',
    content = { { type = 'text', text = t } } } } }
end
local function tool_use(id, name, input)
  return { emit = { type = 'assistant', message = { id = 'm', type = 'message', role = 'assistant',
    content = { { type = 'tool_use', id = id, name = name, input = input } } } } }
end
local function tool_result(id, text, is_error)
  return { emit = { type = 'user', message = { role = 'user',
    content = { { type = 'tool_result', tool_use_id = id, content = text, is_error = is_error } } } } }
end
local function ask(rid, name, input)
  return { emit = { type = 'control_request', request_id = rid, request = { subtype = 'can_use_tool',
    tool_name = name, display_name = name, input = input, description = 'b.txt', tool_use_id = 't2' } } }
end
local function result(t, is_error)
  return { emit = { type = 'result', subtype = 'success', is_error = is_error or false, result = t } }
end

-- A plain streamed turn answering `prompt` with `answer`.
local function turn(prompt, answer, mode)
  return { { expect = prompt }, init(mode), status(), replay(prompt), block_start(), delta(answer), say(answer), result(answer) }
end

-- Steps and lists of steps, flattened into one scenario.
local function flat(...)
  local out = {}
  for _, part in ipairs({ ... }) do
    if part[1] ~= nil then vim.list_extend(out, part) else out[#out + 1] = part end
  end
  return out
end

---Configure the fake for `steps`, return the log path.
local function script(steps)
  local cmd, log = fake.cmd(steps)
  config.setup({ claude = { cmd = cmd } })
  return log
end

local function new(opts)
  local s = session.open(vim.tbl_extend('force', { cwd = dir }, opts or {}))
  return s
end

local function kinds(events)
  local out = {}
  for i, e in ipairs(events) do out[i] = e.kind end
  return out
end

local function ins(log)
  local out = {}
  for _, l in ipairs(fake.log(log)) do
    if l['in'] then out[#out + 1] = vim.json.decode(l['in']) end
  end
  return out
end

local function argv(log) return fake.log(log)[1].argv end

-- Tests ---------------------------------------------------------------------------------

T['open: fresh UUID v4, same object for the same id, all in creation order'] = function()
  local a = new()
  eq(a.id:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') ~= nil, true)
  local b = new()
  eq(a.id ~= b.id, true)
  eq(session.open({ id = a.id, cwd = dir }), a)
  eq(session.get(b.id), b)
  eq(session.all(), { a, b })
  eq(a.state, 'idle')
  eq(new({ id = FIXTURE_ID, path = FIXTURE }).state, 'parked')
  eq({ a.events, a.streaming, a.turn_start, a.queue, a.pending_permissions, a.unread, a.owned, a.visible },
    { {}, '', 1, {}, {}, false, false, false })
end

T['new session happy path: idle -> busy -> idle, events prompt + text'] = function()
  local log = script(turn('hello', 'Hello there'))
  local s = new()
  s.visible = true
  local states, deltas = { s.state }, {}
  session.on_change(function(x, what)
    if x ~= s then return end
    if what == 'state' then states[#states + 1] = x.state end
    if what == 'delta' then deltas[#deltas + 1] = x.streaming end
  end)
  eq(s:send('hello'), true)
  eq(s.state, 'busy')
  eq(s.owned, true)
  assert(wait(function() return s.state == 'idle' end))
  eq(states, { 'idle', 'busy', 'idle' })
  eq(deltas, { 'Hello there' })
  eq(s.events, { { kind = 'prompt', text = 'hello' }, { kind = 'text', text = 'Hello there' } })
  eq(s.streaming, '')
  eq(s.turn_start, 1)
  eq(s.unread, false)
  eq(s.model, 'claude-haiku-5-5')
  eq(s.mode, 'manual')
  eq(s.slash_commands, { 'compact', 'context' })
  local a = argv(log)
  eq(a[#a - 1], '--session-id')
  eq(a[#a], s.id)
  eq(ins(log)[1], { type = 'user', message = { role = 'user', content = 'hello' } })
  -- raw lines both ways
  eq(s.raw[1].dir, 'out')
  eq(vim.json.decode(s.raw[1].line), ins(log)[1])
  eq(s.raw[#s.raw].dir, 'in')
end

T['empty prompt is refused'] = function()
  local s = new()
  eq({ s:send('') }, { false, 'empty' })
  eq({ s:send('  \n\t') }, { false, 'empty' })
  eq(s.events, {})
end

T['model from config is passed for a new session'] = function()
  local cmd, log = fake.cmd(turn('hi', 'yo'))
  config.setup({ claude = { cmd = cmd, model = 'haiku' } })
  local s = new()
  s:send('hi')
  assert(wait(function() return s.state == 'done' end))
  local a = argv(log)
  eq(vim.list_slice(a, #a - 3), { '--model', 'haiku', '--session-id', s.id })
end

T['tool turn'] = function()
  script(flat({ expect = 'list' }, init(), status(), replay('list'),
    tool_use('t1', 'Bash', { command = 'ls' }), tool_result('t1', 'a.txt'),
    status(), block_start(), delta('One file.'), say('One file.'), result('One file.')))
  local s = new()
  s.visible = true
  s:send('list')
  assert(wait(function() return s.state == 'idle' end))
  eq(s.events, {
    { kind = 'prompt', text = 'list' },
    { kind = 'tool_call', id = 't1', name = 'Bash', input = { command = 'ls' } },
    { kind = 'tool_result', id = 't1', text = 'a.txt', is_error = false },
    { kind = 'text', text = 'One file.' },
  })
end

T['queue: second prompt waits for the first result'] = function()
  local log = script(flat(
    { expect = 'alpha-prompt' }, init(), replay('alpha-prompt'), block_start(), delta('a1'), { sleep_ms = 300 },
    say('A says'), result('A says'),
    { expect = 'beta-prompt' }, init(), replay('beta-prompt'), say('B says'), result('B says')))
  local s = new()
  s.visible = true
  s:send('alpha-prompt')
  assert(wait(function() return s.streaming == 'a1' end))
  eq(s:send('beta-prompt'), true)
  eq(s.queue, { 'beta-prompt' })
  eq(#s.events, 1) -- queued prompts become events when their turn starts
  assert(wait(function() return s.state == 'idle' and #s.events == 4 end))
  eq(s.events, {
    { kind = 'prompt', text = 'alpha-prompt' }, { kind = 'text', text = 'A says' },
    { kind = 'prompt', text = 'beta-prompt' }, { kind = 'text', text = 'B says' },
  })
  eq(s.queue, {})
  eq(s.turn_start, 3)
  -- beta went out only after alpha's result came in
  local result_at, beta_at
  for i, r in ipairs(s.raw) do
    if r.dir == 'in' and r.line:find('"A says"') and r.line:find('"result"') then result_at = result_at or i end
    if r.dir == 'out' and r.line:find('beta-prompt', 1, true) then beta_at = i end
  end
  eq({ result_at ~= nil, beta_at ~= nil, (beta_at or 0) > (result_at or 0) }, { true, true, true })
  local sent = ins(log)
  eq({ sent[1].message.content, sent[2].message.content }, { 'alpha-prompt', 'beta-prompt' })
end

local WRITE_INPUT = { file_path = '/tmp/x/b.txt', content = 'x' }

local function permission_script(rid)
  return flat({ expect = 'write it' }, init(), replay('write it'), tool_use('t2', 'Write', WRITE_INPUT),
    ask(rid, 'Write', WRITE_INPUT), { expect = rid },
    { emit = { type = 'control_response', response = { subtype = 'success', request_id = rid } } }, -- echo of ours
    tool_result('t2', 'done'), say('Written.'), result('Written.'))
end

T['permission allow sends the exact control response'] = function()
  local log = script(permission_script('p1'))
  local s = new()
  s.visible = true
  local whats = {}
  session.on_change(function(_, what) whats[#whats + 1] = what end)
  s:send('write it')
  assert(wait(function() return s.state == 'waiting' end))
  eq(vim.tbl_contains(whats, 'permission'), true)
  eq(#s.pending_permissions, 1)
  local p = s.pending_permissions[1]
  eq({ p.request_id, p.tool_name, p.input, p.description }, { 'p1', 'Write', WRITE_INPUT, 'b.txt' })
  eq(s:answer('p1', true), true)
  eq(s.pending_permissions, {})
  eq(s.state, 'busy')
  assert(wait(function() return s.state == 'idle' end))
  eq(ins(log)[2], { type = 'control_response', response = { subtype = 'success', request_id = 'p1',
    response = { behavior = 'allow', updatedInput = WRITE_INPUT } } })
  eq(kinds(s.events), { 'prompt', 'tool_call', 'tool_result', 'text' })
end

T['permission deny sends the exact control response'] = function()
  local log = script(permission_script('p2'))
  local s = new()
  s:send('write it')
  assert(wait(function() return s.state == 'waiting' end))
  eq(s:answer('nope', true), false)
  eq(s:answer('p2', false), true)
  assert(wait(function() return s.state == 'done' end))
  eq(ins(log)[2], { type = 'control_response', response = { subtype = 'success', request_id = 'p2',
    response = { behavior = 'deny', message = 'Denied by user in Neovim' } } })
end

T['permission allow with updated input (question answers)'] = function()
  local log = script(permission_script('p3'))
  local s = new()
  s:send('write it')
  assert(wait(function() return s.state == 'waiting' end))
  local upd = { questions = { 'q' }, answers = { q = 'yes' } }
  s:answer('p3', true, { updated_input = upd })
  assert(wait(function() return s.state == 'done' end))
  eq(ins(log)[2].response.response, { behavior = 'allow', updatedInput = upd })
end

T['a setMode answer Claude never confirms is no longer pending after the turn'] = function()
  local log = script(permission_script('p4'))
  local s = new()
  s.visible = true
  s:send('write it')
  assert(wait(function() return s.state == 'waiting' end))
  local sugg = { type = 'setMode', mode = 'acceptEdits', destination = 'session' }
  s:answer('p4', true, { updated_permissions = { sugg } })
  eq(s.mode_requested, 'acceptEdits')
  assert(wait(function() return s.state == 'idle' end))
  eq(s.mode_requested, nil)
  eq(ins(log)[2].response.response.updatedPermissions, { sugg })
end

T['crash mid-answer keeps the partial text, then the next send resumes'] = function()
  script(flat({ expect = 'go' }, init(), replay('go'), block_start(), delta('partial '), delta('answer'),
    { sleep_ms = 100 }, { exit = 2 }))
  local s = new()
  s:send('go')
  s:send('queued one')
  assert(wait(function() return s.state == 'failed' end))
  eq(s.events, {
    { kind = 'prompt', text = 'go' },
    { kind = 'text', text = 'partial answer' },
    { kind = 'meta', label = 'error', text = 'Claude exited (code 2)', live_only = true },
  })
  eq(s.streaming, '')
  eq(s.unread, true)
  eq(s.queue, { 'queued one' })
  -- the next send starts a process that resumes the session; the queue goes first
  local log = script(flat(turn('queued one', 'Q'), turn('again', 'A')))
  eq(s:send('again'), true)
  assert(wait(function() return #fake.log(log) >= 1 end))
  local a = argv(log)
  eq(vim.list_slice(a, #a - 1), { '--resume', s.id })
  assert(wait(function() return #s.events == 7 end))
  eq(s.events[4], { kind = 'prompt', text = 'queued one' })
  eq(s.events[6], { kind = 'prompt', text = 'again' })
end

T['crash shows the stderr tail; visible gives idle'] = function()
  config.setup({ claude = { cmd = { 'sh', '-c', 'read l; echo "boom on stderr" >&2; exit 7' } } })
  local s = new()
  s.visible = true
  s:send('x')
  assert(wait(function() return s.state == 'idle' end))
  local last = s.events[#s.events]
  eq({ last.kind, last.label }, { 'meta', 'error' })
  eq(last.text, 'Claude exited (code 7)\nboom on stderr')
  eq(s.unread, false)
end

T['running elsewhere is refused'] = function()
  local s = new({ id = FIXTURE_ID, path = FIXTURE })
  live.get = function() return { [FIXTURE_ID] = { status = 'busy' } } end
  eq({ s:send('hi') }, { false, 'running elsewhere' })
  eq(s.events, {})
end

T['ownership follows our process: own stale live entry ok, terminal after park refused'] = function()
  script(flat(turn('hi', 'yo'), { exit = 0 }))
  local s = new()
  s:send('hi')
  assert(wait(function() return s.state == 'done' and s.proc == nil end))
  eq(s.owned, false)
  local pid = s.pid
  eq(type(pid), 'number')
  -- the live map still lists our dead process: not "elsewhere"
  live.get = function() return { [s.id] = { status = 'busy', pid = pid } } end
  script(turn('again', 'ok'))
  eq(s:send('again'), true)
  eq(s.owned, true)
  assert(wait(function() return #s.events == 4 and s.state == 'done' end))
  local got
  s:park(function(ok) got = ok end)
  assert(wait(function() return got ~= nil end))
  eq(s.owned, false)
  -- the user resumed it in a terminal: another pid
  live.get = function() return { [s.id] = { status = 'busy', pid = 1 } } end
  eq({ s:send('third') }, { false, 'running elsewhere' })
end

T['a process that exits right after start fails the turn'] = function()
  script({ { exit = 3 } })
  local s = new()
  eq(s:send('hi'), true)
  assert(wait(function() return s.state == 'failed' end))
  eq(s.events, { { kind = 'prompt', text = 'hi' },
    { kind = 'meta', label = 'error', text = 'Claude exited (code 3)', live_only = true } })
end

T['a failed prompt write stops the process and fails the turn'] = function()
  script({ { expect = 'never-sent' } })
  process.start = function(opts)
    local p, err = orig_start(opts)
    if p then p.send = function() return false end end
    return p, err
  end
  local s = new()
  eq(s:send('hi'), true)
  assert(wait(function() return s.state == 'failed' end))
  eq(s.events[1], { kind = 'prompt', text = 'hi' })
  eq({ s.events[2].kind, s.events[2].label, s.events[2].live_only }, { 'meta', 'error', true })
  eq(s.proc, nil)
end

T['echo mismatch warns once per session'] = function()
  script(flat({ expect = 'one' }, init(), replay('ONE'), say('a'), result('a'),
    { expect = 'two' }, init(), replay('TWO'), say('b'), result('b')))
  local s = new()
  s.visible = true
  s:send('one')
  assert(wait(function() return s.state == 'idle' end))
  s:send('two')
  assert(wait(function() return s.state == 'idle' and #s.events == 6 end))
  local warn = { kind = 'meta', label = 'warning', text = 'Prompt echoed by Claude differs from what was sent',
    live_only = true }
  eq(s.events[2], warn)
  eq(s.events[5], warn)
  local warns = vim.tbl_filter(function(n) return n.level == vim.log.levels.WARN end, notes)
  eq(#warns, 1)
end

T['a prompt with inline and line attachments echoes back without a warning'] = function()
  local text = require('agent-ide.ui.prompt').text_to_send({ 'Intro, see @a.lua for it.', '', '[attach] my notes.md',
    'and @"dir ü/b 1.md" here', '```', '[attach] kept', '```' })
  eq(text, 'Intro, see @a.lua for it.\n\n@"my notes.md"\nand @"dir ü/b 1.md" here\n```\n[attach] kept\n```')
  script(flat({ expect = 'Intro' }, init(), replay(text), say('a'), result('a')))
  local s = new()
  s.visible = true
  s:send(text)
  assert(wait(function() return s.state == 'idle' end))
  eq(kinds(s.events), { 'prompt', 'text' })
  eq(s.events[1].text, text)
  eq(vim.tbl_filter(function(n) return n.level == vim.log.levels.WARN end, notes), {})
end

T['done when not visible, mark_seen makes it idle; error result gives failed'] = function()
  script(flat(turn('q1', 'a1'), { expect = 'q2' }, init(), replay('q2'), say('API down'), result('API down', true)))
  local s = new()
  s:send('q1')
  assert(wait(function() return s.state == 'done' end))
  eq(s.unread, true)
  s:mark_seen()
  eq({ s.state, s.unread }, { 'idle', false })
  s:send('q2')
  assert(wait(function() return s.state == 'failed' end))
  eq(s.events[#s.events], { kind = 'meta', label = 'error', text = 'API down', live_only = true })
  s:mark_seen()
  eq(s.state, 'idle')
end

T['load of a transcript, then send resumes'] = function()
  local s = new({ id = FIXTURE_ID, path = FIXTURE })
  local expected
  index.history(FIXTURE, function(evs) expected = evs end)
  assert(wait(function() return expected ~= nil end))
  local done = 0
  s:load(function() done = done + 1 end)
  assert(wait(function() return done == 1 end))
  eq(s.events, expected)
  eq(s.turn_start, #expected + 1)
  s:load(function() done = done + 1 end) -- unchanged file: no reload, still calls back
  assert(wait(function() return done == 2 end))
  eq(s.events, expected)
  local log = script(turn('more', 'ok'))
  s:send('more')
  assert(wait(function() return s.state == 'done' end))
  local a = argv(log)
  eq(vim.list_slice(a, #a - 1), { '--resume', FIXTURE_ID })
  eq(s.turn_start, #expected + 1)
  eq(s.events[#expected + 1], { kind = 'prompt', text = 'more' })
end

T['send during a load keeps the history before the live events'] = function()
  local s = new({ id = FIXTURE_ID, path = FIXTURE })
  local expected
  orig_history(FIXTURE, function(evs) expected = evs end)
  assert(wait(function() return expected ~= nil end))
  local release
  index.history = function(p, cb) release = function() orig_history(p, cb) end end
  local loaded = false
  s:load(function() loaded = true end)
  assert(wait(function() return release ~= nil end))
  script(turn('more', 'ok'))
  s:send('more')
  release()
  assert(wait(function() return loaded and s.state == 'done' end))
  eq(#s.events, #expected + 2)
  eq(vim.list_slice(s.events, 1, #expected), expected)
  eq(s.events[#expected + 1], { kind = 'prompt', text = 'more' })
  eq(s.events[#expected + 2], { kind = 'text', text = 'ok' })
  eq(s.turn_start, #expected + 1)
end

T['load reloads when the file changed and no process is alive'] = function()
  local path = dir .. '/s.jsonl'
  vim.fn.writefile({ '{"type":"user","message":{"role":"user","content":"first"}}' }, path)
  local s = new({ id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', path = path })
  local n = 0
  s:load(function() n = n + 1 end)
  assert(wait(function() return n == 1 end))
  eq(s.events, { { kind = 'prompt', text = 'first' } })
  vim.fn.writefile({ '{"type":"user","message":{"role":"user","content":"first"}}',
    '{"type":"user","message":{"role":"user","content":"second"}}' }, path)
  s:load(function() n = n + 1 end)
  assert(wait(function() return n == 2 end))
  eq(kinds(s.events), { 'prompt', 'prompt' })
  eq(s.turn_start, 3)
  -- a shorter file: turn_start does not move backwards
  vim.fn.writefile({ '{"type":"user","message":{"role":"user","content":"only"}}' }, path)
  vim.uv.fs_utime(path, 1, 1)
  s:load(function() n = n + 1 end)
  assert(wait(function() return n == 3 end))
  eq(s.events, { { kind = 'prompt', text = 'only' } })
  eq(s.turn_start, 3)
end

T['park while busy asks; declined keeps it running; accepted parks'] = function()
  script(flat({ expect = 'long' }, init(), replay('long'), block_start(), delta('working')))
  local s = new()
  s:send('long')
  assert(wait(function() return s.streaming == 'working' end))
  local asked = 0
  vim.fn.confirm = function() asked = asked + 1; return 2 end
  local got
  s:park(function(ok) got = ok end)
  assert(wait(function() return got ~= nil end))
  eq({ got, asked, s.state }, { false, 1, 'busy' })
  vim.fn.confirm = function() asked = asked + 1; return 1 end
  got = nil
  s:park(function(ok) got = ok end)
  assert(wait(function() return got ~= nil end))
  eq({ got, asked, s.state, s.owned }, { true, 2, 'parked', false })
  eq(s.events[#s.events], { kind = 'text', text = 'working' })
  eq(children(), false)
end

T['interrupt drops the queue and the error result starts no turn'] = function()
  local log = script(flat({ expect = 'first' }, init(), replay('first'), block_start(), delta('x'),
    { expect = 'interrupt' }, say('x'), result(nil, true)))
  local s = new()
  local sizes = {}
  session.on_change(function(_, what) if what == 'meta' then sizes[#sizes + 1] = #s.queue end end)
  s:send('first')
  assert(wait(function() return s.streaming == 'x' end))
  s:send('second')
  s:send('third')
  eq(s.queue, { 'second', 'third' })
  local dropped, sent = s:interrupt()
  eq({ dropped, sent, s.queue }, { { 'second', 'third' }, true, {} })
  s:send('late') -- queued while the interrupted turn ends
  assert(wait(function() return s.state == 'failed' end))
  vim.wait(200)
  eq(s.queue, { 'late' })
  for _, l in ipairs(ins(log)) do eq(l.type == 'user' and l.message.content ~= 'first', false) end
  eq(vim.tbl_contains(sizes, 1) and vim.tbl_contains(sizes, 2) and vim.tbl_contains(sizes, 0), true)
end

T['park drops the queue and hands it to the callback; a send while parking is queued'] = function()
  script(flat({ expect = 'long' }, init(), replay('long'), block_start(), delta('working')))
  local s = new()
  s:send('long')
  assert(wait(function() return s.streaming == 'working' end))
  s:send('q1')
  vim.fn.confirm = function() return 1 end
  local got, dropped
  s:park(function(ok, d) got, dropped = ok, d end)
  eq(s.queue, {})
  eq(s:send('while parking'), true)
  assert(wait(function() return got ~= nil end))
  eq({ got, dropped, s.state, s.queue }, { true, { 'q1' }, 'parked', { 'while parking' } })
end

T['park when idle does not ask'] = function()
  script(turn('hi', 'yo'))
  local s = new()
  s:send('hi')
  assert(wait(function() return s.state == 'done' end))
  vim.fn.confirm = function() error('must not ask') end
  local got
  s:park(function(ok) got = ok end)
  assert(wait(function() return got ~= nil end))
  eq({ got, s.state }, { true, 'parked' })
end

T['set_mode, set_model and interrupt send control requests'] = function()
  local log = script(flat({ expect = 'start' }, init(), replay('start'),
    { expect = 'set_permission_mode' }, { expect = 'set_model' }, { expect = 'interrupt' },
    { emit = { type = 'control_response', response = { subtype = 'error', request_id = 'r2', error = "Model 'sonnet' not found" } } },
    { emit = { type = 'control_response', response = { subtype = 'success', request_id = 'unrelated' } } },
    result(nil, true)))
  local s = new()
  s.visible = true
  s:send('start')
  eq(s:set_mode('plan'), true)
  eq(s:set_model('sonnet'), true)
  eq({ s:interrupt() }, { {}, true })
  assert(wait(function() return s.state == 'idle' end))
  local sent = ins(log)
  eq(sent[2], { type = 'control_request', request_id = 'r1', request = { subtype = 'set_permission_mode', mode = 'plan' } })
  eq(sent[3], { type = 'control_request', request_id = 'r2', request = { subtype = 'set_model', model = 'sonnet' } })
  eq(sent[4], { type = 'control_request', request_id = 'r3', request = { subtype = 'interrupt' } })
  eq(s.events[#s.events - 1], { kind = 'meta', label = 'error', text = "set_model: Model 'sonnet' not found", live_only = true })
  eq(s.events[#s.events], { kind = 'meta', label = 'error', text = 'Turn failed', live_only = true })
end

-- What the real Claude streams and what it writes to the transcript for a model switch between
-- turns, a local slash command and an interrupt (shapes as in docs/protocol.md): the session's
-- events must equal the parsed transcript (history equals live).
T['history equals live: model switch, /context and interrupt'] = function()
  local stdout = '<local-command-stdout>Set model to `sonnet (claude-sonnet-5-5)`</local-command-stdout>'
  local log = script(flat(turn('hi', 'yo'),
    { expect = 'set_model' }, replay(stdout),
    { emit = { type = 'control_response', response = { subtype = 'success', request_id = 'r1' } } },
    { expect = '/context' }, init(),
    { emit = { type = 'assistant', message = { model = '<synthetic>', role = 'assistant',
      content = { { type = 'text', text = '## Context\n\nrows' } } }, local_command_run = { command = 'context', args = '' },
      local_command_source = '<local-command-stdout>## Context\n\nrows\n\n</local-command-stdout>' } },
    result('## Context\n\nrows'),
    { expect = 'Count' }, init(), status(), replay('Count'), block_start(), delta('1\n2'),
    { expect = 'interrupt' },
    { emit = { type = 'control_response', response = { subtype = 'success', request_id = 'r2', response = { still_queued = {} } } } },
    { emit = { type = 'assistant', message = { id = 'm', role = 'assistant', content = { { type = 'text', text = '1\n2' } } }, aborted = true } },
    { emit = { type = 'user', message = { role = 'user', content = { { type = 'text', text = '[Request interrupted by user]' } } } } },
    { emit = { type = 'result', subtype = 'error_during_execution', is_error = true, errors = { 'aborted' } } }))
  local s = new()
  s.visible = true
  s:send('hi')
  assert(wait(function() return s.state == 'idle' end))
  s:set_model('sonnet')
  assert(wait(function() return s.model == 'sonnet' end))
  s:send('/context')
  assert(wait(function() return s.state == 'idle' and #s.events >= 5 end))
  s:send('Count')
  assert(wait(function() return s.streaming ~= '' end))
  s:interrupt()
  assert(wait(function() return s.state == 'idle' and #s.events >= 9 end))
  eq(#ins(log), 5)
  -- the transcript Claude writes for the same conversation (bookkeeping records left out)
  local function rec(t) return vim.json.encode(t) end
  local function user(c, meta) return rec({ type = 'user', isMeta = meta, message = { role = 'user', content = c } }) end
  local function assistant(t) return rec({ type = 'assistant', message = { role = 'assistant', content = { { type = 'text', text = t } } } }) end
  local caveat = '<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>'
  local file = table.concat({
    user('hi'), assistant('yo'),
    user(caveat, true), user('<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>sonnet</command-args>'),
    user(stdout),
    user(caveat, true), user('<command-name>/context</command-name>\n            <command-message>context</command-message>\n            <command-args></command-args>'),
    rec({ type = 'system', subtype = 'local_command', content = '<local-command-stdout>## Context\n\nrows\n\n</local-command-stdout>', level = 'info' }),
    user('Count'), assistant('1\n2'),
    rec({ type = 'user', message = { role = 'user', content = { { type = 'text', text = '[Request interrupted by user]' } } } }),
  }, '\n') .. '\n'
  local history = require('agent-ide.transcript.parse').parse_text(file)
  eq(vim.tbl_filter(function(e) return not e.live_only end, s.events), history)
end

T['set_mode before a process runs is sent right after start'] = function()
  local log = script(turn('hi', 'yo'))
  local s = new()
  eq({ s:interrupt() }, { {}, false })
  eq(s:set_mode('plan'), true)
  s:send('hi')
  assert(wait(function() return s.state == 'done' end))
  local sent = ins(log)
  eq(sent[1].request, { subtype = 'set_permission_mode', mode = 'plan' })
  eq(sent[2].type, 'user')
end

T['unknown objects and garbage lines become unknown events'] = function()
  script(flat({ expect = 'hi' }, init(), replay('hi'), { emit_raw = 'not json at all\n' },
    { emit = { type = 'mystery', n = 1 } }, say('ok'), result('ok')))
  local s = new()
  s:send('hi')
  assert(wait(function() return s.state == 'done' end))
  eq(s.events[2], { kind = 'unknown', label = 'not JSON', raw = 'not json at all', live_only = true })
  eq({ s.events[3].kind, s.events[3].label, s.events[3].live_only }, { 'unknown', 'mystery', true })
  eq(vim.json.decode(s.events[3].raw), { type = 'mystery', n = 1 })
end

T['a turn Claude starts on its own goes busy and appends to the current turn'] = function()
  script(flat(turn('hi', 'yo'), { sleep_ms = 200 }, init(), status(), say('background done'), result('background done')))
  local s = new()
  s.visible = true
  local states = {}
  session.on_change(function(x, what) if what == 'state' then states[#states + 1] = x.state end end)
  s:send('hi')
  assert(wait(function() return #s.events == 3 and s.state == 'idle' end))
  eq(states, { 'busy', 'idle', 'busy', 'idle' })
  eq(s.turn_start, 1)
  eq(s.events[3], { kind = 'text', text = 'background done' })
end

T['quota is forwarded and kept; a raising listener warns once'] = function()
  script(flat({ expect = 'hi' }, init(), replay('hi'),
    { emit = { type = 'rate_limit_event', rate_limit_info = { unifiedWindows = {
      five_hour = { utilization = 0.07, resetsAt = 100 } } } } }, say('ok'), result('ok')))
  local quotas = 0
  session.on_change(function() error('listener broke') end)
  local function counter(_, what) if what == 'quota' then quotas = quotas + 1 end end
  session.on_change(counter)
  local s = new()
  s:send('hi')
  assert(wait(function() return s.state == 'done' end))
  eq(quotas, 1)
  eq(session.quota(), { five_hour = { utilization = 0.07, resets_at = 100 } })
  local warns = vim.tbl_filter(function(n) return n.msg:find('listener broke', 1, true) ~= nil end, notes)
  eq(#warns, 1)
  session.off_change(counter)
  s:mark_seen()
  eq(quotas, 1)
end

T['raw is capped at the newest 5000 lines'] = function()
  local steps = { { expect = 'hi' }, init(), replay('hi') }
  local chunk = {}
  for i = 1, 5100 do chunk[#chunk + 1] = vim.json.encode({ type = 'system', subtype = 'thinking_tokens', n = i }) end
  steps[#steps + 1] = { emit_raw = table.concat(chunk, '\n') .. '\n' }
  vim.list_extend(steps, { say('ok'), result('ok') })
  script(steps)
  local s = new()
  s:send('hi')
  assert(wait(function() return s.state == 'done' end, 10000))
  eq(#s.raw, 5000)
  eq(s.raw[#s.raw].line:find('"result"') ~= nil, true)
end

return T
