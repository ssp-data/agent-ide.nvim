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

return T
