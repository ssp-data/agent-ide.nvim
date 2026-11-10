-- Search backends: the Lua fallback, the helper, and their parity. Synthetic data only; the
-- helper runs through a wrapper with its own cache directory, never the user's.
local config = require('agent-ide.config')
local index = require('agent-ide.index')
local helper = require('agent-ide.index.helper')
local lua_scan = require('agent-ide.index.lua_scan')
local search = require('agent-ide.index.search')
local S = dofile(vim.fn.getcwd() .. '/tests/search_synth.lua')
local eq = MiniTest.expect.equality

local fixtures = vim.fn.fnamemodify('tests/fixtures/projects', ':p'):gsub('/$', '')
local real_helper = vim.fn.getcwd() .. '/helper/target/release/agent-ide-helper'
local tmp

local function wrapper()
  local p = tmp .. '/helper.sh'
  vim.fn.writefile({ '#!/bin/sh', ('exec %q --cache-dir %q'):format(real_helper, tmp .. '/cache') }, p)
  vim.uv.fs_chmod(p, tonumber('755', 8))
  return p
end

local function use(backend)
  config.setup({ helper = { enabled = backend == 'helper', path = backend == 'helper' and wrapper() or nil } })
  helper._reset(); index._reset(); search._reset()
end

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    use('lua')
  end,
  post_case = function()
    helper._reset(); index._reset(); search._reset()
    config.setup({})
    vim.fn.delete(tmp, 'rf')
  end,
} })

local function need_helper()
  if not vim.uv.fs_stat(real_helper) then MiniTest.skip('helper not built') end
end

-- Search until the index is complete (the Lua search indexes in the background).
local function run(params, ms)
  local deadline = vim.uv.now() + (ms or 10000)
  while true do
    local out
    search.search(vim.tbl_extend('force', { limit = 500 }, params), function(r) out = r end)
    vim.wait(ms or 10000, function() return out ~= nil end, 5)
    assert(out, 'no search result')
    if not out.indexing or vim.uv.now() > deadline then return out end
    vim.wait(20)
  end
end

local function history(path)
  local out
  lua_scan.history(path, function(e) out = e end)
  vim.wait(5000, function() return out ~= nil end, 5)
  return out
end

local function sessions_of(hits, kinds)
  local set = {}
  for _, h in ipairs(hits) do
    if kinds[h.kind] and h.match ~= 'fuzzy' then set[h.session] = true end
  end
  local out = vim.tbl_keys(set)
  table.sort(out)
  return out
end

