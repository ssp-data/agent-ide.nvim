local status = require('agent-ide.status')
local session = require('agent-ide.session')
local eq = MiniTest.expect.equality

local NOW = 1000000
local notes, dir, orig_notify, env_xdg

local function sess(id, state, extra)
  return vim.tbl_extend('force', { id = id, state = state, cwd = '/home/u/git/' .. id, title = 'T ' .. id,
    pending_permissions = {}, owned = true }, extra or {})
end

local function use(sessions, live_map, current)
  status._src.sessions = function() return sessions end
  status._src.live = function() return live_map or {} end
  status._src.current = function() return current end
  status._src.now = function() return NOW end
end

local function set_quota(w) status._reset(); session._set_quota(w); status.refresh() end

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    status._reset()
    session._reset()
    notes = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    env_xdg = vim.uv.os_getenv('XDG_RUNTIME_DIR')
    vim.uv.os_setenv('XDG_RUNTIME_DIR', dir .. '/run')
    use({}, {})
  end,
  post_case = function()
    status._reset() -- cancel timers
    vim.wait(80, function() return false end, 10) -- let in-flight async writes finish before the dir goes
    vim.notify = orig_notify
    if env_xdg then vim.uv.os_setenv('XDG_RUNTIME_DIR', env_xdg) else vim.uv.os_unsetenv('XDG_RUNTIME_DIR') end
    status._reset()
    session._reset()
    vim.fn.delete(dir, 'rf')
  end,
} })

T['level combinations'] = function()
  local function lv(ss, lm) local l = status.level(ss, lm); return { l.level, l.name, l.waiting, l.review, l.busy } end
  eq(lv({}, {}), { 1, 'ok', 0, 0, 0 })
  eq(lv({ sess('a', 'idle'), sess('p', 'parked') }, {}), { 1, 'ok', 0, 0, 0 })
  eq(lv({ sess('a', 'busy') }, {}), { 2, 'running', 0, 0, 1 })
  eq(lv({ sess('a', 'busy'), sess('b', 'done') }, {}), { 3, 'review', 0, 1, 1 })
  eq(lv({ sess('a', 'failed'), sess('b', 'done') }, {}), { 3, 'review', 0, 2, 0 })
  eq(lv({ sess('a', 'busy'), sess('b', 'done'), sess('c', 'waiting'), sess('d', 'waiting') }, {}), { 4, 'input', 2, 1, 1 })
end

T['live map: other sessions count, owned ones are ignored'] = function()
  local ss = { sess('mine', 'idle'), sess('parked1', 'parked', { owned = false }) }
  local lm = {
    mine = { status = 'waiting' }, -- owned here: ignored
    parked1 = { status = 'busy' }, -- registry entry not owned: counts
    other = { status = 'waiting' },
    other2 = { status = 'busy' },
    other3 = { status = 'idle' },
  }
  local l = status.level(ss, lm)
  eq({ l.level, l.waiting, l.busy, l.review }, { 4, 1, 2, 0 })
end

T['statusline text per level'] = function()
  use({})
  eq(status.statusline(), 'agents ok')
  eq(status.statusline_hl(), 'AgentIdeLevel1')
  use({ sess('a', 'busy'), sess('b', 'busy') })
  eq(status.statusline(), 'agents running (2)')
  eq(status.statusline_hl(), 'AgentIdeLevel2')
  use({ sess('a', 'done') })
  eq(status.statusline(), 'review (1)')
  eq(status.statusline_hl(), 'AgentIdeLevel3')
  use({ sess('a', 'waiting'), sess('b', 'waiting') })
  eq(status.statusline(), 'input required (2)')
  eq(status.statusline_hl(), 'AgentIdeLevel4')
end

T['model of the focused session, claude- prefix removed'] = function()
  use({}, {}, { model = 'claude-haiku-5-5' })
  eq(status.statusline(), 'agents ok · haiku-5-5')
  use({}, {}, { model = nil })
  eq(status.statusline(), 'agents ok')
end

