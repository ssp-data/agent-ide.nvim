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
T['edit caps removed and added lines separately at 30 each'] = function()
  local r = render.render({ { kind = 'tool_call', id = 'e', name = 'Edit',
    input = { file_path = '/f', old_string = string.rep('o\n', 69) .. 'o', new_string = 'n1\nn2' } } })
  local minus, plus = 0, 0
  for _, l in ipairs(r.lines) do
    if l == '│ - o' then minus = minus + 1 end
    if vim.startswith(l, '│ + ') then plus = plus + 1 end
  end
  eq({ minus, plus }, { 30, 2 })
  eq(r.lines[32], '│ … 40 more lines')
  eq({ r.lines[33], r.lines[34] }, { '│ + n1', '│ + n2' })
  local both = render.render({ { kind = 'tool_call', id = 'e', name = 'Edit',
    input = { file_path = '/f', old_string = string.rep('o\n', 34) .. 'o', new_string = string.rep('n\n', 31) .. 'n' } } })
  eq(#both.lines, 1 + 30 + 1 + 30 + 1)
  eq(both.lines[32], '│ … 5 more lines')
  eq(both.lines[#both.lines], '│ … 2 more lines')
end
T['tool input shows empty objects as {} however they were decoded'] = function()
  local a = render.render({ { kind = 'tool_call', id = 'a', name = 'Foo', input = vim.json.decode('{"x":{}}') } })
  local b = render.render({ { kind = 'tool_call', id = 'a', name = 'Foo', input = { x = {} } } })
  eq(a.lines, b.lines)
  eq(vim.tbl_contains(a.lines, '│   x = {}'), true)
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
-- Very long lines ------------------------------------------------------------------------

local function longest(lines)
  local n = 0
  for _, l in ipairs(lines) do n = math.max(n, #l) end
  return n
end
local function suffix(n) return (' … +%d bytes (gr shows the raw line)'):format(n) end

T['line limits are named constants'] = function()
  eq({ render.MAX_FOLD_LINE, render.MAX_TEXT_LINE }, { 2000, 20000 })
end
T['a 600 KB single-line unknown is one short line with a counted cut'] = function()
  local r = render.render({ { kind = 'unknown', label = 'image', raw = string.rep('A', 600000) } })
  eq(#r.lines, 2)
  eq(r.lines[2], '│ ' .. string.rep('A', 2000) .. suffix(600000 - 2000))
  eq(r.folds, { { first = 1, last = 2 } })
end
T['the cut never splits a multi-byte character'] = function()
  -- 999 two-byte characters fill 1998 bytes; the 3-byte one would end at 2001
  local raw = string.rep('é', 999) .. '€' .. string.rep('x', 100)
  local r = render.render({ { kind = 'unknown', label = 'u', raw = raw } })
  eq(r.lines[2], '│ ' .. string.rep('é', 999) .. suffix(103))
  eq(vim.fn.strchars(r.lines[2]) > 0, true)
  eq(pcall(vim.str_utfindex, r.lines[2], 'utf-32'), true)
end
T['a 48 KB line in a Write body is cut; line count and folds do not change'] = function()
  local big = string.rep('w', 48000)
  local short = 'w'
  local function run(content)
    return render.render({
      { kind = 'prompt', text = 'p' },
      { kind = 'tool_call', id = 'a', name = 'Write', input = { file_path = '/x', content = 'one\n' .. content .. '\nthree' } },
      { kind = 'tool_result', id = 'a', text = 'ok', is_error = false },
      { kind = 'text', text = 'done' },
    })
  end
  local cut, plain = run(big), run(short)
  eq(#cut.lines, #plain.lines)
  eq(cut.folds, plain.folds)
  eq(cut.lines[10], '│ ' .. string.rep('w', 2000) .. suffix(48000 - 2000))
  eq(longest(cut.lines) <= 4 + 2000 + #suffix(48000), true)
end
T['limits apply to meta, thinking, tool results and keep every line of the body'] = function()
  local big = string.rep('m', 5000)
  local r = render.render({
    { kind = 'meta', label = 'm', text = 'a\n' .. big },
    { kind = 'thinking', text = big },
    { kind = 'tool_result', id = 'zz', text = big, is_error = false },
  })
  eq(#r.lines, 7)
  for _, l in ipairs(r.lines) do eq(#l <= 4 + 2000 + #suffix(5000), true) end
end
T['answer and prompt lines are cut only above 20000 bytes'] = function()
  local five = string.rep('a', 5000)
  local r = render.render({ { kind = 'prompt', text = five }, { kind = 'text', text = five } })
  eq(r.lines[4], five)
  eq(r.lines[8], five)
  local huge = string.rep('b', 25000)
  r = render.render({ { kind = 'prompt', text = huge }, { kind = 'text', text = huge } })
  eq(r.lines[4], string.rep('b', 20000) .. suffix(5000))
  eq(r.lines[8], string.rep('b', 20000) .. suffix(5000))
  eq(#r.lines, 9)
end

return T