T['lua fallback finds titles and prompts with the helper hit shape'] = function()
  local r = run({ projects_dir = fixtures, query = 'greeting' })
  eq(r.backend, 'lua')
  eq(r.limited, true)
  eq(#r.hits, 1)
  local h = r.hits[1]
  eq(h.kind, 'prompt')
  eq(h.session, '11111111-1111-4111-8111-111111111111')
  eq(h.title, 'Alpha basics')
  eq(h.project, 'alpha')
  eq(h.match, 'prefix')
  eq(h.snippet, 'Please add a greeting to main.')
  eq(h.positions, { { 13, 21 } })
  local ev = history(h.path)[h.event]
  eq({ ev.kind, ev.text }, { 'prompt', 'Please add a greeting to main.' })
  local t = run({ projects_dir = fixtures, query = 'meeting summary' })
  eq(t.hits[1].kind, 'title')
  eq(t.hits[1].event, nil)
end

T['lua fallback: answers are not searched, empty prompt query lists prompts newest first'] = function()
  local root = tmp .. '/p'
  S.write(root, '-w-a', 'a', { S.user('old one', 1), S.answer('answer word', 2), S.user('newest one', 30) })
  S.write(root, '-w-b', 'b', { S.user('middle one', 10) })
  eq(#run({ projects_dir = root, query = 'answer', kinds = { 'answer' } }).hits, 0)
  local r = run({ projects_dir = root, query = '  ', kinds = { 'prompt' } })
  eq(vim.tbl_map(function(h) return h.snippet end, r.hits), { 'newest one', 'middle one', 'old one' })
  eq(r.hits[1].match, 'recent')
end

T['lua fallback indexes in slices without blocking the UI'] = function()
  local root = tmp .. '/big'
  local blob = string.rep('synthetic output line\n', 2000)
  for i = 1, 6 do
    local lines = {}
    for n = 1, 60 do
      lines[#lines + 1] = S.user('prompt ' .. n .. ' in ' .. i, n)
      lines[#lines + 1] = S.result('t', blob)
    end
    S.write(root, '-w-' .. i, 's' .. i, lines)
  end
  local worst, last = 0, vim.uv.hrtime()
  local timer = vim.uv.new_timer()
  timer:start(1, 1, function()
    local now = vim.uv.hrtime()
    worst = math.max(worst, now - last)
    last = now
  end)
  local r = run({ projects_dir = root, query = 'prompt 7 in 3', kinds = { 'prompt' } }, 60000)
  timer:stop(); timer:close()
  eq(r.indexing, false)
  eq(#r.hits >= 1, true)
  if worst / 1e6 >= 50 then error(('UI blocked for %.1f ms'):format(worst / 1e6), 0) end
end

T['lua context returns the turn of an event'] = function()
  local p = fixtures .. '/-home-u-git-alpha/11111111-1111-4111-8111-111111111111.jsonl'
  local all = history(p)
  local first, events
  search.context(p, 3, function(f, e) first, events = f, e end)
  vim.wait(5000, function() return first ~= nil end, 5)
  eq(first, 1)
  eq(events[1].kind, 'prompt')
  eq(#events < #all, true)
  local none
  search.context(p, 9999, function(f) none = f or false end)
  vim.wait(5000, function() return none ~= nil end, 5)
  eq(none, false)
end

local PARITY_QUERIES = { 'a', 'the', 'notes', 'alpha', 'greeting main', 'docs', 'über', 'Über', 'brücke', 'GRÜN',
  'prompt 3', 'compact', 'x', 'parser1', 'topic2 übersetzung', '%s', '(', 'zzz' }

T['helper and lua return the same sessions for exact queries on titles and prompts'] = function()
  need_helper()
  local root = tmp .. '/parity'
  vim.fn.system({ 'cp', '-r', fixtures .. '/.', root })
  S.write(root, '-w-u', 'u1', { S.title('Über die Brücke'), S.user('grün und blau', 1), S.user('Grün again', 2) })
  S.write(root, '-w-u', 'u2', { S.user(string.rep('ä', 3000) .. ' brücke at the cap', 3) })
  for i = 1, 4 do
    S.write(root, '-w-g', 'g' .. i, S.session('/w/g', 5, ('topic%d Übersetzung parser%d'):format(i, i), 50, i))
  end
  local projects = { ['/w/u'] = 'umlaut-repo' }
  for _, kinds in ipairs({ { 'title', 'prompt' }, { 'prompt' }, { 'title' } }) do
    local set = {}
    for _, k in ipairs(kinds) do set[k] = true end
    for _, q in ipairs(PARITY_QUERIES) do
      local params = { projects_dir = root, query = q, kinds = kinds, fuzzy = false, projects = projects }
      use('lua')
      local l = sessions_of(run(params).hits, set)
      use('helper')
      local hr = run(params)
      eq(hr.backend, 'helper')
      local h = sessions_of(hr.hits, set)
      -- u2 has its match beyond the 4 KiB cap in both backends
      if q == 'über' and set.prompt and set.title then eq(l, { 'g1', 'g2', 'g3', 'g4', 'u1' }) end
      if q == 'parser1' and set.prompt then eq(l, { 'g1' }) end
      if not vim.deep_equal(l, h) then
        error(('query %q kinds %s: lua %s helper %s'):format(q, table.concat(kinds, ','), vim.inspect(l), vim.inspect(h)), 0)
      end
    end
  end
end

T['helper hits point at the events lua history returns, and context agrees'] = function()
  need_helper()
  use('helper')
  local root = tmp .. '/ev'
  local path = S.write(root, '-w-e', 'e', S.session('/w/e', 6, 'eventword', 30, 0))
  local r = run({ projects_dir = root, query = 'eventword', kinds = { 'prompt', 'answer', 'tool' } })
  eq(#r.hits, 12)
  local all = history(path)
  for _, h in ipairs(r.hits) do
    local ev = all[h.event]
    eq(ev.kind, h.kind == 'prompt' and 'prompt' or 'text')
    eq(ev.text:find('eventword', 1, true) ~= nil, true)
    local first, events
    search.context(path, h.event, function(f, e) first, events = f, e end)
    vim.wait(5000, function() return first ~= nil end, 5)
    eq(events[h.event - first + 1], ev)
  end
end

return T
