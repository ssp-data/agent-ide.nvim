-- The full diff: the patch parser (git_parse.patch) and the pure renderer (ui/fulldiff_render),
-- from synthetic patch text.
local parse = require('agent-ide.git_parse')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local PATCH = table.concat({
  'diff --git a/lua/x.lua b/lua/x.lua', 'index 1111111..2222222 100644', '--- a/lua/x.lua', '+++ b/lua/x.lua',
  '@@ -1,3 +1,4 @@', ' a', '-b', '+bb', '+c', ' d',
  'diff --git a/new.txt b/new.txt', 'new file mode 100644', 'index 0000000..3333333', '--- /dev/null', '+++ b/new.txt',
  '@@ -0,0 +1 @@', '+hello', '\\ No newline at end of file',
  'diff --git a/old.lua b/dir/new.lua', 'similarity index 90%', 'rename from old.lua', 'rename to dir/new.lua',
  'index 4444444..5555555 100644', '--- a/old.lua', '+++ b/dir/new.lua', '@@ -1 +1 @@', '-x', '+y',
  'diff --git a/img.png b/img.png', 'index 6666666..7777777 100644', 'Binary files a/img.png and b/img.png differ',
  'diff --git a/run.sh b/run.sh', 'old mode 100644', 'new mode 100755',
  'diff --git "a/sp ace \\"q\\".txt" "b/sp ace \\"q\\".txt"', 'index 8888888..9999999 100644',
  '--- "a/sp ace \\"q\\".txt"', '+++ "b/sp ace \\"q\\".txt"', '@@ -1 +1 @@', '-1', '+2',
}, '\n') .. '\n'

