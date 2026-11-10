-- Pure row layout of the drawer: display widths, truncation and right-aligned columns.
local layout = require('agent-ide.ui.layout')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function text(pieces)
  local out = {}
  for i, p in ipairs(pieces) do out[i] = p[1] end
  return table.concat(out)
end
local W = vim.fn.strdisplaywidth

T['width: ASCII, umlauts, CJK, emoji'] = function()
  eq(layout.width('abc'), 3)
  eq(layout.width('Übersetzung für Bäume'), 21)
  eq(layout.width('日本語'), 6)
  eq(layout.width('ok 🎉'), 5)
  eq(layout.width(''), 0)
end

T['truncate never splits a character and never exceeds the width'] = function()
  eq(layout.truncate('abcdef', 10), 'abcdef')
  eq(layout.truncate('abcdef', 4), 'abc…')
  eq(layout.truncate('abcdef', 1), '…')
  eq(layout.truncate('abcdef', 0), '')
  eq(layout.truncate('Übersetzung', 5), 'Über…')
  -- a wide character that does not fit is left out whole
  eq(layout.truncate('日本語です', 6), '日本…')
  eq(layout.truncate('日本語です', 5), '日本…')
  eq(layout.truncate('ab🎉cd', 4), 'ab…')
  for _, s in ipairs({ 'Übersetzung für Bäume', '日本語のタイトルです', 'emoji 🎉🎉🎉 party', string.rep('x', 300) }) do
    for w = 1, 25 do
      local t = layout.truncate(s, w)
      eq(W(t) <= w, true)
      eq(vim.str_utf_pos(t) ~= nil and vim.fn.strchars(t) == #vim.str_utf_pos(t), true)
      eq(vim.fn.byteidx(t, vim.fn.strchars(t)) == #t, true) -- valid UTF-8 boundaries
    end
  end
end

T['row: the right part ends at the right edge'] = function()
  local p = layout.row({ { '  ' }, { 'Fix login', nil, fit = true } }, { { 'now', 'AgentIdeAge' } }, 20)
  eq(text(p), '  Fix login      now')
  eq(W(text(p)), 20)
  -- the highlight group of each piece is kept
  eq(p[#p][2], 'AgentIdeAge')
end

T['row: without a width the right part follows after two spaces'] = function()
  eq(text(layout.row({ { 'a' }, { 'title', nil, fit = true } }, { { 'now' } })), 'atitle  now')
  eq(text(layout.row({ { 'a' } }, {})), 'a')
end

T['row: a long title is cut with an ellipsis; the right part stays whole'] = function()
  local long = string.rep('x', 300)
  local p = layout.row({ { '      ' }, { 'B', 'AgentIdeBusy' }, { ' ' }, { long, nil, fit = true } },
    { { 'permission: Bash', 'AgentIdeWaiting' }, { ' ' }, { '12m', 'AgentIdeAge' } }, 44)
  local s = text(p)
  eq(W(s), 44)
  eq(vim.endswith(s, '…  permission: Bash 12m'), true)
  eq(vim.startswith(s, '      B xxx'), true)
end

T['row: multi-byte titles align by display width'] = function()
  for _, title in ipairs({ 'Übersetzung prüfen', '日本語のタイトル', 'Party 🎉 time', 'ascii title' }) do
    local s = text(layout.row({ { '  ' }, { title, nil, fit = true } }, { { '3h' } }, 30))
    eq(W(s), 30)
    eq(vim.endswith(s, ' 3h'), true)
  end
  for _, title in ipairs({ 'Übersetzung prüfen und mehr Text', '日本語のタイトルはとても長いです', 'Party 🎉🎉🎉🎉🎉🎉🎉🎉 time' }) do
    local s = text(layout.row({ { '  ' }, { title, nil, fit = true } }, { { '3h' } }, 20))
    eq(W(s), 20) -- a wide character left out is made up by the padding
    eq(s:match('…%s+3h$') ~= nil, true)
  end
end

T['row: several fit pieces shrink last first'] = function()
  local s = text(layout.row({ { '> ' }, { 'project-name', nil, fit = true }, { '  feature-branch', nil, fit = true } },
    { { 'B 2m' } }, 26))
  eq(s, '> project-name  fea…  B 2m')
  eq(W(s), 26)
end

T['row: a marker piece shrinks only after the title'] = function()
  local left = { { '> ' }, { 'name', 'AgentIdeProject', fit = true }, { ' (folder missing)', 'AgentIdeMissing', fit = 'last' } }
  eq(text(layout.row(left, { { '. 2m' } }, 30)), '> name (folder missing)   . 2m')
  eq(text(layout.row(left, { { '. 2m' } }, 26)), '> … (folder missing)  . 2m')
  eq(text(layout.row(left, { { '. 2m' } }, 20)), '> … (folder m…  . 2m')
  eq(text(layout.row(left, { { '. 2m' } }, 12)), '> …     . 2m') -- no room left: the marker goes
end

T['row: very narrow (24 columns) and deep indent: the right part is still whole'] = function()
  local s = text(layout.row({ { string.rep(' ', 14) }, { 'a title', nil, fit = true } }, { { 'failed: quota' } }, 24))
  eq(vim.endswith(s, 'failed: quota'), true)
  eq(s:find('…', 1, true) ~= nil, true)
end

T['row: a droppable piece goes away instead of shrinking below 6 cells'] = function()
  local left = { { '      Invoice text' }, { '  Short invoice text', 'AgentIdeAge', fit = 'drop' } }
  eq(text(layout.row(left, {}, 30)), '      Invoice text  Short inv…')
  eq(text(layout.row(left, {}, 22)), '      Invoice text')
  eq(text(layout.row(left, {}, 80)), '      Invoice text  Short invoice text')
end

T['row: no right part and a fitting line stays exactly as given'] = function()
  local left = { { '  ' }, { 'Sessions (2)', 'AgentIdeSection' } }
  eq(layout.row(left, {}, 44), left)
end

return T
