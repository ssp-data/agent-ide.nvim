local parse = require('agent-ide.transcript.parse')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()
local fx = 'tests/fixtures/projects/-home-u-git-alpha/11111111-1111-4111-8111-111111111111.jsonl'
local function slurp(p) local f = assert(io.open(p)); local s = f:read('a'); f:close(); return s end

T['fixture matches golden events'] = function()
  local golden = vim.json.decode(slurp('tests/fixtures/golden/alpha-basic.events.json'), { luanil = { object = true, array = true } })
  eq(parse.parse_text(slurp(fx)), golden)
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
return T
