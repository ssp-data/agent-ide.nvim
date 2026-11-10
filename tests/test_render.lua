local render = require('agent-ide.transcript.render')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T['prompt, answer, tool call with result'] = function()
  local r = render.render({
    { kind = 'prompt', text = 'run ls' },
    { kind = 'tool_call', id = 't1', name = 'Bash', input = { command = 'ls' } },
    { kind = 'tool_result', id = 't1', text = 'a.txt\nb.txt', is_error = false },
    { kind = 'text', text = 'Done.' },
  })
  eq(r.lines, { '', '## You', '', 'run ls', '', '## Claude', '',
    '▸ Bash: ls', '│ $ ls', '│ a.txt', '│ b.txt', 'Done.', '' })
  eq(r.folds, { { first = 8, last = 11 } })
end
T['answer text that looks like markup is not a fold'] = function()
  local r = render.render({ { kind = 'prompt', text = 'q' }, { kind = 'text', text = '▸ not a fold\n│ nor this' } })
  eq(r.folds, {})
end
T['results attach to their call even when out of order'] = function()
  local r = render.render({
    { kind = 'tool_call', id = 'a', name = 'Read', input = { file_path = '/x' } },
    { kind = 'tool_call', id = 'b', name = 'Read', input = { file_path = '/y' } },
    { kind = 'tool_result', id = 'b', text = 'YY', is_error = false },
    { kind = 'tool_result', id = 'a', text = 'XX', is_error = false },
  })
  local s = table.concat(r.lines, '\n')
  MiniTest.expect.no_equality(s:find('/x.-XX.-/y.-YY'), nil)
end
T['call without result and result without call'] = function()
  local r = render.render({
    { kind = 'tool_call', id = 'a', name = 'Bash', input = { command = 'sleep 9' } },
    { kind = 'tool_result', id = 'zz', text = 'orphan', is_error = false },
  })
  eq(#r.folds, 2)
  eq(r.lines[r.folds[2].first], '▸ result (no matching call)')
end
T['error result, unknown, long output cap'] = function()
  local big = string.rep('x\n', 300)
  local r = render.render({
    { kind = 'tool_call', id = 'a', name = 'Bash', input = { command = 'c' } },
    { kind = 'tool_result', id = 'a', text = big, is_error = true },
    { kind = 'unknown', label = 'future-thing', raw = '{"type":"future-thing"}' },
  })
  eq(r.lines[3], '│ ERROR x')
  eq(vim.tbl_contains(r.lines, '│ … 101 more lines'), true)
  eq(vim.tbl_contains(r.lines, '▸ unknown: future-thing'), true)
end
T['no line contains newline or carriage return'] = function()
  local r = render.render({ { kind = 'text', text = 'a\r\nb\rc' } })
  eq(r.lines, { 'a', 'b', 'c', '' })
  for _, l in ipairs(r.lines) do eq(l:find('[\r\n]'), nil) end
end
T['sidechain events collapse into one fold'] = function()
  local r = render.render({
    { kind = 'text', text = 'sub says hi', sidechain = true },
    { kind = 'tool_call', id = 's', name = 'Bash', input = { command = 'ls' }, sidechain = true },
  })
  eq(r.lines[1], '▸ subagent (2 events)')
  eq(r.folds, { { first = 1, last = #r.lines } })
end
T['fold_levels'] = function()
  eq(render.fold_levels({ { first = 2, last = 3 } }, 4), { '0', '>1', '1', '0' })
end
T['tool call without summary fields keeps colon form'] = function()
  local r = render.render({ { kind = 'tool_call', id = 'a', name = 'Foo', input = { x = 1 } } })
  eq(r.lines[1], '▸ Foo: ')
end
T['edit and write bodies'] = function()
  local r = render.render({
    { kind = 'tool_call', id = 'e', name = 'Edit', input = { file_path = '/f', old_string = 'a\nb', new_string = 'c' } },
    { kind = 'tool_call', id = 'w', name = 'Write', input = { file_path = '/g', content = 'l1\nl2' } },
  })
  eq(r.lines, { '▸ Edit: /f', '│ - a', '│ - b', '│ + c', '▸ Write: /g', '│ l1', '│ l2' })
end
T['tool input cap is 60 lines'] = function()
  local r = render.render({
    { kind = 'tool_call', id = 'w', name = 'Write', input = { file_path = '/g', content = string.rep('y\n', 99) } },
  })
  eq(#r.lines, 1 + 60 + 1)
  eq(r.lines[#r.lines], '│ … 40 more lines')
end
T['summary is cut to 80 characters'] = function()
  local r = render.render({ { kind = 'tool_call', id = 'a', name = 'Bash', input = { command = string.rep('z', 100) .. '\nsecond' } } })
  eq(r.lines[1], '▸ Bash: ' .. string.rep('z', 80))
end
T['thinking and meta blocks'] = function()
  local r = render.render({
    { kind = 'thinking', text = 'hmm' },
    { kind = 'meta', label = 'summary', text = 'sum' },
  })
  eq(r.lines, { '▸ thinking', '│ hmm', '▸ summary', '│ sum' })
  eq(#r.folds, 2)
end
T['unknown body capped at 20 lines'] = function()
  local r = render.render({ { kind = 'unknown', label = 'u', raw = string.rep('r\n', 29) } })
  eq(#r.lines, 1 + 20 + 1)
  eq(r.lines[#r.lines], '│ … 10 more lines')
end
T['sidechain group between main-thread events'] = function()
  local r = render.render({
    { kind = 'text', text = 'main' },
    { kind = 'text', text = 'sub', sidechain = true },
    { kind = 'tool_call', id = 's', name = 'Bash', input = { command = 'ls' }, sidechain = true },
    { kind = 'tool_result', id = 's', text = 'out', is_error = false, sidechain = true },
    { kind = 'text', text = 'after' },
  })
  eq(r.lines, { 'main', '', '▸ subagent (3 events)', '│ sub', '│ ', '│ ▸ Bash: ls', '│ │ $ ls', '│ │ out', 'after', '' })
  eq(r.folds, { { first = 3, last = 8 } })
end
T['headers use only the first line of name and label'] = function()
  local r = render.render({
    { kind = 'tool_call', id = 'a', name = 'Na\nme', input = {} },
    { kind = 'meta', label = 'la\nbel', text = 't' },
    { kind = 'unknown', label = 'un\r\nk', raw = 'r' },
  })
  eq(r.lines, { '▸ Na: ', '│ {}', '▸ la', '│ t', '▸ unknown: un', '│ r' })
  for _, l in ipairs(r.lines) do eq(l:find('[\r\n]'), nil) end
end
return T