T['quota text, bars and percentages'] = function()
  use({})
  set_quota({ five_hour = { utilization = 0.07, resets_at = NOW + 100 }, seven_day = { utilization = 0.18, resets_at = NOW + 100 } })
  eq(status.statusline(), 'agents ok · 5h ▰▰▰▰▰ 93%% · week ▰▰▰▰▱ 82%%')
end

T['quota: extra windows, clamping'] = function()
  use({})
  set_quota({ zeta = { utilization = 1.5 }, five_hour = { utilization = 0 }, extra = { utilization = 0.5 } })
  eq(status.statusline(), 'agents ok · 5h ▰▰▰▰▰ 100%% · extra ▰▰▰▱▱ 50%% · zeta ▱▱▱▱▱ 0%%')
end

T['quota stale: past reset or older than 6 h'] = function()
  use({})
  set_quota({ five_hour = { utilization = 0.07, resets_at = NOW - 1 }, seven_day = { utilization = 0.18, resets_at = NOW + 100 } })
  eq(status.statusline(), 'agents ok · 5h ? · week ▰▰▰▰▱ 82%%')
  set_quota({ five_hour = { utilization = 0.07 } })
  status._src.now = function() return NOW + 6 * 3600 + 1 end
  eq(status.statusline(), 'agents ok · 5h ?')
end

T['statusline never raises without setup or with broken sources'] = function()
  status._src.sessions = function() error('boom') end
  eq(type(status.statusline()), 'string')
  eq(status.statusline_hl(), 'AgentIdeLevel1')
end

T['quota survives a restart'] = function()
  use({})
  local state = dir .. '/state'
  local orig = vim.fn.stdpath
  vim.fn.stdpath = function(w) if w == 'state' then return state end return orig(w) end
  set_quota({ five_hour = { utilization = 0.07, resets_at = NOW + 100 } })
  status._flush_quota()
  local file = state .. '/agent-ide/quota.json'
  MiniTest.expect.equality(vim.wait(2000, function() return vim.uv.fs_stat(file) ~= nil end, 10), true)
  local obj = vim.json.decode(table.concat(vim.fn.readfile(file), '\n'))
  eq(obj.updated, NOW)
  eq(obj.windows.five_hour, { utilization = 0.07, resets_at = NOW + 100 })
  status._reset()
  session._reset()
  local loaded
  status.load_quota(function(ok) loaded = ok end)
  vim.wait(2000, function() return loaded ~= nil end, 10)
  vim.fn.stdpath = orig
  eq(loaded, true)
  eq(status.statusline(), 'agents ok · 5h ▰▰▰▰▰ 93%%')
end

T['corrupt quota file is ignored'] = function()
  local state = dir .. '/state'
  vim.fn.mkdir(state .. '/agent-ide', 'p')
  vim.fn.writefile({ '{not json' }, state .. '/agent-ide/quota.json')
  local orig = vim.fn.stdpath
  vim.fn.stdpath = function(w) if w == 'state' then return state end return orig(w) end
  local loaded
  status.load_quota(function(ok) loaded = ok end)
  vim.wait(2000, function() return loaded ~= nil end, 10)
  vim.fn.stdpath = orig
  eq(loaded, false)
  eq(status.statusline(), 'agents ok')
end

local function read_json(path) return vim.json.decode(table.concat(vim.fn.readfile(path), '\n')) end
local function wait_file(path) return vim.wait(2000, function() return vim.uv.fs_stat(path) ~= nil end, 10) end

