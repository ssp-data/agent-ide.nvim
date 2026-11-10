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

local synth = dofile(vim.fn.getcwd() .. '/tests/synthetic.lua')
local KIB, filler, title_line, big = 1024, synth.filler, synth.title_line, synth.big
local function meta_of(text)
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  local p = d .. '/abc.jsonl'
  local f = assert(io.open(p, 'wb')); f:write(text); f:close()
  local m = scan.meta(p, 1, #text)
  vim.fn.delete(d, 'rf')
  return m
end

T['title of a big file comes from the tail window first'] = function()
  local m = meta_of(big('Early', nil, 'Late'))
  eq({ m.title, m.cwd }, { 'Late', '/w' })
end
T['big file without a late title uses the head window'] = function()
  eq(meta_of(big('Early', 'Middle', nil)).title, 'Early')
end
T['big file title outside both windows is not seen'] = function()
  eq(meta_of(big(nil, 'Middle', nil)).title, 'first prompt')
end
T['first line of the tail window is ignored'] = function()
  local late = title_line('Late')
  local pad = filler(256 * KIB):sub(1, 256 * KIB - #late - 1) .. '\n'
  eq(#late + #pad, 256 * KIB)
  eq(meta_of(big('Early', nil, nil) .. filler(300 * KIB) .. late .. pad).title, 'Early')
end
T['small file: last aiTitle anywhere wins'] = function()
  local text = '{"type":"user","message":{"content":"p"}}\n' .. title_line('One') .. filler(200 * KIB) .. title_line('Two')
  eq(meta_of(text).title, 'Two')
end
T['a user line with an aiTitle key can still be the first prompt'] = function()
  eq(meta_of('{"type":"user","aiTitle":"not a title record","message":{"content":"quoted prompt"}}\n').title, 'quoted prompt')
end
T['an error in the scan callback is reported once at WARN'] = function()
  local notes, orig = {}, vim.notify
  vim.notify = function(msg, level) notes[#notes + 1] = { msg, level } end
  local done = 0
  for _ = 1, 2 do scan.scan(dir, function() done = done + 1; error('consumer boom') end) end
  vim.wait(2000, function() return done == 2 end)
  vim.notify = orig
  eq(#notes, 1)
  eq(notes[1][2], vim.log.levels.WARN)
  eq(notes[1][1]:find('consumer boom', 1, true) ~= nil, true)
end
return T
