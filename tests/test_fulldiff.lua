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

T['parse.unquote'] = function()
  eq(parse.unquote('plain.txt'), 'plain.txt')
  eq(parse.unquote('"a\\tb\\\\c\\"d\\303\\244.txt"'), 'a\tb\\c"dä.txt')
end

return T
