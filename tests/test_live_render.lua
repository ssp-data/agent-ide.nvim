local render = require('agent-ide.transcript.render')
local live_render = require('agent-ide.transcript.live')
local api = vim.api
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = {
  post_case = function()
    vim.cmd('silent! only')
    for _, b in ipairs(api.nvim_list_bufs()) do
      if b ~= api.nvim_get_current_buf() then pcall(api.nvim_buf_delete, b, { force = true }) end
    end
  end,
} })

-- Stub Session: only the fields the live view reads.
local function stub()
  return { events = {}, turn_start = 1, streaming = '', pending_permissions = {} }
end

---Append `ev` to the stub, keeping `turn_start` on the latest main-thread prompt.
local function push(s, ev)
  s.events[#s.events + 1] = ev
  if ev.kind == 'prompt' and not ev.sidechain then
    s.turn_start = #s.events
  elseif s.turn_start == #s.events then
    s.turn_start = #s.events + 1 -- no prompt yet: keeps pointing past the end
  end
end

local function new_buf()
  local buf = api.nvim_create_buf(false, true)
  return buf
end

local function levels_of(buf)
  return require('agent-ide.ui.history')._levels(buf)
end

local function expect_full(buf, s)
  local out = render.render(s.events)
  eq(api.nvim_buf_get_lines(buf, 0, -1, false), #out.lines > 0 and out.lines or { '' })
  local lv = levels_of(buf)
  eq(vim.list_slice(lv, 1, #out.lines), render.fold_levels(out.folds, #out.lines))
  eq(#lv, #out.lines)
end

-- Synthetic event sequences (never real data).
local SEQ = {}
SEQ.plain = {
  { kind = 'prompt', text = 'hello' },
  { kind = 'text', text = 'Hi there.\nSecond line.' },
  { kind = 'prompt', text = 'again' },
  { kind = 'text', text = 'Sure.' },
  { kind = 'prompt', text = 'and\r\nagain' },
  { kind = 'prompt', text = 'twice' },
  { kind = 'text', text = 'ok' },
}
SEQ.tools = {
  { kind = 'meta', label = 'before', text = 'turn zero' },
  { kind = 'prompt', text = 'run things' },
  { kind = 'thinking', text = 'plan' },
  { kind = 'tool_call', id = 'a', name = 'Bash', input = { command = 'ls' } },
  { kind = 'tool_call', id = 'b', name = 'Read', input = { file_path = '/y' } },
  { kind = 'tool_result', id = 'b', text = 'YY', is_error = false },
  { kind = 'text', text = 'between' },
  { kind = 'tool_result', id = 'a', text = 'a.txt\nb.txt', is_error = true },
  { kind = 'tool_result', id = 'zz', text = 'orphan', is_error = false },
  { kind = 'prompt', text = 'next' },
  { kind = 'tool_result', id = 'a', text = 'late result from the previous turn', is_error = false },
  { kind = 'tool_call', id = 'c', name = 'Edit', input = { file_path = '/f', old_string = 'x', new_string = 'y' } },
  { kind = 'tool_result', id = 'c', text = 'ok', is_error = false },
  { kind = 'text', text = 'Done.' },
}
SEQ.sidechain = {
  { kind = 'prompt', text = 'delegate' },
  { kind = 'tool_call', id = 't', name = 'Task', input = { description = 'sub' } },
  { kind = 'prompt', text = 'sub prompt', sidechain = true },
  { kind = 'text', text = 'sub says hi', sidechain = true },
  { kind = 'tool_call', id = 's', name = 'Bash', input = { command = 'ls' }, sidechain = true },
  { kind = 'prompt', text = 'sub prompt two', sidechain = true },
  { kind = 'tool_result', id = 's', text = 'out', is_error = false, sidechain = true },
  { kind = 'tool_result', id = 't', text = 'sub done', is_error = false },
  { kind = 'text', text = 'main again' },
  { kind = 'prompt', text = 'more' },
  { kind = 'text', text = 'x', sidechain = true },
}
SEQ.markup = {
  { kind = 'prompt', text = '## You\n▸ x' },
  { kind = 'text', text = '▸ x\n│ y\n## You\n## Claude' },
  { kind = 'prompt', text = '│ y' },
  { kind = 'text', text = '' },
  { kind = 'text', text = '\n\n' },
}
local function many_turns(n)
  local evs = {}
  for t = 1, n do
    evs[#evs + 1] = { kind = 'prompt', text = 'question ' .. t }
    if t % 3 == 0 then
      evs[#evs + 1] = { kind = 'tool_call', id = 'c' .. t, name = 'Bash', input = { command = 'echo ' .. t } }
      evs[#evs + 1] = { kind = 'tool_result', id = 'c' .. t, text = 'out ' .. t, is_error = false }
    end
    evs[#evs + 1] = { kind = 'text', text = ('answer %d\nwith two lines'):format(t) }
  end
  return evs
end
SEQ.turns300 = many_turns(300)

local function concat_turns(events)
  local lines, folds, answers = {}, {}, {}
  local seg = {}
  local function flush()
    if #seg == 0 then return end
    local r = render.render(seg)
    for _, f in ipairs(r.folds) do folds[#folds + 1] = { first = f.first + #lines, last = f.last + #lines } end
    for _, a in ipairs(r.answers) do answers[#answers + 1] = a + #lines end
    vim.list_extend(lines, r.lines)
    seg = {}
  end
  for _, ev in ipairs(events) do
    if ev.kind == 'prompt' and not ev.sidechain then flush() end
    seg[#seg + 1] = ev
  end
  flush()
  return { lines = lines, folds = folds, answers = answers }
end

T['render is compositional over turns'] = function()
  for name, seq in pairs(SEQ) do
    for n = 0, #seq do
      local part = vim.list_slice(seq, 1, n)
      local whole, parts = render.render(part), concat_turns(part)
      if not vim.deep_equal(whole, parts) then error(('%s: prefix %d not compositional'):format(name, n)) end
    end
  end
end

T['a result whose call is in an earlier turn renders as no matching call in its own turn'] = function()
  local r = render.render(SEQ.tools)
  local s = table.concat(r.lines, '\n')
  eq(s:find('late result from the previous turn', 1, true) > s:find('## You\n\nnext', 1, true), true)
  local first_turn = render.render(vim.list_slice(SEQ.tools, 1, 9))
  eq(vim.list_slice(r.lines, 1, #first_turn.lines), first_turn.lines)
  eq(vim.tbl_contains(r.lines, '▸ result (no matching call)'), true)
end

for name, seq in pairs(SEQ) do
  T['fed one at a time equals full render: ' .. name] = function()
    local s, buf = stub(), new_buf()
    local view = live_render.attach(buf, s)
    for _, ev in ipairs(seq) do
      push(s, ev)
      view:sync('events')
      expect_full(buf, s)
    end
    view:sync('reset')
    expect_full(buf, s)
    view:detach()
  end
end

T['streaming deltas then the text event'] = function()
  local s, buf = stub(), new_buf()
  local view = live_render.attach(buf, s)
  push(s, { kind = 'prompt', text = 'hi' })
  view:sync('events')
  local base = render.render(s.events).lines
  local counts = {}
  for _, d in ipairs({ 'Hel', 'lo\nwor', 'ld' }) do
    s.streaming = s.streaming .. d
    view:sync('delta')
    counts[#counts + 1] = api.nvim_buf_line_count(buf)
  end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(vim.list_slice(lines, #lines - 1), { 'Hello', 'world' })
  eq(vim.list_slice(lines, 1, #base), base)
  eq(vim.bo[buf].modifiable, false)
  local before = api.nvim_buf_line_count(buf)
  push(s, { kind = 'text', text = s.streaming })
  s.streaming = ''
  view:sync('events')
  expect_full(buf, s)
  eq(api.nvim_buf_line_count(buf) >= before, true)
  -- the streamed lines are the final lines (no re-layout): only the trailing blank is new
  eq(vim.list_slice(api.nvim_buf_get_lines(buf, 0, -1, false), 1, before), lines)
  eq(counts[1] <= counts[2] and counts[2] <= counts[3], true)
end

T['streaming with carriage returns and a second answer block'] = function()
  local s, buf = stub(), new_buf()
  local view = live_render.attach(buf, s)
  push(s, { kind = 'prompt', text = 'hi' })
  push(s, { kind = 'text', text = 'first' })
  view:sync('events')
  s.streaming = 'a\r\nb\rc'
  view:sync('delta')
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(vim.list_slice(lines, #lines - 2), { 'a', 'b', 'c' })
  eq(#lines, #render.render(s.events).lines + 3)
  local before = #lines
  push(s, { kind = 'text', text = s.streaming })
  s.streaming = ''
  view:sync('events')
  expect_full(buf, s)
  eq(api.nvim_buf_line_count(buf) >= before, true)
end

T['streaming text ends when a tool call arrives instead'] = function()
  local s, buf = stub(), new_buf()
  local view = live_render.attach(buf, s)
  push(s, { kind = 'prompt', text = 'hi' })
  view:sync('events')
  s.streaming = 'partial'
  view:sync('delta')
  s.streaming = ''
  push(s, { kind = 'tool_call', id = 'x', name = 'Bash', input = { command = 'ls' } })
  view:sync('events')
  expect_full(buf, s)
  view:sync('delta') -- no stream: nothing to show, nothing changes
  expect_full(buf, s)
  view:sync('bogus')
  expect_full(buf, s)
end

T['open asks show below the events and the streaming lines, unfolded, and go when answered'] = function()
  local ask = require('agent-ide.transcript.ask')
  local s, buf = stub(), new_buf()
  local view = live_render.attach(buf, s)
  push(s, { kind = 'prompt', text = 'hi' })
  push(s, { kind = 'tool_call', id = 'x', name = 'Bash', input = { command = 'ls' } })
  view:sync('events')
  s.pending_permissions = { { request_id = 'r', tool_name = 'Bash', input = { command = 'ls' } } }
  view:sync('permission')
  local rendered = render.render(s.events).lines
  local block = { '▸ Permission needed: Bash: ls', '│ $ ls' }
  eq(ask.lines(s), block)
  eq(api.nvim_buf_get_lines(buf, 0, -1, false), vim.list_extend(vim.list_slice(rendered), block))
  local lv = levels_of(buf)
  eq(vim.list_slice(lv, #rendered + 1), { '0', '0' })
  -- streaming text goes between the events and the block; a new event keeps the block last
  s.streaming = 'part'
  view:sync('delta')
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(vim.list_slice(lines, #lines - 2), { 'part', block[1], block[2] })
  s.streaming = ''
  push(s, { kind = 'text', text = 'more' })
  view:sync('events')
  rendered = render.render(s.events).lines
  eq(api.nvim_buf_get_lines(buf, 0, -1, false), vim.list_extend(vim.list_slice(rendered), block))
  s.pending_permissions = {}
  view:sync('permission')
  expect_full(buf, s)
end

T['lines before the current turn are never rewritten'] = function()
  local s, buf = stub(), new_buf()
  local view = live_render.attach(buf, s)
  for _, ev in ipairs({ { kind = 'prompt', text = 'one' }, { kind = 'text', text = 'turn one answer' } }) do
    push(s, ev)
    view:sync('events')
  end
  local row = vim.fn.index(api.nvim_buf_get_lines(buf, 0, -1, false), 'turn one answer')
  local ns = api.nvim_create_namespace('test_live_render')
  local mark = api.nvim_buf_set_extmark(buf, ns, row, 0, {})
  local ticks = {}
  api.nvim_buf_attach(buf, false, { on_lines = function(_, _, _, first) ticks[#ticks + 1] = first end })
  local rest = {
    { kind = 'prompt', text = 'two' }, { kind = 'tool_call', id = 'q', name = 'Bash', input = { command = 'x' } },
    { kind = 'tool_result', id = 'q', text = 'r', is_error = false }, { kind = 'text', text = 'two done' },
    { kind = 'prompt', text = 'three' }, { kind = 'text', text = 'three done' },
  }
  for _, ev in ipairs(rest) do
    push(s, ev)
    view:sync('events')
    s.streaming = 'stream'
    view:sync('delta')
    s.streaming = ''
  end
  view:sync('events')
  expect_full(buf, s)
  local pos = api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
  eq(api.nvim_buf_get_lines(buf, pos[1], pos[1] + 1, false)[1], 'turn one answer')
  for _, first in ipairs(ticks) do eq(first > row, true) end
end

T['folds opened in earlier turns stay open'] = function()
  local s, buf = stub(), new_buf()
  local view = live_render.attach(buf, s)
  api.nvim_set_current_buf(buf)
  local win = api.nvim_get_current_win()
  push(s, { kind = 'prompt', text = 'one' })
  push(s, { kind = 'tool_call', id = 'a', name = 'Bash', input = { command = 'ls' } })
  push(s, { kind = 'tool_result', id = 'a', text = 'r1\nr2', is_error = false })
  push(s, { kind = 'text', text = 'done' })
  view:sync('events')
  eq(vim.wo[win].foldmethod, 'expr')
  local header = vim.fn.index(api.nvim_buf_get_lines(buf, 0, -1, false), '▸ Bash: ls') + 1
  eq(vim.fn.foldclosed(header), header)
  api.nvim_win_set_cursor(win, { header, 0 })
  vim.cmd('normal! za')
  eq(vim.fn.foldclosed(header), -1)
  for _, ev in ipairs({
    { kind = 'prompt', text = 'two' }, { kind = 'tool_call', id = 'b', name = 'Bash', input = { command = 'pwd' } },
    { kind = 'tool_result', id = 'b', text = '/', is_error = false }, { kind = 'text', text = 'two done' },
  }) do
    push(s, ev)
    view:sync('events')
  end
  expect_full(buf, s)
  eq(vim.fn.foldclosed(header), -1)
  local h2 = vim.fn.index(api.nvim_buf_get_lines(buf, 0, -1, false), '▸ Bash: pwd') + 1
  eq(vim.fn.foldclosed(h2), h2)
end

T['cursor follows only in windows that were on the last line'] = function()
  local s, buf = stub(), new_buf()
  local view = live_render.attach(buf, s)
  for _, ev in ipairs({ { kind = 'prompt', text = 'one' }, { kind = 'text', text = 'a\nb\nc' } }) do
    push(s, ev)
  end
  view:sync('events')
  api.nvim_set_current_buf(buf)
  local follow = api.nvim_get_current_win()
  vim.cmd('split')
  local stay = api.nvim_get_current_win()
  vim.cmd('wincmd p')
  eq(api.nvim_get_current_win(), follow)
  api.nvim_win_set_cursor(follow, { api.nvim_buf_line_count(buf), 0 })
  api.nvim_win_set_cursor(stay, { 2, 0 })
  local mode = api.nvim_get_mode().mode
  push(s, { kind = 'prompt', text = 'two' })
  view:sync('events')
  s.streaming = 'live\nstream'
  view:sync('delta')
  eq(api.nvim_win_get_cursor(follow)[1], api.nvim_buf_line_count(buf))
  eq(api.nvim_win_get_cursor(stay), { 2, 0 })
  eq(api.nvim_get_current_win(), follow)
  eq(api.nvim_get_mode().mode, mode)
end

T['detach stops updates'] = function()
  local s, buf = stub(), new_buf()
  local view = live_render.attach(buf, s)
  push(s, { kind = 'prompt', text = 'one' })
  view:sync('events')
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  view:detach()
  push(s, { kind = 'text', text = 'later' })
  view:sync('events')
  eq(api.nvim_buf_get_lines(buf, 0, -1, false), lines)
end

T['reset after reload from disk re-renders everything'] = function()
  local s, buf = stub(), new_buf()
  local view = live_render.attach(buf, s)
  for _, ev in ipairs(SEQ.plain) do push(s, ev) end
  view:sync('events')
  s.events = vim.list_slice(SEQ.tools, 1, 6)
  s.turn_start = 2
  view:sync('reset')
  expect_full(buf, s)
  push(s, SEQ.tools[7])
  view:sync('events')
  expect_full(buf, s)
end

T['updates add no undo history'] = function()
  local s, buf = stub(), new_buf()
  local view = live_render.attach(buf, s)
  for _, ev in ipairs(SEQ.plain) do
    push(s, ev)
    view:sync('events')
  end
  eq(vim.bo[buf].undolevels, -1)
  eq(vim.fn.undotree(buf).seq_last, 0)
end

---While streaming, the buffer reads as the final render of the answer, minus its trailing blank.
local function expect_streaming(buf, s)
  local evs = vim.list_extend(vim.list_slice(s.events), { { kind = 'text', text = s.streaming } })
  local want = render.render(evs).lines
  want[#want] = nil
  eq(api.nvim_buf_get_lines(buf, 0, -1, false), want)
end

for name, before in pairs({
  thinking = { { kind = 'prompt', text = 'q' }, { kind = 'thinking', text = 'hmm' } },
  tool_result = { { kind = 'prompt', text = 'q' }, { kind = 'tool_call', id = 'a', name = 'Bash', input = { command = 'ls' } },
    { kind = 'tool_result', id = 'a', text = 'out', is_error = false } },
  prompt = { { kind = 'prompt', text = 'q' } },
  turn0 = { { kind = 'meta', label = 'm', text = 't' } },
}) do
  T['streaming after ' .. name .. ' keeps the invariant at every step'] = function()
    local s, buf = stub(), new_buf()
    local view = live_render.attach(buf, s)
    for _, ev in ipairs(before) do
      push(s, ev)
      view:sync('events')
      expect_full(buf, s)
    end
    for _, d in ipairs({ 'Hel', 'lo\nwor', 'ld\n' }) do
      s.streaming = s.streaming .. d
      view:sync('delta')
      expect_streaming(buf, s)
    end
    push(s, { kind = 'text', text = s.streaming })
    s.streaming = ''
    view:sync('events')
    expect_full(buf, s)
  end
end

T['empty session shows one empty line; the first event replaces it'] = function()
  local s, buf = stub(), new_buf()
  local view = live_render.attach(buf, s)
  eq(api.nvim_buf_get_lines(buf, 0, -1, false), { '' })
  eq(levels_of(buf), {})
  push(s, { kind = 'text', text = 'first' })
  view:sync('events')
  eq(api.nvim_buf_get_lines(buf, 0, -1, false), { 'first', '' })
  expect_full(buf, s)
end

-- Through a child Neovim's main loop, which moves a cursor inside a closed fold to the fold start.
local child = MiniTest.new_child_neovim()
T['follow'] = MiniTest.new_set({ hooks = { post_case = function() child.stop() end } })
T['follow']['window keeps following when a closed tool fold ends the buffer'] = function()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local api = vim.api
    _G.s = { events = {}, turn_start = 1, streaming = '', pending_permissions = {} }
    local buf = api.nvim_create_buf(false, true)
    _G.view = require('agent-ide.transcript.live').attach(buf, _G.s)
    api.nvim_set_current_buf(buf)
    vim.cmd('resize 6')
    _G.step = function(evs, streaming)
      for _, ev in ipairs(evs) do table.insert(_G.s.events, ev) end
      if #evs > 0 then _G.view:sync('events') end
      if streaming then _G.s.streaming = streaming; _G.view:sync('delta') end
    end
    _G.bottom = function()
      local w = vim.fn.line('w$')
      return { math.max(w, vim.fn.foldclosedend(w)), api.nvim_buf_line_count(0) }
    end
  ]])
  local function settle()
    child.type_keys('<Esc>')
    child.cmd('redraw')
  end
  local function at_end(what)
    settle()
    local b = child.lua_get('_G.bottom()')
    if b[1] ~= b[2] then error(('%s: last visible line %d, buffer has %d'):format(what, b[1], b[2])) end
  end
  child.lua([[_G.step({ { kind = 'prompt', text = 'question' }, { kind = 'text', text = 'a\nb\nc\nd\ne\nf\ng' } })]])
  child.lua('vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })')
  at_end('answer')
  -- the user opens and closes a fold by hand, so Neovim would create later folds open
  child.lua([[_G.step({ { kind = 'meta', label = 'm', text = 'x' }, { kind = 'text', text = 'h\ni' } })]])
  child.lua('vim.api.nvim_win_set_cursor(0, { vim.fn.search("^▸ m", "nw"), 0 })')
  child.type_keys('za', 'za', 'G')
  at_end('after za')
  child.lua([[_G.step({ { kind = 'prompt', text = 'next' } })]])
  at_end('prompt')
  child.lua([[_G.step({ { kind = 'tool_call', id = 't', name = 'Bash', input = { command = 'ls' } } })]])
  at_end('tool call')
  child.lua([[_G.step({ { kind = 'tool_result', id = 't', text = 'r1\nr2\nr3', is_error = false } })]])
  at_end('tool result')
  local fold_start = child.lua_get('vim.fn.foldclosed(vim.api.nvim_buf_line_count(0))')
  eq(fold_start > 0, true)
  -- what Neovim's foldAdjustCursor may do: the cursor goes to the start of the closed fold
  child.lua('vim.api.nvim_win_set_cursor(0, { ..., 0 })', { fold_start })
  at_end('cursor at fold start')
  for i, d in ipairs({ 'Hel', 'Hello\nwor', 'Hello\nworld\nmore' }) do
    child.lua(('_G.step({}, %q)'):format(d))
    at_end('delta ' .. i)
  end
  child.lua([[_G.s.streaming = ''; _G.step({ { kind = 'text', text = 'Hello\nworld\nmore' } })]])
  at_end('text event')
end

local function best_of(n, fn)
  collectgarbage('collect') -- earlier garbage is not this code's pause
  local best = math.huge
  for _ = 1, n do
    local t0 = vim.uv.hrtime()
    fn()
    best = math.min(best, (vim.uv.hrtime() - t0) / 1e6)
  end
  return best
end

T['300 turns: delta under 2 ms, events under 5 ms'] = function()
  local s, buf = stub(), new_buf()
  local view = live_render.attach(buf, s)
  for _, ev in ipairs(SEQ.turns300) do push(s, ev) end
  view:sync('events')
  expect_full(buf, s)
  push(s, { kind = 'prompt', text = 'last question' })
  push(s, { kind = 'tool_call', id = 'z', name = 'Bash', input = { command = 'ls' } })
  push(s, { kind = 'tool_result', id = 'z', text = 'out', is_error = false })
  view:sync('events')
  local i = 0
  local delta = best_of(20, function()
    i = i + 1
    s.streaming = s.streaming .. ('word%d '):format(i) .. (i % 5 == 0 and '\n' or '')
    view:sync('delta')
  end)
  s.streaming = ''
  local events = best_of(20, function()
    push(s, { kind = 'text', text = 'more' })
    view:sync('events')
  end)
  expect_full(buf, s)
  eq(delta < 2, true)
  eq(events < 5, true)
end


T['answer marks: a ● before every text block, the streaming one included; none duplicated by rewrites'] = function()
  local s, buf = stub(), new_buf()
  local view = live_render.attach(buf, s)
  api.nvim_set_current_buf(buf)
  local history = require('agent-ide.ui.history')
  local function marked()
    local out = {}
    for _, l in ipairs(history.answer_marks(buf)) do out[#out + 1] = api.nvim_buf_get_lines(buf, l - 1, l, false)[1] end
    return out
  end
  push(s, { kind = 'prompt', text = 'one' })
  push(s, { kind = 'text', text = 'Looking.' })
  view:sync('events')
  eq(marked(), { 'Looking.' })
  s.streaming = 'Str'
  view:sync('delta')
  eq(marked(), { 'Looking.', 'Str' })
  s.streaming = 'Streamed text'
  view:sync('delta')
  eq(marked(), { 'Looking.', 'Streamed text' })
  s.streaming = ''
  push(s, { kind = 'text', text = 'Streamed text.' })
  push(s, { kind = 'tool_call', id = 'a', name = 'Bash', input = { command = 'ls' } })
  view:sync('events')
  eq(marked(), { 'Looking.', 'Streamed text.' })
  push(s, { kind = 'tool_result', id = 'a', text = 'r' })
  push(s, { kind = 'text', text = 'Done.' })
  view:sync('events')
  eq(marked(), { 'Looking.', 'Streamed text.', 'Done.' })
  push(s, { kind = 'prompt', text = 'two' })
  push(s, { kind = 'text', text = 'Again.' })
  view:sync('events')
  eq(marked(), { 'Looking.', 'Streamed text.', 'Done.', 'Again.' })
  eq(#history.answer_marks(buf), 4)
  -- a reload from disk: the same marks, once
  view:sync('reset')
  eq(marked(), { 'Looking.', 'Streamed text.', 'Done.', 'Again.' })
  eq(#history.answer_marks(buf), 4)
  -- the mark is virtual text in the idle colour; the buffer text has no ●
  local m = api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace('agent-ide.history.answers'), 0, -1, { details = true })[1]
  eq(m[4].virt_text, { { '● ', 'AgentIdeAnswerMark' } })
  eq(m[4].virt_text_pos, 'inline')
  for _, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do eq(l:find('●', 1, true), nil) end
end

return T