T['parse.patch: blocks with paths, renames, binary, mode-only, quoted paths'] = function()
  local b = parse.patch(PATCH)
  eq(#b, 6)
  eq({ b[1].path, b[1].old_path, b[1].binary, b[1].mode_only }, { 'lua/x.lua', nil, false, false })
  eq(b[1].lines, { '@@ -1,3 +1,4 @@', ' a', '-b', '+bb', '+c', ' d' })
  eq(b[2].lines, { '@@ -0,0 +1 @@', '+hello', '\\ No newline at end of file' })
  eq({ b[3].path, b[3].old_path }, { 'dir/new.lua', 'old.lua' })
  eq({ b[4].path, b[4].binary, b[4].lines }, { 'img.png', true, {} })
  eq({ b[5].path, b[5].mode_only, b[5].lines }, { 'run.sh', true, {} })
  eq(b[6].path, 'sp ace "q".txt')
  eq(parse.patch(''), {})
end

T['parse.patch: colour codes on header lines (delta with a styled file header) keep the structure'] = function()
  local E = '\27['
  local b = parse.patch(table.concat({ E .. '1;33mdiff --git a/x.lua b/x.lua' .. E .. '0m', 'index 1..2 100644',
    E .. '1;33m--- a/x.lua' .. E .. '0m', E .. '1;33m+++ b/x.lua' .. E .. '0m', E .. '34m@@ -1 +1 @@' .. E .. '0m',
    E .. '48;2;0;40;0m+a' .. E .. '0K' .. E .. '0m' }, '\n') .. '\n')
  eq(#b, 1)
  eq(b[1].path, 'x.lua')
  eq(b[1].lines, { E .. '34m@@ -1 +1 @@' .. E .. '0m', E .. '48;2;0;40;0m+a' .. E .. '0K' .. E .. '0m' })
end

T['parse.unquote'] = function()
  eq(parse.unquote('plain.txt'), 'plain.txt')
  eq(parse.unquote('"a\\tb\\\\c\\"d\\303\\244.txt"'), 'a\tb\\c"dä.txt')
end

-- Renderer -------------------------------------------------------------------------------------

local render = require('agent-ide.ui.fulldiff_render')
local ICONS = { open = 'v', closed = '>' }

T['render.build: headers with stats, hunks, notes, folds, nodes'] = function()
  local files = {
    { status = 'M', path = 'lua/x.lua', added = 2, removed = 1, binary = false, submodule = false },
    { status = 'R', path = 'dir/new.lua', old_path = 'old.lua', added = 1, removed = 1, binary = false, submodule = false },
    { status = 'M', path = 'img.png', binary = true, submodule = false },
    { status = '?', path = 'big.bin', untracked = true, binary = false, submodule = false },
  }
  local blocks = {
    ['lua/x.lua'] = { lines = { '@@ -1,3 +1,4 @@', ' a', '-b', '+bb', '+c', '\\ No newline at end of file', ' d' } },
    ['dir/new.lua'] = { lines = { '@@ -1 +1 @@', '-x', '+y' } },
    ['big.bin'] = { note = 'not shown (larger than 2 MiB)' },
  }
  local t = render.build(files, blocks, { icons = ICONS, width = 60, fold_over = 500 })
  eq(t.lines[1]:sub(1, 13), 'v M lua/x.lua')
  eq(t.lines[1]:sub(-7), '+2 −1')
  eq(t.lines[2], '@@ -1,3 +1,4 @@')
  eq(t.lines[9], '')
  eq(t.lines[10]:sub(1, 27), 'v R old.lua → dir/new.lua')
  eq(t.lines[15]:sub(1, 11), 'v M img.png')
  eq(t.lines[16], '  binary file, not shown')
  eq(t.lines[19], '  not shown (larger than 2 MiB)')
  eq(t.files, { { path = 'lua/x.lua', line = 1 }, { path = 'dir/new.lua', line = 10 }, { path = 'img.png', line = 15 },
    { path = 'big.bin', line = 18 } })
  eq(t.folds[1], { first = 1, last = 9, closed = false, path = 'lua/x.lua' })
  eq(t.nodes[1], { file = 1, header = true })
  eq(t.nodes[2], { file = 1 })                  -- @@
  eq(t.nodes[3], { file = 1, new_line = 1 })    -- ' a'
  eq(t.nodes[4], { file = 1 })                  -- '-b'
  eq(t.nodes[5], { file = 1, new_line = 2 })    -- '+bb'
  eq(t.nodes[6], { file = 1, new_line = 3 })    -- '+c'
  eq(t.nodes[7], { file = 1 })                  -- '\ No newline'
  eq(t.nodes[8], { file = 1, new_line = 4 })    -- ' d'
  local g = t.line_group
  eq({ g[2], g[4], g[5], g[7], g[16] },
    { 'AgentIdeDiffHunk', 'AgentIdeFullDiffDel', 'AgentIdeFullDiffAdd', 'AgentIdeDiffHunk', 'AgentIdeDiffNote' })
  eq({ t.line_eol[4], t.line_eol[5], t.line_eol[2], t.line_eol[16] }, { true, true, nil, nil })
  eq(g[1], nil) -- a header has ranges in hl, no whole-line colour
  eq(t.hl[1].line, 1)
end

T['render.build: changed text inside paired - / + lines is marked, a wholly different pair is not'] = function()
  local files = { { status = 'M', path = 'a.lua', added = 3, removed = 3, binary = false, submodule = false } }
  local blocks = { ['a.lua'] = { lines = { '@@ -1,4 +1,4 @@', ' ctx',
    '-local x = compute(1)', '-wholly different', '-ü = {a, b}',
    '+local x = compute(2)', '+another thing entirely', '+ü = {a, c}', ' end' } } }
  local t = render.build(files, blocks, { icons = ICONS, width = 60, fold_over = 500 })
  local text = {}
  for _, h in ipairs(t.hl) do
    if h.group == 'AgentIdeFullDiffText' then text[#text + 1] = { h.line, t.lines[h.line]:sub(h.col_start + 1, h.col_end), h.priority } end
  end
  eq(text, { { 4, '1', 110 }, { 7, '2', 110 }, { 6, 'b', 110 }, { 9, 'c', 110 } })
end

T['render.build: a coloured block (delta): codes stripped, spans as ansi groups, the line background to the end'] = function()
  local E = '\27['
  local files = { { status = 'M', path = 'a.lua', added = 1, removed = 1, binary = false, submodule = false } }
  -- delta --color-only: a background per line, a stronger one on the changed word, syntax
  -- colours in the foreground, `ESC[0K` (erase to the end of the line) before the reset
  local blocks = { ['a.lua'] = { colored = true, lines = { '@@ -1,2 +1,2 @@',
    E .. '48;2;63;0;1m-local x = compute(' .. E .. '48;2;144;16;17m1' .. E .. '48;2;63;0;1m)' .. E .. '0m' .. E .. '48;2;63;0;1m' .. E .. '0K' .. E .. '0m',
    E .. '48;2;0;40;0m+' .. E .. '38;2;249;38;114mlocal' .. E .. '38;2;248;248;242m x = compute(' .. E .. '48;2;0;96;0;38;2;190;132;255m2' .. E .. '48;2;0;40;0;38;2;248;248;242m)' .. E .. '0m' .. E .. '48;2;0;40;0m' .. E .. '0K' .. E .. '0m',
    ' ' .. E .. '38;2;249;38;114mlocal' .. E .. '0m y = 2' } } }
  local t = render.build(files, blocks, { icons = ICONS, width = 60, fold_over = 500 })
  eq({ t.lines[3], t.lines[4], t.lines[5] }, { '-local x = compute(1)', '+local x = compute(2)', ' local y = 2' })
  eq({ t.nodes[3], t.nodes[4], t.nodes[5] }, { { file = 1 }, { file = 1, new_line = 1 }, { file = 1, new_line = 2 } })
  -- the coloured lines are kept raw for a decode on demand (the view decodes what it draws)
  eq({ t.raw[2], t.raw[3] == blocks['a.lua'].lines[2], t.raw[5] == blocks['a.lua'].lines[4] }, { nil, true, true })
  -- our own line colours stay out of a coloured block
  for _, h in ipairs(t.hl) do eq(h.group:find('^AgentIdeFullDiff'), nil) end
  eq({ t.line_group[3], t.line_group[4], t.line_group[2] }, { nil, nil, 'AgentIdeDiffHunk' })
  local function decoded(line)
    local out = {}
    for _, h in ipairs(render.decode(t.raw[line], line)) do
      out[#out + 1] = { h.col_start, h.col_end, h.group, h.line_hl or false, h.line }
    end
    return out
  end
  -- the removed line: the whole line in its background, the word in the stronger one, then the
  -- background again to the end of the screen line (a line highlight)
  eq(decoded(3), { { 0, 19, 'AgentIdeAnsi_Y3f0001', false, 3 }, { 19, 20, 'AgentIdeAnsi_Y901011', false, 3 },
    { 20, 21, 'AgentIdeAnsi_Y3f0001', false, 3 }, { 0, 0, 'AgentIdeAnsi_Y3f0001', true, 3 } })
  local four = decoded(4)
  eq(four[2], { 1, 6, 'AgentIdeAnsi_Xf92672_Y002800', false, 4 })
  eq(four[#four], { 0, 0, 'AgentIdeAnsi_Y002800', true, 4 })
  eq(decoded(5), { { 1, 6, 'AgentIdeAnsi_Xf92672', false, 5 } })
  eq(render.decode(nil, 9), {})
end

T['render.build: closed folds by size and by the user; a block without a list entry is kept'] = function()
  local big = { '@@ -1,600 +1,600 @@' }
  for i = 1, 600 do big[#big + 1] = ' line ' .. i end
  local files = { { status = 'M', path = 'a.lua', added = 0, removed = 0, binary = false, submodule = false },
    { status = 'M', path = 'b.lua', added = 1, removed = 0, binary = false, submodule = false } }
  local blocks = { ['a.lua'] = { lines = big }, ['b.lua'] = { lines = { '@@ -1 +1,2 @@', ' x', '+y' } },
    ['c.lua'] = { lines = { '@@ -1 +1 @@', '-p', '+q' } } }
  local t = render.build(files, blocks, { icons = ICONS, width = 60, fold_over = 500, closed = { ['b.lua'] = true } })
  eq({ t.folds[1].closed, t.folds[2].closed, t.folds[3].closed }, { true, true, false })
  eq(t.lines[1]:sub(1, 1), '>')
  eq(t.files[3].path, 'c.lua')
  eq(t.lines[t.files[3].line]:sub(1, 9), 'v M c.lua')
  eq(render.build({}, {}, { icons = ICONS, width = 60, fold_over = 500 }).lines, {})
end

return T
