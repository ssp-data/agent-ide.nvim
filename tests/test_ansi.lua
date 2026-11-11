-- Colour codes (SGR) in tool output: parsed into clean text and coloured spans.
local ansi = require('agent-ide.transcript.ansi')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local E = '\27['

T['a line without codes comes back unchanged, without spans'] = function()
  local text, spans = ansi.parse('plain text')
  eq(text, 'plain text')
  eq(spans, {})
end

T['bold and a reset: the text loses the codes, the span covers the bold part'] = function()
  local text, spans = ansi.parse(E .. '1mFails (0)' .. E .. '0m and Notes')
  eq(text, 'Fails (0) and Notes')
  eq(spans, { { 0, 9, 'AgentIdeAnsi_B' } })
end

T['colours: 16, 256 and true colour, foreground and background, combined with bold'] = function()
  local _, spans = ansi.parse(E .. '31mred' .. E .. '1;92mbright' .. E .. '38;5;208mx' .. E .. '0;38;2;1;2;255my'
    .. E .. '41mz' .. E .. 'm')
  eq(spans, {
    { 0, 3, 'AgentIdeAnsi_F1' },
    { 3, 9, 'AgentIdeAnsi_B_F10' },
    { 9, 10, 'AgentIdeAnsi_B_F208' },
    { 10, 11, 'AgentIdeAnsi_X0102ff' },
    { 11, 12, 'AgentIdeAnsi_X0102ff_G1' },
  })
end

T['attributes switch off one by one: 22, 23, 24, 39'] = function()
  local text, spans = ansi.parse(E .. '1;3;4;32ma' .. E .. '22mb' .. E .. '23mc' .. E .. '24md' .. E .. '39me')
  eq(text, 'abcde')
  eq(spans, {
    { 0, 1, 'AgentIdeAnsi_B_I_U_F2' },
    { 1, 2, 'AgentIdeAnsi_I_U_F2' },
    { 2, 3, 'AgentIdeAnsi_U_F2' },
    { 3, 4, 'AgentIdeAnsi_F2' },
  })
end

T['the style carries over to the next line, as in a terminal'] = function()
  local t1, s1, state = ansi.parse(E .. '33mstart')
  local t2, s2, state2 = ansi.parse('still yellow' .. E .. '0m done', state)
  eq({ t1, t2 }, { 'start', 'still yellow done' })
  eq(s1, { { 0, 5, 'AgentIdeAnsi_F3' } })
  eq(s2, { { 0, 12, 'AgentIdeAnsi_F3' } })
  eq(ansi.parse('after', state2), 'after')
end

T['codes that are not colours stay in the text'] = function()
  local text, spans = ansi.parse('a' .. E .. 'Kb' .. E .. '2Jc')
  eq(text, 'a' .. E .. 'Kb' .. E .. '2Jc')
  eq(spans, {})
end

T['spec: a group name back into highlight attributes'] = function()
  local palette = function(n) return ('#0000%02x'):format(n) end
  eq(ansi.spec('AgentIdeAnsi_B_U_F2_G9', palette, '#888888'),
    { bold = true, underline = true, fg = '#000002', ctermfg = 2, bg = '#000009', ctermbg = 9 })
  eq(ansi.spec('AgentIdeAnsi_X0102ff_Yffffff', palette, '#888888'), { fg = '#0102ff', bg = '#ffffff' })
  -- dim without a colour of its own: the dim colour
  eq(ansi.spec('AgentIdeAnsi_D', palette, '#888888'), { fg = '#888888' })
end

T['xterm: the 256-colour palette above 15'] = function()
  eq({ ansi.xterm(16), ansi.xterm(196), ansi.xterm(231), ansi.xterm(232), ansi.xterm(255) },
    { '#000000', '#ff0000', '#ffffff', '#080808', '#eeeeee' })
end

return T
