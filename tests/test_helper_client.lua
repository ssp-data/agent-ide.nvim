local config = require('agent-ide.config')
local index = require('agent-ide.index')
local helper = require('agent-ide.index.helper')
local lua_scan = require('agent-ide.index.lua_scan')
local eq = MiniTest.expect.equality

local dir = vim.fn.fnamemodify('tests/fixtures/projects', ':p'):gsub('/$', '')
local notes, orig_notify

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    config.setup({})
    helper._reset(); index._reset()
    notes = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
  end,
  post_case = function()
    vim.notify = orig_notify
    helper._reset(); index._reset()
    config.setup({})
  end,
} })

local function need_helper() if not helper.available() then MiniTest.skip('helper not built') end end
local function wait(pred, ms) return vim.wait(ms or 3000, pred, 10) end
local function scan(d)
  local out; index.scan(function(s) out = s end, d)
  wait(function() return out ~= nil end, 6000)
  return out
end
local function history(p)
  local out; index.history(p, function(e) out = e end)
  wait(function() return out ~= nil end, 6000)
  return out
end
local function by_id(list)
  local t = vim.deepcopy(list)
  table.sort(t, function(a, b) return a.id < b.id end)
  return t
end
local function script(body)
  local p = vim.fn.tempname()
  vim.fn.writefile({ '#!/bin/sh', body }, p)
  vim.uv.fs_chmod(p, tonumber('755', 8))
  return p
end
local function lua_only(fn)
  config.setup({ helper = { enabled = false } })
  index._reset()
  return fn()
end
local fixture_path = dir .. '/-home-u-git-alpha/11111111-1111-4111-8111-111111111111.jsonl'

T['backend is lua when helper disabled or missing'] = function()
  config.setup({ helper = { enabled = false } })
  eq(index.backend(), 'lua')
  config.setup({ helper = { enabled = true, path = '/nonexistent/agent-ide-helper' } })
  eq(index.backend(), 'lua')
  eq(helper.available(), false)
end

T['backend is helper when enabled and built'] = function()
  need_helper()
  eq(index.backend(), 'helper')
end

T['helper scan equals lua scan on fixtures'] = function()
  need_helper()
  local h = by_id(scan(dir))
  eq(index.backend(), 'helper')
  local l = by_id(lua_only(function() return scan(dir) end))
  eq(#h, 4)
  eq(h, l)
end

T['helper history equals lua history on fixtures'] = function()
  need_helper()
  local paths = { vim.fn.fnamemodify('tests/fixtures/edge/edge-cases.jsonl', ':p'), fixture_path }
  for _, p in ipairs(paths) do
    local h = history(p)
    eq(index.backend(), 'helper')
    local l = lua_only(function() return history(p) end)
    eq(#h > 0, true)
    eq(vim.deep_equal(h, l), true)
    config.setup({}); index._reset()
  end
end

T['history of a missing file is empty under both backends, without fallback'] = function()
  eq(lua_only(function() return history('/nonexistent/x/abc.jsonl') end), {})
  eq(#notes, 0)
  need_helper()
  config.setup({}); index._reset()
  eq(history('/nonexistent/x/abc.jsonl'), {})
  eq(index.backend(), 'helper')
  eq(#notes, 0)
end

T['failing helper falls back and notifies once'] = function()
  config.setup({ helper = { enabled = true, path = script('echo garbage; exit 1') } })
  eq(index.backend(), 'helper')
  eq(#scan(dir), 4)
  eq(index.backend(), 'lua')
  eq(#scan(dir), 4)
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.WARN)
  eq(notes[1].msg:match('^Agent%-IDE: helper failed %(.+%), using Lua fallback$') ~= nil, true)
end

T['unspawnable helper falls back'] = function()
  local p = vim.fn.tempname()
  vim.fn.writefile({ '#!/nonexistent/interpreter' }, p)
  vim.uv.fs_chmod(p, tonumber('755', 8))
  config.setup({ helper = { enabled = true, path = p } })
  eq(#scan(dir), 4)
  eq(index.backend(), 'lua')
  eq(#notes, 1)
end

T['silent helper times out and falls back'] = function()
  config.setup({ helper = { enabled = true, path = script('cat >/dev/null') } })
  helper._timeout_ms = 200
  eq(#scan(dir), 4)
  eq(index.backend(), 'lua')
  eq(#notes, 1)
  eq(notes[1].msg:find('timeout', 1, true) ~= nil, true)
end

T['request ids are matched and timers cancelled'] = function()
  need_helper()
  local a, b
  helper.request('scan', { projects_dir = dir }, function(e, r) a = { e, r } end)
  helper.request('history', { path = fixture_path }, function(e, r) b = { e, r } end)
  wait(function() return a and b end, 6000)
  eq(a[1], nil); eq(#a[2].sessions, 4)
  eq(b[1], nil); eq(type(b[2].events), 'table')
  local e
  helper.request('nope', {}, function(err) e = err end)
  wait(function() return e ~= nil end)
  eq(type(e), 'string')
end

T['stop is idempotent'] = function()
  need_helper()
  scan(dir)
  helper.stop(); helper.stop()
  eq(#scan(dir), 4) -- restarts lazily
  helper.stop()
end

T['stopping with a request pending is not a failure'] = function()
  need_helper()
  local out
  index.scan(function(s) out = s end, dir)
  helper.stop()
  wait(function() return out ~= nil end, 6000)
  eq(#out, 4)
  eq(index.backend(), 'helper')
  eq(#notes, 0)
end

T['changed notification reaches on_change'] = function()
  need_helper()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. '/-p', 'p')
  local file = tmp .. '/-p/abc.jsonl'
  vim.fn.writefile({ '{"type":"user","cwd":"/x","message":{"role":"user","content":"hi"}}' }, file)
  local hit = false
  index.on_change(function() hit = true end, tmp)
  local ok = wait(function()
    local f = io.open(file, 'a'); f:write('{"type":"ai-title","aiTitle":"t"}\n'); f:close()
    return hit
  end, 4000)
  index.on_change(nil)
  eq(ok, true)
  vim.fn.delete(tmp, 'rf')
end

T['lua backend runs the change timer only while visible'] = function()
  config.setup({ helper = { enabled = false } })
  index._tick_ms = 30
  local n = 0
  index.on_change(function() n = n + 1 end)
  vim.wait(150, function() return false end)
  eq(n, 0)
  index.set_visible(true)
  wait(function() return n >= 2 end, 1000)
  eq(n >= 2, true)
  index.set_visible(false)
  local seen = n
  vim.wait(150, function() return false end)
  eq(n, seen)
  index.on_change(nil)
end

return T
