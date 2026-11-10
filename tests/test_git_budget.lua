-- Speed budgets of the git sections (synthetic data, best of 5): drawer re-render with 30 git
-- projects under 5 ms, and 300 changed files on screen within 150 ms of the data arriving.
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()
local RUNS = 5

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    child.restart({ '-u', 'tests/minimal_init.lua' })
    child.lua([[
      require('agent-ide').setup({ projects_dir = vim.fn.tempname(), helper = { enabled = false },
        live = { interval_ms = 100000, cmd = { 'true' } },
        prompts = { command_dirs = {}, skill_dirs = {}, library_dir = vim.fn.tempname(), saved_dir = vim.fn.tempname() } })
      local cache = require('agent-ide.git_cache')
      local projects = {}
      _G.projects = projects -- a case may add more
      -- every scan groups into these projects
      require('agent-ide.project').group = function() return projects end
      for i = 1, 30 do
        local root = '/synthetic/repo' .. i
        local sessions = {}
        for k = 1, 5 do sessions[k] = { id = i .. '-' .. k, title = 'Session ' .. k, activity = 1000 } end
        projects[i] = { key = root, root = root, name = 'repo' .. i, is_git = true, missing = false, activity = 1000,
          sessions = sessions }
        local b = { branch = 'feat' .. i, detached = false, head = 'h', default_name = 'main', default_ref = 'main',
          ref = 'main', on_default = false, merge_base = 'm', mode = 'branch', rev = 'm', label = 'main' }
        cache._set(root, 'head', b)
        cache._set(root, 'base', b)
        cache._set(root, 'changes', { { status = 'M', path = 'a.lua', added = 1, removed = 1 } })
        cache._set(root, 'commits', { { hash = 'c', short = 'c', subject = 's', date = 0, files = 1 } })
      end
      require('agent-ide').toggle()
      assert(vim.wait(3000, function() return #require('agent-ide.ui.drawer').state().nodes == 32 end, 10))
      _G.best = function(fn)
        local best = math.huge
        for _ = 1, ]] .. RUNS .. [[ do
          local t0 = vim.uv.hrtime()
          fn()
          best = math.min(best, (vim.uv.hrtime() - t0) / 1e6)
        end
        return best
      end
    ]])
  end,
  post_case = function() child.stop() end,
  post_once = function() child.stop() end,
} })

local function check(name, value, budget)
  if value >= budget then error(string.format('%s: %.2f ms, budget < %d ms', name, value, budget), 0) end
  MiniTest.add_note(string.format('%s: %.2f ms (budget %d ms)', name, value, budget))
end

T['re-render with 30 collapsed git projects under 5 ms'] = function()
  local ms = child.lua_get('_G.best(require("agent-ide.ui.drawer").refresh)')
  local n = child.lua_get('#vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)')
  eq(n, 32) -- the header, the Prompts node and 30 projects
  check('re-render, 30 collapsed projects', ms, 5)
end

T['re-render with 30 expanded git projects, sections collapsed, under 5 ms'] = function()
  child.lua([[
    local s = require('agent-ide.ui.drawer').state()
    for _, p in ipairs(s.projects) do
      vim.api.nvim_set_current_win(s.win)
      for i, node in ipairs(require('agent-ide.ui.drawer').state().nodes) do
        if node.type == 'project' and node.project == p then vim.api.nvim_win_set_cursor(s.win, { i, 0 }); break end
      end
      vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
    end
  ]])
  local n = child.lua_get('#vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)')
  eq(n, 2 + 30 * (1 + 1 + 1 + 5 + 2))
  check('re-render, 30 expanded projects', child.lua_get('_G.best(require("agent-ide.ui.drawer").refresh)'), 5)
end

T['re-render with 60 projects and 300 visible aligned rows (multi-byte titles) under 5 ms'] = function()
  child.lua([[
    local cache = require('agent-ide.git_cache')
    for i = 31, 60 do
      local root = '/synthetic/repo' .. i
      local sessions = {}
      for k = 1, 4 do
        sessions[k] = { id = i .. '-' .. k, activity = 1000 - k * 4000,
          title = ({ 'Übersetzung prüfen für Bäume', '日本語のタイトル', 'Party 🎉 time with a rather long title', 'plain' })[k] }
      end
      _G.projects[i] = { key = root, root = root, name = 'repo' .. i, is_git = true, missing = false, activity = 900,
        sessions = sessions }
      local b = { branch = 'feat' .. i, detached = false, head = 'h', default_name = 'main', default_ref = 'main',
        ref = 'main', on_default = false, merge_base = 'm', mode = 'branch', rev = 'm', label = 'main' }
      cache._set(root, 'head', b)
      cache._set(root, 'base', b)
      cache._set(root, 'changes', {})
      cache._set(root, 'commits', {})
    end
    local d = require('agent-ide.ui.drawer')
    d.refresh()
    local s = d.state()
    vim.api.nvim_set_current_win(s.win)
    for i = 31, 60 do -- expand the 30 new projects
      for row, node in ipairs(d.state().nodes) do
        if node.type == 'project' and node.project == _G.projects[i] then vim.api.nvim_win_set_cursor(s.win, { row, 0 }); break end
      end
      vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
    end
  ]])
  local lines = child.lua_get('vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)')
  eq(#lines, 2 + 60 + 30 * (1 + 1 + 4 + 2))
  for _, l in ipairs(lines) do
    if l:find('Übersetzung', 1, true) or l:find('日本語', 1, true) or l:find('🎉', 1, true) then eq(vim.fn.strdisplaywidth(l), 44) end
  end
  check('re-render, 60 projects, 302 rows', child.lua_get('_G.best(require("agent-ide.ui.drawer").refresh)'), 5)
end

T['300 changed files on screen within 150 ms of the data arriving'] = function()
  local ms = child.lua_get([[(function()
    local cache = require('agent-ide.git_cache')
    local drawer = require('agent-ide.ui.drawer')
    local s = drawer.state()
    local root = s.projects[1].root
    local files = {}
    for i = 1, 300 do files[i] = { status = 'M', path = ('dir/file%03d.lua'):format(i), added = i, removed = 1 } end
    -- expand the project and its Changes section while the data is still unknown
    s.projects[1].root = root
    vim.api.nvim_set_current_win(s.win)
    vim.api.nvim_win_set_cursor(s.win, { 3, 0 }) -- line 1: the header, 2: the Prompts node
    vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
    for i, node in ipairs(drawer.state().nodes) do
      if node.id == root .. '#changes' then vim.api.nvim_win_set_cursor(s.win, { i, 0 }) end
    end
    vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
    return _G.best(function()
      cache._set(root, 'changes', files) -- what a git callback stores
      drawer.refresh() -- what the cache listener does
      local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
      assert(table.concat(lines, '\n'):find('dir/file300.lua', 1, true))
    end)
  end)()]])
  check('300 files on screen', ms, 150)
end

return T
