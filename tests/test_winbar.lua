-- The chat transcript's winbar: state mark and word in the drawer's colours, project, title cut
-- to fit, model and permission mode on the right. Synthetic sessions only, no Claude process.
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local ICONS = { waiting = 'W', busy = 'B', idle = 'I', parked = 'P', done = 'D', failed = 'F' }

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    child.restart({ '-u', 'tests/minimal_init.lua' })
    child.lua([[
      vim.env.TMUX = nil
      require('agent-ide').setup({ projects_dir = vim.fn.tempname(), helper = { enabled = false },
        live = { interval_ms = 600000, cmd = { 'echo', '[]' } }, icons_style = 'plain', icons = ...,
        claude = { cmd = { 'false' } } })
      _G.mk = function(o)
        _G.n = (_G.n or 0) + 1
        local s = require('agent-ide.session').open({ id = o.id or ('s' .. _G.n), cwd = '/w/proj', title = o.title or 'Fix the parser' })
        for k, v in pairs(o) do if k ~= 'id' and k ~= 'title' then s[k] = v end end
        return s
      end
      _G.bar = function(o, width)
        return require('agent-ide.ui.chat')._winbar(_G.mk(o), { key = '/w/proj', name = o.project or 'proj', sessions = {} }, width or 80)
      end
    ]], { ICONS })
  end,
  post_once = function() child.stop() end,
} })

-- The winbar as plain text: groups dropped, `%=` as two spaces, `%%` as `%`.
local function plain(bar)
  return (bar:gsub('%%#[^#]*#', ''):gsub('%%%*', ''):gsub('%%=', '  '):gsub('%%%%', '%%'))
end

-- As on screen: the gap `%=` makes is one column when the parts fill the window.
local function screen(bar) return (plain(bar):gsub('  ', ' ', 1)) end

local function bar(o, width) return child.lua_get('_G.bar(...)', { o, width or 80 }) end

local function width(s) return vim.fn.strdisplaywidth(s) end

T['each state: the mark and word in the drawer\'s group, project bold, title, model italic, mode badge'] = function()
  local base = { model = 'claude-opus-4-5-20251101', mode = 'manual' }
  local cases = {
    { 'idle', {}, 'AgentIdeIdle', 'I idle' },
    { 'busy', {}, 'AgentIdeBusy', 'B busy' },
    { 'parked', {}, 'AgentIdeParked', 'P parked' },
    { 'waiting', { pending_permissions = { { tool_name = 'Bash' } } }, 'AgentIdeWaiting', 'W permission: Bash' },
    { 'waiting', { pending_permissions = { { tool_name = 'AskUserQuestion' } } }, 'AgentIdeWaiting', 'W question' },
    { 'waiting', { pending_permissions = { { tool_name = 'ExitPlanMode' } } }, 'AgentIdeWaiting', 'W plan to approve' },
    { 'done', {}, 'AgentIdeDone', 'D done, unread' },
    { 'failed', { events = { { kind = 'meta', label = 'error', text = 'rate limit reached\nmore' } } }, 'AgentIdeFailed',
      'F failed: rate limit reached' },
  }
  for _, c in ipairs(cases) do
    local o = vim.tbl_extend('force', base, c[2], { state = c[1] })
    local b = bar(o)
    local word = c[4]:sub(3)
    eq({ c[1], b }, { c[1], ('%%#%s#%s%%* %%#%s#%s%%* · %%#AgentIdeProject#proj%%* · Fix the parser%%=%%#AgentIdeModel#opus-4-5%%* %%#AgentIdeMode#[manual]%%*')
      :format(c[3], c[4]:sub(1, 1), c[3], word) })
    eq(plain(b), c[4] .. ' · proj · Fix the parser  opus-4-5 [manual]')
  end
end

T['the state groups are the drawer\'s, by name'] = function()
  local groups = child.lua_get('require("agent-ide.ui.tree").STATE_GROUP')
  for _, st in ipairs({ 'idle', 'busy', 'parked', 'done', 'failed', 'waiting' }) do
    local b = bar({ state = st })
    eq({ st, b:match('^%%#([^#]+)#') }, { st, groups[st] })
  end
end

T['a session running elsewhere: tmux pane or native, in the drawer\'s dim word'] = function()
  child.lua([[
    local live = require('agent-ide.live')
    live.get = function() return { sid = { status = 'busy', pid = 4242 } } end
    live.fresh = live.get
    require('agent-ide.tmux').pane_label = function(pid) return pid == 4242 and '2.1' or nil end
  ]])
  local b = bar({ id = 'sid', state = 'parked' })
  eq(b:match('^(.-) · '), '%#AgentIdeBusy#B%* %#AgentIdeAge#tmux 2.1%*')
  eq(plain(b), 'B tmux 2.1 · proj · Fix the parser')
  child.lua([[
    require('agent-ide.live').get = function() return {} end
    require('agent-ide.live').fresh = function() return {} end
    require('agent-ide.ui.handoff').away = function() return true end
  ]])
  eq(plain(bar({ state = 'idle' })), 'I native · proj · Fix the parser')
end

T['no model known: no model segment; the queue is counted'] = function()
  local b = bar({ state = 'busy', queue = { 'a', 'b' } })
  eq(b:find('AgentIdeModel', 1, true), nil)
  eq(b:find('AgentIdeMode', 1, true), nil)
  eq(plain(b), 'B busy · queued:2 · proj · Fix the parser')
  -- a model asked for before Claude reported one
  eq(plain(bar({ state = 'idle', model_requested = 'sonnet' })), 'I idle · proj · Fix the parser  model ?→sonnet')
end

