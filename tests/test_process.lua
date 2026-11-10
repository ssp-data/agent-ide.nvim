local config = require('agent-ide.config')
local process = require('agent-ide.claude.process')
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality

local FIXED = {
  '-p', '--verbose', '--input-format', 'stream-json', '--output-format', 'stream-json',
  '--include-partial-messages', '--replay-user-messages',
  '--permission-prompts', 'host', '--permission-prompt-tool', 'stdio',
}
local procs, orig_notify, notes

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    config.setup({})
    procs, notes = {}, {}
    orig_notify = vim.notify
    vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
  end,
  post_case = function()
    for _, p in ipairs(procs) do p:stop(nil, true) end
    vim.wait(2000, function()
      for _, p in ipairs(procs) do if p:alive() then return false end end
      return true
    end, 10)
    vim.notify = orig_notify
    vim.uv.os_unsetenv('ANTHROPIC_API_KEY')
    vim.uv.os_unsetenv('FAKE_CLAUDE_LOG')
    config.setup({})
  end,
} })

local function wait(pred, ms) return vim.wait(ms or 5000, pred, 10) end

--- Start the fake with a scenario; returns proc and a record of callbacks.
local function run(scenario, extra)
  local cmd, log = fake.cmd(scenario)
  config.setup({ claude = vim.tbl_extend('force', { cmd = cmd }, (extra and extra.claude) or {}) })
  local rec = { objs = {}, raws = {}, garbage = {}, exits = {}, log = log }
  local opts = vim.tbl_extend('force', {
    session_id = 'sid-1',
    on_object = function(o, raw) rec.objs[#rec.objs + 1] = o; rec.raws[#rec.raws + 1] = raw end,
    on_garbage = function(l) rec.garbage[#rec.garbage + 1] = l end,
    on_exit = function(code, sig, tail) rec.exits[#rec.exits + 1] = { code, sig, tail } end,
  }, (extra and extra.start) or {})
  local p = assert(process.start(opts))
  procs[#procs + 1] = p
  return p, rec
end

local function children(pat)
  vim.fn.system({ 'pgrep', '-P', tostring(vim.fn.getpid()), '-f', pat })
  return vim.v.shell_error == 0
end

T['args: new session, resume, model, custom cmd'] = function()
  local expected = vim.list_extend({ 'claude' }, FIXED)
  eq(process.args({ session_id = 'abc' }), vim.list_extend(vim.deepcopy(expected), { '--session-id', 'abc' }))
  eq(process.args({ session_id = 'abc', resume = true }), vim.list_extend(vim.deepcopy(expected), { '--resume', 'abc' }))
  eq(process.args({ session_id = 'abc', model = 'haiku' }),
    vim.list_extend(vim.deepcopy(expected), { '--model', 'haiku', '--session-id', 'abc' }))
  eq(process.args({ session_id = 'abc', model = 'haiku', resume = true }),
    vim.list_extend(vim.deepcopy(expected), { '--resume', 'abc' }))
  config.setup({ claude = { cmd = { 'nvim', '-l', 'x.lua' } } })
  local a = process.args({ session_id = 'abc' })
  eq(vim.list_slice(a, 1, 4), { 'nvim', '-l', 'x.lua', '-p' })
  eq(a[#a], 'abc')
end

T['the fake receives the argv'] = function()
  local p, rec = run({ { expect = 'never' } })
  assert(wait(function() return #fake.log(rec.log) >= 1 end))
  local argv = fake.log(rec.log)[1].argv
  eq(vim.list_slice(argv, 2), vim.list_extend(vim.deepcopy(FIXED), { '--session-id', 'sid-1' }))
  p:stop()
end

T['ANTHROPIC_API_KEY is stripped'] = function()
  vim.uv.os_setenv('ANTHROPIC_API_KEY', 'secret')
  local p, rec = run({})
  assert(wait(function() return #fake.log(rec.log) >= 1 end))
  eq(fake.log(rec.log)[1].api_key_set, false)
  p:stop()
end

T['strip_api_key = false keeps the variable'] = function()
  vim.uv.os_setenv('ANTHROPIC_API_KEY', 'secret')
  local p, rec = run({}, { claude = { strip_api_key = false } })
  assert(wait(function() return #fake.log(rec.log) >= 1 end))
  eq(fake.log(rec.log)[1].api_key_set, true)
  p:stop()
end

T['works when the variable is absent'] = function()
  vim.uv.os_unsetenv('ANTHROPIC_API_KEY')
  local p, rec = run({})
  assert(wait(function() return #fake.log(rec.log) >= 1 end))
  eq(fake.log(rec.log)[1].api_key_set, false)
  p:stop()
end

T['other environment variables are passed on'] = function()
  vim.uv.os_setenv('AGENT_IDE_PROBE', 'xyz')
  local cmd = { 'sh', '-c', 'echo "$AGENT_IDE_PROBE:$HOME:$PATH" > "$FAKE_CLAUDE_LOG"' }
  config.setup({ claude = { cmd = cmd } })
  local log = vim.fn.tempname()
  vim.uv.os_setenv('FAKE_CLAUDE_LOG', log)
  local done = false
  local p = assert(process.start({ session_id = 's', on_exit = function() done = true end }))
  procs[#procs + 1] = p
  assert(wait(function() return done end))
  eq(vim.fn.readfile(log)[1], 'xyz:' .. vim.env.HOME .. ':' .. vim.env.PATH)
  vim.uv.os_unsetenv('AGENT_IDE_PROBE')
end

T['objects arrive in order, split mid-line and two per chunk'] = function()
  local p, rec = run({
    { emit_raw = '{"n":1,"t' },
    { sleep_ms = 80 },
    { emit_raw = 'ext":"a"}\n{"n":2}\n{"n":3}\n' },
    { sleep_ms = 80 },
    { emit_raw = '{"n":4}' },
    { emit_raw = '\n' },
  })
  assert(wait(function() return #rec.objs == 4 end))
  eq({ rec.objs[1].n, rec.objs[2].n, rec.objs[3].n, rec.objs[4].n }, { 1, 2, 3, 4 })
  eq(rec.objs[1].text, 'a')
  eq(rec.raws[2], '{"n":2}')
  p:stop()
end

T['array nulls stay vim.NIL, object nulls are dropped'] = function()
  local p, rec = run({ { emit_raw = '{"a":[1,null],"b":null}\n' } })
  assert(wait(function() return #rec.objs == 1 end))
  eq(rec.objs[1].b, nil)
  eq(rec.objs[1].a[2], vim.NIL)
  p:stop()
end

T['non-JSON lines go to on_garbage; blank lines are ignored'] = function()
  local p, rec = run({
    { emit_raw = 'not json\n\n   \n[1,2]\n"str"\n{"ok":true}\n' },
  })
  assert(wait(function() return #rec.objs == 2 end))
  eq(rec.garbage, { 'not json', '"str"' }) -- arrays decode to a table: delivered as objects
  eq(rec.raws, { '[1,2]', '{"ok":true}' })
  p:stop()
end

T['a raising callback does not break the reader; warned once'] = function()
  local n = 0
  local p, rec = run({ { emit_raw = '{"n":1}\n{"n":2}\n{"n":3}\n' } }, {
    start = { on_object = function() n = n + 1; error('boom') end },
  })
  assert(wait(function() return n == 3 end))
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.WARN)
  p:stop()
  assert(wait(function() return #rec.exits == 1 end))
end

T['send writes one line the fake logs byte-exactly'] = function()
  local p, rec = run({ { expect = 'zzz-never' } })
  local text = 'line1\nline2\ttab "quote" back\\slash ünï 日本 \027esc'
  local obj = { type = 'user', message = { role = 'user', content = text } }
  assert(wait(function() return p:alive() end))
  eq(p:send(obj), true)
  assert(wait(function() return #fake.log(rec.log) >= 2 end))
  local got = fake.log(rec.log)[2]['in']
  eq(got, vim.json.encode(obj))
  eq(vim.json.decode(got).message.content, text)
  eq(got:find('\n', 1, true), nil)
  p:stop()
end

T['exit code 3: on_exit once, alive false, send returns false'] = function()
  local p, rec = run({ { exit = 3 } })
  assert(wait(function() return #rec.exits == 1 end))
  eq(rec.exits[1][1], 3)
  eq(p:alive(), false)
  eq(p:send({ a = 1 }), false)
  vim.wait(200)
  eq(#rec.exits, 1)
end

T['on_exit comes after all objects of the output received'] = function()
  local order = {}
  local p, rec = run({ { emit_raw = '{"n":1}\n{"n":2}\n{"n":3}' }, { exit = 0 } }, {
    start = {
      on_object = function(o) order[#order + 1] = 'o' .. o.n end,
      on_exit = function() order[#order + 1] = 'exit' end,
    },
  })
  assert(wait(function() return order[#order] == 'exit' end))
  eq(order, { 'o1', 'o2', 'o3', 'exit' }) -- unterminated last line is delivered at exit
end

T['stderr tail is passed to on_exit (last 2 KiB)'] = function()
  local cmd = { 'sh', '-c', 'i=0; while [ $i -lt 400 ]; do echo "err line $i" >&2; i=$((i+1)); done' }
  config.setup({ claude = { cmd = cmd } })
  local tail
  local p = assert(process.start({ session_id = 's', on_exit = function(_, _, t) tail = t end }))
  procs[#procs + 1] = p
  assert(wait(function() return tail ~= nil end))
  eq(#tail <= 2048, true)
  eq(tail:match('err line 399\n$') ~= nil, true)
end

T['stop on a fake that ignores stdin: gone within 2 s, on_exit once, cb once'] = function()
  local p, rec = run({ { ignore_stdin = true } })
  assert(wait(function() return #fake.log(rec.log) >= 1 end))
  local cbs = 0
  p:stop(function() cbs = cbs + 1 end)
  p:stop(function() cbs = cbs + 1 end) -- twice is safe
  assert(wait(function() return #rec.exits == 1 end, 2000))
  assert(wait(function() return cbs == 2 end, 500))
  eq(p:alive(), false)
  vim.wait(300)
  eq(#rec.exits, 1)
  eq(p:send({ a = 1 }), false)
end

T['stop on a well-behaved fake exits at once via EOF without SIGTERM'] = function()
  local p, rec = run({})
  assert(wait(function() return #fake.log(rec.log) >= 1 end))
  p:stop()
  assert(wait(function() return #rec.exits == 1 end, 400))
  eq({ rec.exits[1][1], rec.exits[1][2] }, { 0, 0 })
end

T['stop after exit just calls cb'] = function()
  local p, rec = run({ { exit = 0 } })
  assert(wait(function() return #rec.exits == 1 end))
  local called = false
  p:stop(function() called = true end)
  assert(wait(function() return called end, 500))
end

T['cwd is honoured'] = function()
  local dir = vim.uv.fs_realpath(vim.fn.tempname() .. '') or vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  dir = vim.uv.fs_realpath(dir)
  local before = vim.uv.cwd()
  local p, rec = run({}, { start = { cwd = dir } })
  assert(wait(function() return #fake.log(rec.log) >= 1 end))
  eq(fake.log(rec.log)[1].cwd, dir)
  eq(vim.uv.cwd(), before)
  p:stop()
  vim.fn.delete(dir, 'rf')
end

T['--version of the fake'] = function()
  local cmd = fake.cmd({})
  local out = vim.system(vim.list_extend(vim.deepcopy(cmd), { '--version' }), { text = true }):wait()
  eq(out.stdout, '2.1.306 (Claude Code)\n')
  eq(out.code, 0)
end

T['start with a missing executable returns an error'] = function()
  config.setup({ claude = { cmd = { '/nonexistent/claude-xyz' } } })
  local p, err = process.start({ session_id = 's' })
  eq(p, nil)
  eq(type(err), 'string')
end

T['no process is left behind'] = function()
  local a = run({ { ignore_stdin = true } })
  local b = run({})
  assert(wait(function() return children('fake_claude') end))
  a:stop(); b:stop()
  assert(wait(function() return not children('fake_claude') end, 2000))
end

return T
