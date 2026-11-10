local parse = require('agent-ide.transcript.parse')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()
local fx = 'tests/fixtures/projects/-home-u-git-alpha/11111111-1111-4111-8111-111111111111.jsonl'
local function slurp(p) local f = assert(io.open(p)); local s = f:read('a'); f:close(); return s end

T['fixture matches golden events'] = function()
  local golden = vim.json.decode(slurp('tests/fixtures/golden/alpha-basic.events.json'), parse.DECODE_OPTS)
  eq(parse.parse_text(slurp(fx)), golden)
end
T['edge-case fixture matches golden events'] = function()
  local golden = vim.json.decode(slurp('tests/fixtures/golden/edge-cases.events.json'), parse.DECODE_OPTS)
  eq(parse.parse_text(slurp('tests/fixtures/edge/edge-cases.jsonl')), golden)
end
T['blank lines yield nothing; invalid lines are unknown events'] = function()
  eq(parse.parse_line(''), {})
  eq(parse.parse_line('   \t'), {})
  local cut = '{"type":"user","message":{"content":"hal'
  eq(parse.parse_line(cut), { { kind = 'unknown', label = 'invalid JSON', raw = cut } })
  eq(parse.parse_line('not json'), { { kind = 'unknown', label = 'invalid JSON', raw = 'not json' } })
  eq(parse.parse_line('42'), { { kind = 'unknown', label = '?', raw = '42' } })
  eq(parse.parse_line('null'), { { kind = 'unknown', label = '?', raw = 'null' } })
end
T['only an unterminated last line that does not decode is skipped'] = function()
  local cut = '{"type":"user","message":{"content":"hal'
  eq(parse.parse_text('not json\n' .. cut), { { kind = 'unknown', label = 'invalid JSON', raw = 'not json' } })
  eq(parse.parse_text(cut .. '\n'), { { kind = 'unknown', label = 'invalid JSON', raw = cut } })
  eq(parse.parse_text('{"type":"user","message":{"content":"whole"}}'), { { kind = 'prompt', text = 'whole' } })
end
T['object content and null elements lose nothing'] = function()
  local obj = '{"type":"assistant","message":{"content":{"type":"text","text":"t"}}}'
  eq(parse.parse_line(obj), { { kind = 'unknown', label = 'content', raw = obj } })
  local nulls = '{"type":"user","message":{"content":{"a":null}}}'
  eq(parse.parse_line(nulls), { { kind = 'unknown', label = 'content', raw = nulls } })
  eq(parse.parse_line('{"type":"assistant","message":{"content":[]}}'), {})
  eq(parse.parse_line('{"type":"assistant","message":{"content":[{"type":"text","text":"a"},null,{"type":"text","text":"b"},null]}}'), {
    { kind = 'text', text = 'a' },
    { kind = 'unknown', label = 'null', raw = 'null' },
    { kind = 'text', text = 'b' },
    { kind = 'unknown', label = 'null', raw = 'null' },
  })
  local tr = '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"x","content":[{"type":"text","text":"a"},null,{"type":"text","text":"b"}]}]}}'
  eq(parse.parse_line(tr)[1].text, 'a\n[null]\nb')
end
T['invalid UTF-8 is replaced exactly like Rust from_utf8_lossy'] = function()
  local R = '\239\191\189'
  eq(parse.fix_utf8('plain ascii'), 'plain ascii')
  eq(parse.fix_utf8('ok é € 😀'), 'ok é € 😀')
  eq(parse.fix_utf8('ab\255c'), 'ab' .. R .. 'c')
  eq(parse.fix_utf8('a\237\160\128b'), 'a' .. R .. R .. R .. 'b') -- encoded surrogate
  eq(parse.fix_utf8('x\240\159\152y'), 'x' .. R .. 'y') -- truncated 4-byte sequence: one U+FFFD
  eq(parse.fix_utf8('\224\128'), R .. R)
  eq(parse.fix_utf8('\192\175'), R .. R) -- overlong
  eq(parse.parse_line('{"type":"user","message":{"content":"bad \255 byte"}}'), { { kind = 'prompt', text = 'bad ' .. R .. ' byte' } })
end
T['system records are meta events'] = function()
  eq(parse.parse_line('{"type":"system","subtype":"compact_boundary","content":"done"}'),
    { { kind = 'meta', label = 'system: compact_boundary', text = 'done' } })
  local line = '{"type":"system","isSidechain":true,"content":{"a":1}}'
  eq(parse.parse_line(line), { { kind = 'meta', label = 'system', text = line, sidechain = true } })
  eq(parse.parse_line('{"type":"attachment","x":1}'), {})
end
T['unknown record type becomes unknown event with raw text'] = function()
  local line = '{"type":"future-thing","x":1}'
  eq(parse.parse_line(line), { { kind = 'unknown', label = 'future-thing', raw = line } })
end
T['bookkeeping yields nothing'] = function()
  eq(parse.parse_line('{"type":"api-request-blob","hash":"h","message":{"content":"zzz"}}'), {})
end
T['unknown block raw is the exact original text, scalars included'] = function()
  local block = [[{"type": "odd" , "k":"{[\"x\"]} \\", "n":[[1,{"a":"]"}], 2],"o":{"z":[]}}]]
  local line = '{"type":"assistant","message":{"content":["scalar", 7 ,' .. block .. ',{"type":"text","text":"ok"}]}}'
  eq(parse.parse_line(line), {
    { kind = 'unknown', label = 'string', raw = '"scalar"' },
    { kind = 'unknown', label = 'number', raw = '7' },
    { kind = 'unknown', label = 'odd', raw = block },
    { kind = 'text', text = 'ok' },
  })
end
T['numeric block type label uses Lua number formatting'] = function()
  local function label(n)
    return parse.parse_line('{"type":"assistant","message":{"content":[{"type":' .. n .. '}]}}')[1].label
  end
  eq(label('100000000000000'), '1e+14')
  eq(label('99999999999999'), '99999999999999')
  eq(label('1.5'), '1.5')
  eq(label('0.00001'), '1e-05')
  eq(label('123456789012345678'), '1.2345678901235e+17')
end
return T
