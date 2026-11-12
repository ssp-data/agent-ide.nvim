local stream = require('agent-ide.claude.stream')
local parse = require('agent-ide.transcript.parse')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function slurp(p) local f = assert(io.open(p)); local s = f:read('a'); f:close(); return s end

-- Feed raw lines to one decoder; return the flat Action list.
local function feed_lines(lines, dec)
  dec = dec or stream.new()
  local out = {}
  for _, line in ipairs(lines) do
    local obj = vim.json.decode(line, parse.DECODE_OPTS)
    for _, a in ipairs(dec:feed(obj, line)) do out[#out + 1] = a end
  end
  return out
end
local function run(name)
  return feed_lines(vim.split(slurp('tests/fixtures/stream/' .. name .. '.jsonl'), '\n', { trimempty = true }))
end
local function pick(actions, t)
  return vim.tbl_filter(function(a) return a.type == t end, actions)
end
local function events(actions)
  return vim.tbl_map(function(a) return a.event end, pick(actions, 'event'))
end

T['basic: init, deltas, streamed text, quota, result'] = function()
  local a = run('basic')
  local init = pick(a, 'init')[1]
  eq(init.model, 'claude-haiku-5-5')
  eq({ init.session_id, init.mode, init.version }, { '00000000-0000-4000-8000-000000000001', 'manual', '2.1.306' })
  eq(init.slash_commands, { 'compact', 'context' })
  eq(pick(a, 'status')[1].busy, true)
  eq(pick(a, 'echo')[1].text, 'Say hello')
  eq(vim.tbl_map(function(x) return x.text end, pick(a, 'delta')), { 'Hel', 'lo' })
  local texts = vim.tbl_filter(function(x) return x.event.kind == 'text' end, pick(a, 'event'))
  eq(#texts, 1)
  eq({ texts[1].event.text, texts[1].streamed }, { 'Hello', true })
  eq(pick(a, 'quota')[1].windows.five_hour.utilization, 0.07)
  eq(pick(a, 'quota')[1].windows.seven_day, { utilization = 0.18, resets_at = 1767751200 })
  eq(pick(a, 'result')[1].is_error, false)
  eq(pick(a, 'result')[1].text, 'Hello')
  eq(#pick(a, 'unknown'), 0)
end

T['tools: call and result become part 1 events'] = function()
  local ev = events(run('tools'))
  eq({ ev[1].kind, ev[1].id, ev[1].name, ev[1].input.command }, { 'tool_call', 't1', 'Bash', 'ls' })
  eq({ ev[2].kind, ev[2].id, ev[2].text, ev[2].is_error }, { 'tool_result', 't1', 'a.txt', false })
  eq(ev[3], { kind = 'text', text = 'Done.' })
  eq(#ev, 3)
end

T['permission request'] = function()
  local a = run('permission')
  local p = pick(a, 'permission')[1]
  eq({ p.request_id, p.tool_name, p.input.file_path }, { 'p1', 'Write', '/tmp/x/b.txt' })
  eq(p.description, 'b.txt')
  eq(p.suggestions, { { type = 'setMode', mode = 'acceptEdits', destination = 'session' } })
  -- Claude echoes the host's answer back as a control_response with the same id.
  eq(pick(a, 'control_ok')[1].request_id, 'p1')
  eq(pick(a, 'control_ok')[1].response.behavior, 'allow')
end

T['odd: nothing is dropped'] = function()
  local a = run('odd')
  eq(pick(a, 'unknown')[1].label, 'future_thing')
  eq(pick(a, 'unknown')[1].raw, vim.split(slurp('tests/fixtures/stream/odd.jsonl'), '\n')[1])
  eq(#pick(a, 'unknown') >= 2, true)
  eq(pick(a, 'unknown')[2].label, 'stream_event/future_event')
  eq(events(a)[1].sidechain, true)
  eq(events(a)[1].text, 'Sub')
  eq(pick(a, 'control_error')[1].request_id, 'c9')
  eq(pick(a, 'control_error')[1].error, "Model 'nope' not found")
  eq(pick(a, 'result')[1].is_error, true)
end

T['interaction: user question and plan approval arrive as permission asks'] = function()
  local a = run('interaction')
  eq(pick(a, 'init')[1].mode, 'plan')
  local p = pick(a, 'permission')
  eq(#p, 2)
  eq({ p[1].request_id, p[1].tool_name }, { 'q1', 'AskUserQuestion' })
  eq(p[1].input.questions[1].options[2].label, 'Blue')
  eq(p[1].suggestions, nil)
  eq({ p[2].request_id, p[2].tool_name, p[2].input.plan }, { 'x1', 'ExitPlanMode', '# Plan\n\nPaint it blue.\n' })
  eq(vim.tbl_map(function(x) return x.request_id end, pick(a, 'control_ok')), { 'q1', 'x1' })
  -- Approving the plan switches the mode; the status carries it, busy stays unset.
  local st = pick(a, 'status')[1]
  eq({ st.mode, st.busy }, { 'manual', nil })
  local ev = events(a)
  eq(vim.tbl_map(function(e) return e.kind end, ev), { 'tool_call', 'tool_result', 'tool_call', 'tool_result' })
end

T['an image block streams as the same event as the transcript record'] = function()
  local block = '{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}}'
  for _, role in ipairs({ 'assistant', 'user' }) do
    local line = '{"type":"' .. role .. '","message":{"role":"' .. role .. '","content":[' .. block .. ']}}'
    local a = feed_lines({ line })
    eq(#a, 1)
    eq(a[1].event, { kind = 'meta', label = 'image', text = 'image/png, 8 B' })
    eq({ a[1].event }, parse.parse_line(line))
  end
end

T['non-streamed assistant text (synthetic message) becomes a text event'] = function()
  local a = feed_lines({ '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hi"}]},"parent_tool_use_id":null}' })
  eq(#a, 1)
  eq(a[1], { type = 'event', event = { kind = 'text', text = 'Hi' } })
  eq(a[1].streamed, nil)
end

T['streamed flag belongs to one content block'] = function()
  local dec = stream.new()
  local function se(ev) return vim.json.encode({ type = 'stream_event', event = ev }) end
  local a = feed_lines({
    se({ type = 'content_block_start', index = 0, content_block = { type = 'text', text = '' } }),
    se({ type = 'content_block_delta', index = 0, delta = { type = 'text_delta', text = 'A' } }),
    '{"type":"assistant","message":{"content":[{"type":"text","text":"A"}]}}',
    se({ type = 'content_block_stop', index = 0 }),
    se({ type = 'content_block_start', index = 1, content_block = { type = 'tool_use', id = 'x', name = 'Bash', input = {} } }),
    '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"x","name":"Bash","input":{}}]}}',
    '{"type":"assistant","message":{"content":[{"type":"text","text":"B"}]}}',
  }, dec)
  local evs = pick(a, 'event')
  eq({ evs[1].event.text, evs[1].streamed }, { 'A', true })
  eq(evs[2].streamed, nil)
  eq({ evs[3].event.text, evs[3].streamed }, { 'B', nil })
end

T['replayed prompt, command output, interrupt marker and slash output'] = function()
  local a = feed_lines({
    '{"type":"user","message":{"role":"user","content":"hello"},"parent_tool_use_id":null,"isReplay":true}',
    '{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to haiku</local-command-stdout>"},"parent_tool_use_id":null,"isReplay":true}',
    '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"parent_tool_use_id":null}',
    '{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"## Context Usage"}]},"parent_tool_use_id":null,"local_command_run":{"command":"context","args":""}}',
  })
  eq(a[1], { type = 'echo', text = 'hello' })
  -- flagged: the output of a command Claude ran for a control request (set_model)
  eq(a[2], { type = 'event', event = { kind = 'meta', label = 'command output', text = 'Set model to haiku' },
    command_stdout = true })
  eq(a[3], { type = 'event', event = { kind = 'meta', label = 'meta', text = '[Request interrupted by user]' } })
  eq(a[4], { type = 'event', event = { kind = 'meta', label = 'command output', text = '## Context Usage' } })
  eq(#a, 4)
end

T['system objects: hooks, thinking tokens, status, other subtypes'] = function()
  local a = feed_lines({
    '{"type":"system","subtype":"hook_started","hook_id":"h","hook_name":"SessionStart","hook_event":"SessionStart"}',
    '{"type":"system","subtype":"hook_response","hook_id":"h","hook_name":"SessionStart","hook_event":"SessionStart","outcome":"success","exit_code":0,"output":"","stdout":"","stderr":""}',
    '{"type":"system","subtype":"hook_response","hook_id":"h2","hook_name":"SessionStart","hook_event":"SessionStart","outcome":"error","exit_code":1,"output":"","stdout":"","stderr":"boom"}',
    '{"type":"system","subtype":"thinking_tokens","estimated_tokens":50,"estimated_tokens_delta":50}',
    '{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}',
    '{"type":"system","subtype":"future_thing","x":1}',
  })
  eq(a[1], { type = 'event', event = { kind = 'meta', label = 'hook', text = 'SessionStart: boom' } })
  eq(a[2], { type = 'status', mode = 'acceptEdits' })
  eq({ a[3].type, a[3].label }, { 'unknown', 'system/future_thing' })
  eq(#a, 3)
end

T['background tasks: started, updated and done as readable folds named by their description'] = function()
  local a = feed_lines({
    '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"k","description":"Scan repo"}],"uuid":"u","session_id":"s"}',
    '{"type":"system","subtype":"task_started","task_id":"k","run_id":"r","tool_use_id":"t","description":"Scan repo","subagent_type":"Explore","is_backgrounded":true,"task_type":"local_agent","prompt":"Find\\nthings","uuid":"u","session_id":"s"}',
    '{"type":"system","subtype":"task_updated","task_id":"k","run_id":"r","patch":{"status":"completed","end_time":5}}',
    '{"type":"system","subtype":"task_notification","task_id":"k","run_id":"r","tool_use_id":"t","status":"completed","output_file":"/tmp/o","summary":"Found 3 files","usage":{"total_tokens":1234,"tool_uses":4,"duration_ms":65000}}',
  })
  eq(events(a), {
    { kind = 'meta', label = 'task started: Scan repo',
      text = 'Explore (local_agent, in the background)\nprompt: Find\nthings\ntask k, run r, tool call t' },
    { kind = 'meta', label = 'task completed: Scan repo', text = 'end_time: 5' },
    { kind = 'meta', label = 'task completed: Scan repo',
      text = 'Found 3 files\n1234 tokens, 4 tool uses, 1m 5s\noutput: /tmp/o' },
  })
  eq(#a, 3)
end

T['background tasks: a foreground task is its own tool fold already, so it and its updates are quiet'] = function()
  local a = feed_lines({
    '{"type":"system","subtype":"task_started","task_id":"f","description":"Run tests","is_backgrounded":false,"task_type":"local_bash"}',
    '{"type":"system","subtype":"task_updated","task_id":"f","patch":{"status":"completed"}}',
    '{"type":"system","subtype":"task_notification","task_id":"f","status":"completed","summary":"ok"}',
  })
  eq(a, {})
end

T['background tasks: an update for a task never seen starting is still shown, by its id'] = function()
  local a = feed_lines({
    '{"type":"system","subtype":"task_notification","task_id":"z","status":"failed","summary":"boom"}',
  })
  eq(events(a), { { kind = 'meta', label = 'task failed: z', text = 'boom' } })
end

T['sidechain deltas are dropped; known stream events yield nothing'] = function()
  local a = feed_lines({
    '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"sub"}},"parent_tool_use_id":"ta"}',
    '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{"}},"parent_tool_use_id":null}',
    '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}},"parent_tool_use_id":null}',
    '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"s"}},"parent_tool_use_id":null}',
    '{"type":"stream_event","event":{"type":"message_stop"},"parent_tool_use_id":null}',
    '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"future_delta"}},"parent_tool_use_id":null}',
  })
  eq(#a, 1)
  eq({ a[1].type, a[1].label }, { 'unknown', 'stream_event/content_block_delta/future_delta' })
end

T['a subagent block start does not reset the main streamed mark'] = function()
  local a = feed_lines({
    '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null}',
    '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Main"}},"parent_tool_use_id":null}',
    '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":"ta"}',
    '{"type":"assistant","message":{"content":[{"type":"text","text":"Main"}]},"parent_tool_use_id":null}',
  })
  local evs = pick(a, 'event')
  eq(#evs, 1)
  eq({ evs[1].event.text, evs[1].streamed, evs[1].event.sidechain }, { 'Main', true, nil })
end

T['parent_tool_use_id decoded as vim.NIL is the main thread'] = function()
  local dec = stream.new()
  local d = dec:feed({ type = 'stream_event', parent_tool_use_id = vim.NIL,
    event = { type = 'content_block_delta', index = 0, delta = { type = 'text_delta', text = 'x' } } }, nil)
  eq(d, { { type = 'delta', text = 'x' } })
  local a = dec:feed({ type = 'assistant', parent_tool_use_id = vim.NIL,
    message = { content = { { type = 'text', text = 'x' } } } }, '{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]},"parent_tool_use_id":null}')
  eq(a, { { type = 'event', event = { kind = 'text', text = 'x' }, streamed = true } })
  local u = dec:feed({ type = 'user', parent_tool_use_id = vim.NIL,
    message = { content = { { type = 'tool_result', tool_use_id = 't', content = 'ok' } } } }, nil)
  eq(u[1].event.sidechain, nil)
end

T['empty thinking block and empty content yield nothing'] = function()
  eq(feed_lines({
    '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"","signature":"s"}]},"parent_tool_use_id":null}',
    '{"type":"assistant","message":{"content":[]},"parent_tool_use_id":null}',
  }), {})
end

T['a repeated tool_use block is reported once'] = function()
  local line = '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t9","name":"Bash","input":{}}]}}'
  eq(#feed_lines({ line, line }), 1)
end

T['feed never raises'] = function()
  local dec = stream.new()
  for _, obj in ipairs({ {}, { type = 5 }, { type = 'assistant' }, { type = 'user', message = 7 },
    { type = 'stream_event' }, { type = 'stream_event', event = { type = 'content_block_delta', delta = 3 } },
    { type = 'control_request' }, { type = 'control_response', response = 'x' }, { type = 'rate_limit_event' },
    { type = 'system', subtype = 'init' }, { type = 'result' } }) do
    local ok, out = pcall(dec.feed, dec, obj, vim.json.encode(obj))
    eq(ok, true)
    eq(type(out), 'table')
  end
  for _, obj in ipairs({ 'str', 42, vim.NIL }) do
    local ok, out = pcall(dec.feed, dec, obj, nil)
    eq({ ok, type(out) }, { true, 'table' })
    eq(out[1].type, 'unknown')
  end
  eq(dec:feed({ type = 5 }, '{"type":5}'), { { type = 'unknown', label = '?', raw = '{"type":5}' } })
end

T['context: an assistant message carries the input of its request; not a subagent\'s'] = function()
  local a = feed_lines({
    vim.json.encode({ type = 'assistant', message = { id = 'm', role = 'assistant', model = 'claude-haiku-5-5',
      content = { { type = 'text', text = 'hi' } },
      usage = { input_tokens = 10, cache_read_input_tokens = 120000, cache_creation_input_tokens = 3000, output_tokens = 5 } } }),
    vim.json.encode({ type = 'assistant', parent_tool_use_id = 't1', message = { id = 'm2', role = 'assistant',
      content = { { type = 'text', text = 'sub' } }, usage = { input_tokens = 999 } } }),
    vim.json.encode({ type = 'assistant', local_command_run = { command = 'context', args = '' },
      message = { id = 'm3', role = 'assistant', model = '<synthetic>',
        content = { { type = 'text', text = 'ctx' } }, usage = { input_tokens = 5 } } }),
    vim.json.encode({ type = 'assistant', message = { id = 'm4', role = 'assistant',
      content = { { type = 'text', text = 'no usage' } } } }),
  })
  local ctx = pick(a, 'context')
  eq(#ctx, 1)
  eq(ctx[1].tokens, 123010)
  -- the event comes first, the size after it
  eq(a[1].type, 'event')
  eq(a[2].type, 'context')
end

T['compact_boundary: the transcript parser\'s meta fold and a compact action'] = function()
  local line = vim.json.encode({ type = 'system', subtype = 'compact_boundary', session_id = 'x', uuid = 'u',
    compact_metadata = { trigger = 'manual', pre_tokens = 241211 } })
  local a = feed_lines({ line })
  eq(#a, 2)
  eq(a[1].event, { kind = 'meta', label = 'system: compact_boundary', text = 'conversation compacted (manual), 241k tokens before' })
  eq(a[2], { type = 'compact', trigger = 'manual', pre_tokens = 241211 })
  -- with a content string (as the transcript record has) that text is shown, as the parser does
  local rec = vim.json.encode({ type = 'system', subtype = 'compact_boundary', content = 'Conversation compacted',
    compact_metadata = { trigger = 'auto', pre_tokens = 1, post_tokens = 2 } })
  local b = feed_lines({ rec })
  eq(b[1].event.text, 'Conversation compacted')
  eq(b[2].post_tokens, 2)
  eq((parse.parse_record(rec))[1], { kind = 'meta', label = 'system: compact_boundary', text = 'Conversation compacted' })
  eq(#pick(a, 'unknown'), 0)
end

return T