T['mode badge: the default mode quiet, any other one hot'] = function()
  local cases = { manual = 'AgentIdeMode', acceptEdits = 'AgentIdeModeHot', plan = 'AgentIdeModeHot',
    auto = 'AgentIdeModeHot', bypassPermissions = 'AgentIdeModeHot' }
  for m, group in pairs(cases) do
    local b = bar({ state = 'idle', model = 'claude-haiku-5-5-20261001', mode = m })
    eq({ m, b:match('%%#(AgentIdeMode%a*)#%[') }, { m, group })
    eq({ m, plain(b):match('%[(.-)%]$') }, { m, m })
  end
  -- a change waiting for Claude: shown as old→new, hot when either is
  local b = bar({ state = 'idle', mode = 'manual', mode_requested = 'plan' })
  eq(b:match('%%#(AgentIdeMode%a*)#%[manual→plan%]'), 'AgentIdeModeHot')
  -- a configured default mode is quiet too
  child.lua('require("agent-ide.config").get().claude.default_mode = "acceptEdits"')
  eq(bar({ state = 'idle', mode = 'acceptEdits' }):match('%%#(AgentIdeMode%a*)#%['), 'AgentIdeMode')
end

T['narrow window (40 columns): a multi-byte title is cut with …, the right part stays'] = function()
  local o = { state = 'idle', model = 'claude-opus-4-5-20251101', mode = 'plan',
    title = 'Größenänderung der Brückenpfeiler – 日本語のタイトル' }
  local p = plain(bar(o, 40))
  eq(p, 'I idle · proj · Größenä…  opus-4-5 [plan]')
  eq(width(p), 40 + 1) -- `%=` counts as two spaces here: on screen the gap is one column
  for w = 30, 50 do
    local q = screen(bar(o, w))
    eq({ w, width(q) <= w }, { w, true })
  end
  -- every width from 80 down: never wider than the window, the state always there; the
  -- title goes first, then the model, the badge, and last the state word is cut; the project
  -- gets what remains
  local long = vim.tbl_extend('force', o, { state = 'waiting', pending_permissions = { { tool_name = 'Bash' } },
    mode = 'acceptEdits' })
  for w = 80, 12, -1 do
    local q = screen(bar(long, w))
    eq({ w, width(q) <= w }, { w, true })
    eq({ w, vim.startswith(q, 'W permissio') }, { w, true })
  end
  eq(plain(bar(long, 40)), 'W permission: Bash · proj  [acceptEdits]')
  -- wide enough: the whole title
  eq(plain(bar(o, 120)):find('日本語のタイトル', 1, true) ~= nil, true)
end

T['a % in the title, project or model is escaped'] = function()
  local b = bar({ state = 'idle', title = '100% done', project = 'p%q', model = 'claude-x%y' })
  eq(b:find('100%% done', 1, true) ~= nil, true)
  eq(b:find('p%%q', 1, true) ~= nil, true)
  eq(b:find('x%%y', 1, true) ~= nil, true)
  eq(plain(b), 'I idle · p%q · 100% done  x%y')
  -- the statusline evaluator accepts it and shows the text
  local shown = child.lua_get('vim.api.nvim_eval_statusline(..., { winid = 0, use_winbar = true, maxwidth = 80 }).str', { b })
  eq(shown:find('100% done', 1, true) ~= nil, true)
end

T['highlight groups: model italic from Normal, mode badges, all default'] = function()
  child.lua('require("agent-ide.ui.highlights").setup()')
  local model = child.lua_get('vim.api.nvim_get_hl(0, { name = "AgentIdeModel" })')
  eq(model.italic, true)
  eq(model.default, true)
  eq(model.fg, child.lua_get('vim.api.nvim_get_hl(0, { name = "Normal", link = false }).fg'))
  eq(child.lua_get('vim.api.nvim_get_hl(0, { name = "AgentIdeModeHot" }).link'), 'WarningMsg')
  eq(child.lua_get('vim.api.nvim_get_hl(0, { name = "AgentIdeModeHot" }).default'), true)
  eq(child.lua_get('next(vim.api.nvim_get_hl(0, { name = "AgentIdeMode" })) ~= nil'), true)
end

T['the winbar follows the window width on resize and never moves focus'] = function()
  child.lua([[
    _G.s = _G.mk({ state = 'idle', model = 'claude-opus-4-5-20251101', mode = 'plan',
      title = 'A session title shown in full' })
    require('agent-ide.ui.chat').open(_G.s, { key = '/w/proj', name = 'proj', sessions = {} })
    _G.twin = require('agent-ide.ui.chat')._windows().transcript
    -- a window beside it, so it can be made narrower
    vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, { split = 'left', win = _G.twin })
    vim.api.nvim_win_set_width(_G.twin, 70)
  ]])
  local focus = child.lua_get('vim.api.nvim_get_current_win()')
  local function shown() return screen(child.lua_get('vim.wo[_G.twin].winbar')) end
  local function w() return child.lua_get('vim.api.nvim_win_get_width(_G.twin)') end
  eq(width(shown()) <= w(), true)
  eq(shown():find('shown in full', 1, true) ~= nil, true)
  child.lua('vim.api.nvim_win_set_width(_G.twin, 42)')
  child.lua('vim.cmd("redraw")')
  vim.wait(200, function() return width(shown()) <= w() end, 10)
  eq(w(), 42)
  eq(width(shown()) <= 42, true)
  eq(vim.endswith(shown(), 'opus-4-5 [plan]'), true)
  eq(shown():find('…', 1, true) ~= nil, true)
  eq(child.lua_get('vim.api.nvim_get_current_win()'), focus)
end

return T
