local scan = require('agent-ide.index.lua_scan')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()
local dir = vim.fn.fnamemodify('tests/fixtures/projects', ':p'):gsub('/$', '')
local function run(d) local out; scan.scan(d, function(s) out = s end); vim.wait(2000, function() return out ~= nil end); return out end
local function by_id(list, prefix) for _, s in ipairs(list) do if vim.startswith(s.id, prefix) then return s end end end

T['meta: title from ai-title, cwd and branch'] = function()
  local s = by_id(run(dir), '1111')
  eq({ s.title, s.cwd, s.branch }, { 'Alpha basics', '/home/u/git/alpha', 'feat/x' })
  eq(type(s.mtime), 'number'); eq(s.size > 0, true)
end
T['meta: falls back to first prompt, then (untitled)'] = function()
  local all = run(dir)
  eq(by_id(all, '2222').title, 'Write the docs intro paragraph')
  eq(by_id(all, '2222').cwd, '/home/u/git/alpha/docs')
  eq(by_id(all, '3333').title, 'Meeting notes summary')
  eq(by_id(all, '4444').title, '(untitled)')
  eq(by_id(all, '4444').cwd, nil)
end
T['scan finds every fixture session and is asynchronous'] = function()
  local called = false
  scan.scan(dir, function() called = true end)
  eq(called, false)
  eq(#run(dir), 4)
end
T['missing projects dir gives empty list'] = function() eq(run('/nonexistent/x'), {}) end
T['unreadable file gives untitled meta'] = function()
  local m = scan.meta('/nonexistent/x/abc.jsonl', 1, 2)
  eq({ m.id, m.title, m.cwd }, { 'abc', '(untitled)', nil })
end
T['index facade'] = function()
  local index = require('agent-ide.index')
  require('agent-ide.config').setup({ helper = { enabled = false } })
  eq(index.backend(), 'lua')
  local out; index.scan(function(s) out = s end, dir); vim.wait(2000, function() return out ~= nil end)
  eq(#out, 4)
  require('agent-ide.config').setup({})
end
T['history returns the same events as parse_text'] = function()
  local p = by_id(run(dir), '1111').path
  local ev; scan.history(p, function(e) ev = e end); vim.wait(2000, function() return ev ~= nil end)
  local f = io.open(p); local text = f:read('a'); f:close()
  eq(ev, require('agent-ide.transcript.parse').parse_text(text))
end
T['non-string prompt text keeps the session and is skipped'] = function()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d .. '/-p', 'p')
  local f = assert(io.open(d .. '/-p/abc.jsonl', 'w'))
  f:write('{"type":"user","message":{"content":[{"type":"text","text":5}]}}\n')
  f:write('{"type":"user","message":{"content":"real prompt"}}\n')
  f:close()
  local all = run(d)
  eq(#all, 1)
  eq(all[1].title, 'real prompt')
  vim.fn.delete(d, 'rf')
end
return T
