-- Unit cases for the trash's file primitives (safe writes, copy and verify, moves) on temp
-- folders, in this Neovim: no child, no Claude folder.
local eq = MiniTest.expect.equality
local jsonfile = require('agent-ide.util.jsonfile')

local tmp
local real_write = jsonfile._write

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    jsonfile._write = real_write
  end,
  post_case = function()
    jsonfile._write = real_write
    vim.fn.delete(tmp, 'rf')
  end,
} })

local function write(path, text, mode)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(text)
  f:close()
  if mode then vim.uv.fs_chmod(path, mode) end
end

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local t = f:read('a')
  f:close()
  return t
end

local function names(dir)
  local out = {}
  for name in vim.fs.dir(dir) do out[#out + 1] = name end
  table.sort(out)
  return out
end

-- A writer that writes at most `n` bytes per call (0: none at all).
local function short_writer(n)
  return function(fd, data, offset) return real_write(fd, data:sub(1, n), offset) end
end

T['write_atomic: replaces the file, keeps the given mode, leaves no temp file'] = function()
  local p = tmp .. '/f.json'
  write(p, 'old', 420)
  eq(jsonfile.write_atomic(p, 'new text', 420), true)
  eq(read(p), 'new text')
  eq(vim.uv.fs_stat(p).mode % 4096, 420)
  eq(names(tmp), { 'f.json' })
end

T['write_atomic: writes that come back short are continued until every byte is there'] = function()
  jsonfile._write = short_writer(3)
  local p = tmp .. '/f.json'
  eq(jsonfile.write_atomic(p, ('x'):rep(100) .. '\n', 384), true)
  eq(read(p), ('x'):rep(100) .. '\n')
end

T['write_atomic: a writer that stops making progress fails; the original stays, no temp file'] = function()
  local p = tmp .. '/f.json'
  write(p, 'original', 384)
  jsonfile._write = short_writer(0)
  local ok, err = jsonfile.write_atomic(p, 'a much longer replacement text', 384)
  eq(ok, nil)
  eq(type(err), 'string')
  eq(read(p), 'original')
  eq(names(tmp), { 'f.json' })
  -- an error from the writer: the same
  jsonfile._write = function() return nil, 'ENOSPC: no space left on device' end
  ok, err = jsonfile.write_atomic(p, 'replacement', 384)
  eq({ ok, err }, { nil, 'ENOSPC: no space left on device' })
  eq(read(p), 'original')
  eq(names(tmp), { 'f.json' })
end

T['write_atomic: a writer that claims more than the file got is caught by the size check'] = function()
  local p = tmp .. '/f.json'
  write(p, 'original', 384)
  -- reports every byte but writes half of them
  jsonfile._write = function(fd, data, offset)
    real_write(fd, data:sub(1, math.floor(#data / 2)), offset)
    return #data
  end
  local ok, err = jsonfile.write_atomic(p, 'a replacement that is cut in half', 384)
  eq(ok, nil)
  eq(err:find('size', 1, true) ~= nil, true)
  eq(read(p), 'original')
  eq(names(tmp), { 'f.json' })
end

T['jsonfile.write uses the safe writer: a short write keeps the old file'] = function()
  local p = tmp .. '/state/hidden.json'
  eq(type(jsonfile.write(p, { version = 1, ids = { a = true } })), 'string')
  local before = read(p)
  jsonfile._write = short_writer(0)
  local stamp, err = jsonfile.write(p, { version = 1, ids = { a = true, b = true } })
  eq(stamp, nil)
  eq(type(err), 'string')
  eq(read(p), before)
  eq(names(tmp .. '/state'), { 'hidden.json' })
  eq(vim.uv.fs_stat(p).mode % 512, 384)
  -- never under a .claude folder
  jsonfile._write = real_write
  eq(select(2, jsonfile.write(tmp .. '/.claude/x.json', { version = 1 })), 'refusing to write under a .claude folder')
end

T['append: adds every byte at the end'] = function()
  local p = tmp .. '/h.jsonl'
  write(p, 'a\n', 384)
  jsonfile._write = short_writer(2)
  eq(jsonfile.append(p, 'bcdefg\n'), true)
  eq(read(p), 'a\nbcdefg\n')
  jsonfile._write = short_writer(0)
  eq(jsonfile.append(p, 'more\n'), nil)
end

T['holders: finds another process that keeps a file open (Linux)'] = function()
  if not vim.uv.fs_stat('/proc/self/fd') then return MiniTest.skip('no /proc') end
  local h = require('agent-ide.trash_history')
  local p = tmp .. '/history.jsonl'
  write(p, 'x\n')
  eq(h.holders(p), {})
  local proc = vim.system({ 'sh', '-c', 'exec 3>>"$1"; echo ready; sleep 5', 'sh', p }, { text = true, stdout = function() end })
  local ok, err = pcall(function()
    local found
    vim.wait(3000, function()
      found = h.holders(p)
      return #found > 0
    end, 20)
    eq(found, { proc.pid })
  end)
  proc:kill('sigterm')
  proc:wait(2000)
  if not ok then error(err, 0) end
end

-- Moves ------------------------------------------------------------------------------------------

local fs = require('agent-ide.trash_fs')
local real_rename = fs._rename
local function exdev(a, b)
  if vim.uv.fs_lstat(a) then return nil, 'EXDEV: cross-device link not permitted' end
  return real_rename(a, b)
end

-- A session folder with a nested file, an empty folder and a relative symlink.
local function session_tree(root)
  write(root .. '/subagents/agent-1.jsonl', 'sub\n', 384)
  write(root .. '/tool-results/r1.txt', ('result\n'):rep(1000), 420)
  vim.fn.mkdir(root .. '/empty', 'p')
  vim.uv.fs_symlink('tool-results/r1.txt', root .. '/latest')
end

local function tree_of(root)
  local out = {}
  local function walk(dir, rel)
    for name, typ in vim.fs.dir(dir) do
      local p, r = dir .. '/' .. name, rel .. '/' .. name
      local st = vim.uv.fs_lstat(p)
      out[r] = { typ, st.mode % 4096, typ == 'file' and read(p) or typ == 'link' and vim.uv.fs_readlink(p) or nil }
      if typ == 'directory' then walk(p, r) end
    end
  end
  walk(root, '')
  return out
end

T['scan: special files are refused, symlinks are listed (never followed)'] = function()
  session_tree(tmp .. '/s')
  local list, err = fs.scan(tmp .. '/s')
  eq(err, nil)
  local kinds = {}
  for _, e in ipairs(list) do kinds[e.rel] = e.type end
  eq(kinds['latest'], 'link')
  eq(kinds['empty'], 'directory')
  vim.fn.system({ 'mkfifo', tmp .. '/s/subagents/pipe' })
  eq(vim.v.shell_error, 0)
  list, err = fs.scan(tmp .. '/s')
  eq(list, nil)
  eq(err, 'a special file (fifo): ' .. tmp .. '/s/subagents/pipe')
end

T['move across file systems: copied (links as links), verified, source removed'] = function()
  session_tree(tmp .. '/s')
  local want = tree_of(tmp .. '/s')
  fs._rename = exdev
  local ok, err, left = fs.move(tmp .. '/s', tmp .. '/trash/x/s', {})
  fs._rename = real_rename
  eq({ ok, err, left }, { true, nil, nil })
  eq(vim.uv.fs_lstat(tmp .. '/s'), nil)
  eq(tree_of(tmp .. '/trash/x/s'), want)
  eq(vim.uv.fs_lstat(tmp .. '/trash/x/s/latest').type, 'link')
  -- a single file as well
  write(tmp .. '/t.jsonl', 'transcript\n', 384)
  fs._rename = exdev
  ok = fs.move(tmp .. '/t.jsonl', tmp .. '/trash/x/t.jsonl', {})
  fs._rename = real_rename
  eq(ok, true)
  eq(read(tmp .. '/trash/x/t.jsonl'), 'transcript\n')
end

T['verify: same size but other content, a missing file, another link target all fail'] = function()
  session_tree(tmp .. '/a')
  session_tree(tmp .. '/b')
  eq(fs.verify(tmp .. '/a', tmp .. '/b'), true)
  write(tmp .. '/b/subagents/agent-1.jsonl', 'SUB\n', 384)
  local ok, err = fs.verify(tmp .. '/a', tmp .. '/b')
  eq(ok, false)
  eq(err, 'content differs: subagents/agent-1.jsonl')
  write(tmp .. '/b/subagents/agent-1.jsonl', 'sub\n', 384)
  vim.uv.fs_unlink(tmp .. '/b/latest')
  eq(select(2, fs.verify(tmp .. '/a', tmp .. '/b')), 'file count differs')
  vim.uv.fs_symlink('subagents/agent-1.jsonl', tmp .. '/b/latest')
  eq(select(2, fs.verify(tmp .. '/a', tmp .. '/b')), 'link target differs: latest')
end

T['move across file systems: a copy that does not verify is removed, the source stays'] = function()
  session_tree(tmp .. '/s')
  local want = tree_of(tmp .. '/s')
  fs._rename = exdev
  fs._after_copy = function(dst) write(dst .. '/tool-results/r1.txt', 'X', 420) end
  local ok, err = fs.move(tmp .. '/s', tmp .. '/trash/x/s', {})
  fs._rename, fs._after_copy = real_rename, nil
  eq(ok, nil)
  eq(err:find('copy of ' .. tmp .. '/s does not match', 1, true) ~= nil, true)
  eq(tree_of(tmp .. '/s'), want)
  eq(vim.uv.fs_lstat(tmp .. '/trash/x/s'), nil)
end

T['move across file systems: when the source cannot be fully removed, the move still counts'] = function()
  session_tree(tmp .. '/s')
  local want = tree_of(tmp .. '/s')
  vim.uv.fs_chmod(tmp .. '/s/subagents', 320) -- 0500: its file cannot be unlinked
  fs._rename = exdev
  local ok, err, left = fs.move(tmp .. '/s', tmp .. '/trash/x/s', {})
  fs._rename = real_rename
  vim.uv.fs_chmod(tmp .. '/s/subagents', 448)
  eq({ ok, err }, { true, nil })
  table.sort(left)
  eq(left, { tmp .. '/s', tmp .. '/s/subagents', tmp .. '/s/subagents/agent-1.jsonl' })
  -- the copy is complete
  local got = tree_of(tmp .. '/trash/x/s')
  want['/subagents'][2] = got['/subagents'][2] -- the mode the test changed
  eq(got, want)
end

T['cleanup removes only what is empty, bottom-up, and says what is left'] = function()
  vim.fn.mkdir(tmp .. '/t/a/b', 'p')
  vim.fn.mkdir(tmp .. '/t/c', 'p')
  write(tmp .. '/t/c/keep', 'x')
  local left = fs.cleanup(tmp .. '/t', { tmp .. '/t/a', tmp .. '/t/a/b', tmp .. '/t/c' })
  eq(left, { tmp .. '/t/c', tmp .. '/t' })
  eq(read(tmp .. '/t/c/keep'), 'x')
  eq(vim.uv.fs_lstat(tmp .. '/t/a'), nil)
end

return T