T['status file content for two sessions'] = function()
  local a = sess('a', 'waiting', { pending_permissions = { { request_id = 'r1', tool_name = 'Bash' }, { request_id = 'r2', tool_name = 'Edit' } } })
  local b = sess('b', 'busy')
  local p = sess('p', 'parked', { owned = false })
  use({ a, b, p }, { other = { status = 'busy' } })
  status.refresh()
  eq(wait_file(status.file()), true)
  vim.wait(2000, function() return vim.uv.fs_stat(status.latest_file()) ~= nil end, 10)
  local obj = read_json(status.file())
  eq(obj, {
    version = 1, pid = vim.fn.getpid(), updated = NOW, level = 4, name = 'input', waiting = 1, review = 0, busy = 2,
    sessions = {
      { id = 'a', project = 'a', title = 'T a', state = 'waiting', reason = 'Bash' },
      { id = 'b', project = 'b', title = 'T b', state = 'busy', reason = '' },
    },
  })
  eq(read_json(status.latest_file()), obj)
  eq(status.file(), dir .. '/run/agent-ide/status-' .. vim.fn.getpid() .. '.json')
  eq(vim.uv.fs_stat(dir .. '/run/agent-ide').mode % 512, tonumber('700', 8))
end

T['empty session list is a JSON array'] = function()
  use({})
  status.refresh()
  wait_file(status.file())
  local raw = table.concat(vim.fn.readfile(status.file()), '\n')
  eq(raw:find('"sessions":[]', 1, true) ~= nil, true)
end

T['files removed on leave, latest only if ours'] = function()
  use({ sess('a', 'busy') })
  status.refresh()
  vim.wait(2000, function() return vim.uv.fs_stat(status.latest_file()) ~= nil end, 10)
  vim.wait(100)
  status._cleanup()
  eq(vim.uv.fs_stat(status.file()), nil)
  eq(vim.uv.fs_stat(status.latest_file()), nil)
  -- another instance wrote last: status.json stays
  vim.fn.writefile({ vim.json.encode({ pid = 1 }) }, status.latest_file())
  status._cleanup()
  eq(vim.uv.fs_stat(status.latest_file()) ~= nil, true)
end

T['50 rapid changes: at most one write per 200 ms, final state written'] = function()
  local ss = { sess('a', 'idle') }
  use(ss)
  status.refresh()
  local t0 = vim.uv.hrtime()
  for i = 1, 50 do
    ss[1].title = 'title ' .. i
    status.refresh()
  end
  eq(status._writes(), 1)
  vim.wait(600, function() return false end, 20)
  eq(status._writes(), 2)
  eq(vim.wait(1000, function()
    local ok, o = pcall(read_json, status.file())
    return ok and o.sessions[1].title == 'title 50'
  end, 10), true)
  eq((vim.uv.hrtime() - t0) / 1e6 < 5000, true)
end

T['unwritable runtime dir: one warning, no error'] = function()
  vim.fn.writefile({ 'x' }, dir .. '/blocker')
  vim.uv.os_setenv('XDG_RUNTIME_DIR', dir .. '/blocker')
  local ss = { sess('a', 'idle') }
  use(ss)
  local ok = pcall(function()
    status.refresh()
    for i = 1, 5 do
      ss[1].title = 'x' .. i
      status.refresh()
      vim.wait(250, function() return false end, 20)
    end
  end)
  eq(ok, true)
  local warns = vim.tbl_filter(function(n) return n.level == vim.log.levels.WARN end, notes)
  eq(#warns, 1)
end

T['setup twice subscribes once'] = function()
  use({})
  status.setup()
  status.setup()
  vim.wait(300, function() return false end, 20)
  local before = status._writes()
  use({ sess('a', 'busy') })
  session._emit({}, 'state') -- stand-in notification
  vim.wait(500, function() return false end, 20)
  eq(status._writes() - before <= 2, true)
  eq(status.level().level, 2)
end

T['highlight groups and lualine component'] = function()
  require('agent-ide.ui.highlights').setup()
  local want = { '#9ece6a', '#e0af68', '#ff9e64', '#a277ff' }
  for i, hex in ipairs(want) do
    eq(('#%06x'):format(vim.api.nvim_get_hl(0, { name = 'AgentIdeLevel' .. i }).fg), hex)
  end
  eq(vim.api.nvim_get_hl(0, { name = 'AgentIdeWaiting', link = true }).link, 'AgentIdeLevel4')
  use({ sess('a', 'waiting') })
  local c = require('agent-ide').lualine()
  eq(c[1](), 'input required (1)')
  eq(c.color(), { fg = '#a277ff' })
end

return T
