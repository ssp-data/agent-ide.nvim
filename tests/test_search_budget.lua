-- Speed budgets of the search, with the helper, on synthetic data: 200 sessions of about
-- 250 KB (50 MB). Index build under 3 s, a query under 30 ms in the helper, keystroke to
-- results under 60 ms end to end in the picker, and the UI never blocked while typing.
local S = dofile(vim.fn.getcwd() .. '/tests/search_synth.lua')
local child = MiniTest.new_child_neovim()

local real_helper = vim.fn.getcwd() .. '/helper/target/release/agent-ide-helper'
local root, projects, wrapper

local T = MiniTest.new_set({ hooks = {
  pre_once = function()
    if not vim.uv.fs_stat(real_helper) then return end
    root = vim.fn.tempname()
    projects = S.generate(root, 200, 250 * 1024)
    wrapper = root .. '/helper.sh'
    vim.fn.writefile({ '#!/bin/sh', ('exec %q --cache-dir %q'):format(real_helper, root .. '/cache') }, wrapper)
    vim.uv.fs_chmod(wrapper, tonumber('755', 8))
  end,
  pre_case = function()
    if not root then MiniTest.skip('helper not built (make helper)') end
    vim.fn.delete(root .. '/cache', 'rf') -- every case starts cold
    child.restart({ '-u', 'tests/minimal_init.lua' })
    child.lua([[
      require('agent-ide').setup({ projects_dir = ..., helper = { enabled = true, path = select(2, ...) },
        live = { interval_ms = 600000, cmd = { 'echo', '[]' } }, keys = false })
      require('agent-ide.index.helper')._timeout_ms = 60000
    ]], { projects, wrapper })
  end,
  post_case = function() child.stop() end,
  post_once = function()
    child.stop()
    if root then vim.fn.delete(root, 'rf') end
  end,
} })

local function check(name, value, budget)
  if vim.env.SEARCH_BUDGET_PRINT then print(('%s: %.1f ms (budget %d)'):format(name, value, budget)) end
  if value >= budget then error(('%s: %.1f ms, budget < %d ms'):format(name, value, budget), 0) end
end

-- One `search` request in the child; returns the result and the round trip in ms.
local function request(params)
  return child.lua([[
    local params = ...
    local out, t0 = nil, vim.uv.hrtime()
    require('agent-ide.index.search').search(params, function(r) out = r end)
    vim.wait(60000, function() return out ~= nil end, 1)
    return { result = { sessions = out.sessions, chunks = out.chunks, took_ms = out.took_ms, hits = #out.hits,
      backend = out.backend, indexing = out.indexing }, ms = (vim.uv.hrtime() - t0) / 1e6 }
  ]], { params })
end

T['index build of 200 sessions (50 MB) under 3 s, queries under 30 ms in the helper'] = function()
  local cold = request({ query = '', wait = true })
  MiniTest.expect.equality({ cold.result.backend, cold.result.sessions, cold.result.indexing }, { 'helper', 200, false })
  check('index build', cold.ms, 3000)
  for _, q in ipairs({ 'parser17', 'explaining detail', 'übersetzung', 'prsr', 'zzzzzz', 'topic3 answer', 'a' }) do
    local r = request({ query = q, kinds = { 'title', 'prompt', 'answer', 'tool' } })
    check('query ' .. q, r.result.took_ms, 30)
  end
end

T['picker: keystroke to results under 60 ms with the helper, UI never blocked'] = function()
  request({ query = '', wait = true }) -- built once, as after the first use
  child.lua([[
    require('agent-ide').search()
    vim.wait(5000, function() local s = require('agent-ide.ui.search')._state(); return s and s.backend ~= nil end, 1)
    vim.wait(100)
    _G.gap = { worst = 0, last = vim.uv.hrtime(), timer = vim.uv.new_timer() }
    _G.gap.timer:start(1, 1, function()
      local now = vim.uv.hrtime()
      _G.gap.worst = math.max(_G.gap.worst, now - _G.gap.last)
      _G.gap.last = now
    end)
  ]])
  local times, typed = {}, ''
  for _, key in ipairs({ 'p', 'a', 'r', 's', 'e', 'r', '1', ' ', 'ü', 'b' }) do
    typed = typed .. key
    child.type_keys(key)
    local ok = vim.wait(5000, function()
      local st = child.lua_get('require("agent-ide.ui.search")._state().stats')
      return st ~= vim.NIL and st.query == typed
    end, 2)
    if not ok then error('no results for ' .. typed, 0) end
    times[#times + 1] = child.lua_get('require("agent-ide.ui.search")._state().stats.ms')
    vim.wait(40) -- the preview renders too
  end
  local r = { times = times, block = child.lua_get('(function() _G.gap.timer:stop(); return _G.gap.worst / 1e6 end)()') }
  for i, ms in ipairs(r.times) do check('keystroke ' .. i .. ' to results', ms, 60) end
  check('longest UI block while typing', r.block, 16)
end

return T
