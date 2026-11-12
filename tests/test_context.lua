-- The size of a session's conversation: from `usage` objects (claude/usage.lua) and from the
-- end of a transcript (session/context.lua). Synthetic records only.
local usage = require('agent-ide.claude.usage')
local context = require('agent-ide.session.context')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function rec(t) return vim.json.encode(t) end
local function assistant(u, extra)
  return rec(vim.tbl_extend('force', { type = 'assistant', uuid = 'a',
    message = { role = 'assistant', model = 'claude-haiku-5-5', content = { { type = 'text', text = 'hi' } }, usage = u } },
    extra or {}))
end

T['usage.context: the input of the request, cached or not; nil without numbers'] = function()
  eq(usage.context({ input_tokens = 10, cache_read_input_tokens = 120000, cache_creation_input_tokens = 3000, output_tokens = 5 }), 123010)
  eq(usage.context({ input_tokens = 7 }), 7)
  eq(usage.context({ output_tokens = 5 }), nil)
  eq(usage.context({}), nil)
  eq(usage.context(nil), nil)
  eq(usage.context('x'), nil)
end

T['usage.fmt'] = function()
  eq(usage.fmt(850), '850')
  eq(usage.fmt(1000), '1k')
  eq(usage.fmt(1234), '1.2k')
  eq(usage.fmt(5000), '5k')
  eq(usage.fmt(9950), '10k')
  eq(usage.fmt(9940), '9.9k')
  eq(usage.fmt(12345), '12k')
  eq(usage.fmt(123010), '123k')
  eq(usage.fmt(999600), '1000k')
  eq(usage.fmt(1200000), '1.2M')
  eq(usage.fmt(2000000), '2M')
end

T['from_lines: the last main-conversation assistant message counts'] = function()
  eq(context.from_lines({
    assistant({ input_tokens = 1, cache_read_input_tokens = 50 }),
    rec({ type = 'user', message = { role = 'user', content = 'next' } }),
    assistant({ input_tokens = 10, cache_read_input_tokens = 120000, cache_creation_input_tokens = 3000 }),
    rec({ type = 'user', message = { role = 'user', content = { { type = 'tool_result', content = 'x' } } } }),
  }), 123010)
end

T['from_lines: subagent, synthetic and usage-less messages are skipped'] = function()
  eq(context.from_lines({
    assistant({ input_tokens = 100 }),
    assistant({ input_tokens = 999 }, { isSidechain = true }),
    assistant({ input_tokens = 0, output_tokens = 0 }, { message = { role = 'assistant', model = '<synthetic>',
      content = { { type = 'text', text = 'ctx' } }, usage = { input_tokens = 5 } } }),
    assistant(nil),
    'not json at all',
    rec({ type = 'assistant', message = 'odd' }),
  }), 100)
end

T['from_lines: a compaction after the last message gives its size, or nothing'] = function()
  eq(context.from_lines({
    assistant({ input_tokens = 200000 }),
    rec({ type = 'system', subtype = 'compact_boundary', content = 'Conversation compacted',
      compactMetadata = { trigger = 'manual', preTokens = 200000, postTokens = 9000 } }),
  }), 9000)
  eq(context.from_lines({
    assistant({ input_tokens = 200000 }),
    rec({ type = 'system', subtype = 'compact_boundary', content = 'Conversation compacted' }),
  }), nil)
  -- a message after the compaction counts again
  eq(context.from_lines({
    rec({ type = 'system', subtype = 'compact_boundary', compactMetadata = { postTokens = 9000 } }),
    assistant({ input_tokens = 12000 }),
  }), 12000)
  eq(context.from_lines({}), nil)
end

T['model_from_lines: the model of the last main-conversation answer'] = function()
  local function with_model(m, extra)
    return assistant({ input_tokens = 1 }, vim.tbl_extend('force', { message = { role = 'assistant', model = m,
      content = { { type = 'text', text = 'hi' } }, usage = { input_tokens = 1 } } }, extra or {}))
  end
  eq(context.model_from_lines({
    with_model('claude-opus-5-5'),
    with_model('claude-sonnet-5-5'),
    with_model('claude-haiku-5-5', { isSidechain = true }),
    with_model('<synthetic>'),
    rec({ type = 'user', message = { role = 'user', content = 'next' } }),
  }), 'claude-sonnet-5-5')
  eq(context.model_from_lines({ rec({ type = 'user', message = { role = 'user', content = 'x' } }) }), nil)
