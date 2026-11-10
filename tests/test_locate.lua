-- Event index -> rendered line, derived from the renderer.
local locate = require('agent-ide.transcript.locate')
local render = require('agent-ide.transcript.render')
local parse = require('agent-ide.transcript.parse')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function first_line(s) return (vim.split(s, '\n', { plain = true }))[1] end

-- What the line of event `ev` must show in a full render.
local function expected(ev)
  if ev.kind == 'prompt' or ev.kind == 'text' then return first_line(ev.text) end
  if ev.kind == 'tool_call' then return '▸ ' .. ev.name .. ': ' end
  if ev.sidechain then return '▸ subagent' end
end

local function check(events)
  local lines = render.render(events).lines
  local checked = 0
  for i, ev in ipairs(events) do
    -- `render` shows a sidechain prompt as a prompt, other sidechain events in a subagent block
    local want = (ev.sidechain and ev.kind ~= 'prompt') and '▸ subagent' or expected(ev)
    if want then
      local l = locate.line(events, i)
      local got = lines[l]
      if not got or got:sub(1, #want) ~= want then
        error(('event %d (%s): line %s is %q, want %q'):format(i, ev.kind, tostring(l), tostring(got), want), 0)
      end
      checked = checked + 1
    end
  end
  return checked
end

T['every prompt, answer and tool call maps to its rendered line'] = function()
  local events = {
    { kind = 'text', text = 'before any prompt' },
    { kind = 'prompt', text = 'first prompt\nsecond line' },
    { kind = 'thinking', text = 'hmm' },
    { kind = 'text', text = 'answer one' },
    { kind = 'tool_call', id = 'a', name = 'Bash', input = { command = 'ls' } },
    { kind = 'tool_call', id = 'b', name = 'Read', input = { file_path = 'x' } },
    { kind = 'text', text = 'text between calls and results' },
    { kind = 'tool_result', id = 'a', text = 'out a\nmore' },
    { kind = 'tool_result', id = 'b', text = 'out b' },
    { kind = 'tool_result', id = 'zzz', text = 'orphan' },
    { kind = 'prompt', text = 'sub prompt', sidechain = true },
    { kind = 'text', text = 'sub answer', sidechain = true },
    { kind = 'text', text = 'after the subagent' },
    { kind = 'tool_result', id = 'c', text = 'result before its call' },
    { kind = 'tool_call', id = 'c', name = 'Grep', input = { pattern = 'p' } },
    { kind = 'meta', label = 'meta', text = 'm' },
    { kind = 'prompt', text = 'second prompt' },
    { kind = 'prompt', text = 'third prompt right after' },
    { kind = 'text', text = 'last answer' },
  }
  eq(check(events), 13)
end

T['a prompt right after a prompt, and a subagent block that holds a prompt'] = function()
  local lines = render.render({
    { kind = 'prompt', text = 'p' },
    { kind = 'prompt', text = 'q', sidechain = true },
    { kind = 'text', text = 's1', sidechain = true },
    { kind = 'prompt', text = 's2', sidechain = true },
    { kind = 'text', text = 'after' },
  }).lines
  local events = {
    { kind = 'prompt', text = 'p' },
    { kind = 'prompt', text = 'q', sidechain = true },
    { kind = 'text', text = 's1', sidechain = true },
    { kind = 'prompt', text = 's2', sidechain = true },
    { kind = 'text', text = 'after' },
  }
  eq(lines[locate.line(events, 2)], 'q')
  eq(lines[locate.line(events, 3)]:sub(1, #'▸ subagent'), '▸ subagent')
  eq(locate.line(events, 4), locate.line(events, 3))
  eq(lines[locate.line(events, 5)], 'after')
end

T['fixture transcripts map every event kind it shows'] = function()
  for _, p in ipairs({ 'tests/fixtures/projects/-home-u-git-alpha/11111111-1111-4111-8111-111111111111.jsonl',
    'tests/fixtures/edge/edge-cases.jsonl' }) do
    local f = assert(io.open(p, 'rb'))
    local events = parse.parse_text(f:read('a'))
    f:close()
    eq(check(events) > 3, true)
  end
end

T['turn bounds and out of range'] = function()
  local events = { { kind = 'text', text = 'x' }, { kind = 'prompt', text = 'p' }, { kind = 'text', text = 'y' } }
  eq(locate.turn_of(events, 1), { first = 1, last = 1 })
  eq(locate.turn_of(events, 3), { first = 2, last = 3 })
  eq(locate.line(events, 9), nil)
  eq(locate.line({}, 1), nil)
end

return T
