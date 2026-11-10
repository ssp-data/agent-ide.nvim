local parse = require('agent-ide.transcript.parse')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()
local fx = 'tests/fixtures/projects/-home-u-git-alpha/11111111-1111-4111-8111-111111111111.jsonl'
local function slurp(p) local f = assert(io.open(p)); local s = f:read('a'); f:close(); return s end

T['fixture matches golden events'] = function()
  local golden = vim.json.decode(slurp('tests/fixtures/golden/alpha-basic.events.json'), { luanil = { object = true, array = true } })
  eq(parse.parse_text(slurp(fx)), golden)
end
T['edge-case fixture matches golden events'] = function()
  local golden = vim.json.decode(slurp('tests/fixtures/golden/edge-cases.events.json'), { luanil = { object = true, array = true } })
  eq(parse.parse_text(slurp('tests/fixtures/edge/edge-cases.jsonl')), golden)
end
T['invalid, blank and cut-off lines yield no events and do not raise'] = function()
  eq(parse.parse_line(''), {})
  eq(parse.parse_line('{"type":"user","message":{"content":"hal'), {})
  eq(parse.parse_line('not json'), {})
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