end

T['refresh: the transcript\'s model is what the session starts with, not the one last used elsewhere'] = function()
  require('agent-ide.config').setup({})
  local prefs = require('agent-ide.prefs')
  local session = require('agent-ide.session')
  local path = vim.fn.tempname()
  vim.fn.writefile({ assistant({ input_tokens = 5 }) }, path) -- model claude-haiku-5-5
  local s = session.open({ id = 'ctx-model', cwd = vim.fn.tempname(), path = path, title = 't' })
  local fresh = session.open({ id = 'ctx-fresh', cwd = vim.fn.tempname(), title = 'new' })
  prefs.set('model', 'opus') -- picked in another session
  local done = false
  context.refresh(s, function() done = true end)
  assert(vim.wait(2000, function() return done end, 10))
  eq({ s.transcript_model, prefs.start_model(s), prefs.start_model(fresh) }, { 'claude-haiku-5-5', 'claude-haiku-5-5', 'opus' })
  -- picked for this session: that one
  s.model_chosen = 'sonnet'
  eq(prefs.start_model(s), 'sonnet')
  prefs.set('model', nil)
  vim.fn.delete(path)
end

T['read: the tail of a file, also when the tail starts inside a line'] = function()
  local path = vim.fn.tempname()
  local lines = { assistant({ input_tokens = 1 }) }
  -- a long line ahead of the one that counts, longer than the tail read
  local filler = rec({ type = 'user', message = { role = 'user', content = ('x'):rep(4000) } })
  for _ = 1, 3 do lines[#lines + 1] = filler end
  lines[#lines + 1] = assistant({ input_tokens = 10, cache_read_input_tokens = 70000 })
  lines[#lines + 1] = rec({ type = 'user', message = { role = 'user', content = 'last' } })
  vim.fn.writefile(lines, path)
  local orig = context.TAIL
  context.TAIL = 6000
  local got, done = nil, false
  context.read(path, function(t) got, done = t, true end)
  assert(vim.wait(2000, function() return done end, 10))
  context.TAIL = orig
  eq(got, 70010)
  -- a file without a usable message
  vim.fn.writefile({ rec({ type = 'user', message = { role = 'user', content = 'only' } }) }, path)
  done = false
  context.read(path, function(t) got, done = t, true end)
  assert(vim.wait(2000, function() return done end, 10))
  eq(got, nil)
  -- a missing file
  done = false
  context.read(path .. '.missing', function(t) got, done = t, true end)
  assert(vim.wait(2000, function() return done end, 10))
  eq(got, nil)
  vim.fn.delete(path)
end

T['refresh: reads once per file version, keeps the live value while a process runs'] = function()
  require('agent-ide.config').setup({})
  local session = require('agent-ide.session')
  local path = vim.fn.tempname()
  vim.fn.writefile({ assistant({ input_tokens = 500 }) }, path)
  local s = session.open({ id = 'ctx-1', cwd = vim.fn.tempname(), path = path, title = 't' })
  local got, done = nil, false
  context.refresh(s, function(t) got, done = t, true end)
  assert(vim.wait(2000, function() return done end, 10))
  eq({ got, s.context_tokens, s.context_key ~= nil }, { 500, 500, true })
  -- the same file again: no read (a changed value on the session would be read back otherwise)
  s.context_tokens = 42
  done = false
  context.refresh(s, function(t) got, done = t, true end)
  assert(vim.wait(2000, function() return done end, 10))
  eq(got, 42)
  -- the file grew: read again
  vim.fn.writefile({ assistant({ input_tokens = 7000 }) }, path, 'a')
  s.context_key = nil
  done = false
  context.refresh(s, function(t) got, done = t, true end)
  assert(vim.wait(2000, function() return done end, 10))
  eq(got, 7000)
  -- alive: the live value, no read
  s.context_tokens = 99
  s._alive = function() return true end
  done = false
  context.refresh(s, function(t) got, done = t, true end)
  assert(vim.wait(2000, function() return done end, 10))
  eq(got, 99)
  session._reset()
  vim.fn.delete(path)
end

return T
