local status = require('agent-ide.status')
local session = require('agent-ide.session')
local eq = MiniTest.expect.equality

local NOW = 1000000
local notes, dir, orig_notify, env_xdg, orig_stdpath

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
    orig_stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(w) if w == 'state' then return dir .. '/state' end return orig_stdpath(w) end
    use({}, {})
  end,
  post_case = function()
    status._reset() -- cancel timers
    vim.wait(80, function() return false end, 10) -- let in-flight async writes finish before the dir goes
    vim.notify = orig_notify
    vim.fn.stdpath = orig_stdpath
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

T['quota text: percent used, the bar fills with use'] = function()
  use({})
  set_quota({ five_hour = { utilization = 0.07, resets_at = NOW + 100 }, seven_day = { utilization = 0.18, resets_at = NOW + 100 } })
  eq(status.statusline(), 'agents ok · 5h ▱▱▱▱▱ 7%% · week ▰▱▱▱▱ 18%%')
  set_quota({ five_hour = { utilization = 0.625 }, seven_day = { utilization = 0.005 } })
  eq(status.statusline(), 'agents ok · 5h ▰▰▰▱▱ 63%% · week ▱▱▱▱▱ 1%%') -- floor(x*100+0.5)
end

T['quota: readable labels, clamping, overage windows only when alone'] = function()
  use({})
  set_quota({ zeta_window = { utilization = 1.5 }, five_hour = { utilization = 0 }, seven_day_opus = { utilization = 0.5 },
    seven_day_overage_included = { utilization = 0.9 }, seven_day = { utilization = -0.2 } })
  eq(status.statusline(), 'agents ok · 5h ▱▱▱▱▱ 0%% · week ▱▱▱▱▱ 0%% · week opus ▰▰▰▱▱ 50%% · zeta window ▰▰▰▰▰ 100%%')
  set_quota({ seven_day_overage_included = { utilization = 0.9 } })
  eq(status.statusline(), 'agents ok · week overage included ▰▰▰▰▰ 90%%')
end

T['quota age: shown after 10 min; dimmed with ? after 60 min or past the reset'] = function()
  use({})
  set_quota({ five_hour = { utilization = 0.4, resets_at = NOW - 1 }, seven_day = { utilization = 0.18, resets_at = NOW + 100000 } })
  eq(status.statusline(), 'agents ok · 5h ▪▪▫▫▫ ? · week ▰▱▱▱▱ 18%%')
  status._src.now = function() return NOW + 10 * 60 end
  eq(status.statusline(), 'agents ok · 5h ▪▪▫▫▫ ? · week ▰▱▱▱▱ 18%%')
  status._src.now = function() return NOW + 25 * 60 end
  eq(status.statusline(), 'agents ok · 5h ▪▪▫▫▫ ? · week ▰▱▱▱▱ 18%% · 25m old')
  status._src.now = function() return NOW + 3600 + 1 end
  eq(status.statusline(), 'agents ok · 5h ▪▪▫▫▫ ? · week ▪▫▫▫▫ ? · 1h old')
end

T['quota.file: parsed times and shapes'] = function()
  eq(status._parse_time('1970-01-01T00:00:00Z'), 0)
  eq(status._parse_time('2026-11-10T12:30:15.123+01:00'), 1794310215)
  eq(status._parse_time('2026-11-10T11:30:15Z'), 1794310215)
  eq(status._parse_time('2026-11-10T06:30:15-05:00'), 1794310215)
  eq(status._parse_time(1794310215000), 1794310215)
  eq(status._parse_time('yesterday'), nil)
  local q = status._parse_quota_file(vim.json.encode({ limits = {
    { label = 'Session', percent = 0.42, resetsAt = '2026-11-10T11:30:15Z' }, { label = 'Weekly', percent = 64 } },
    updatedAt = '1970-01-01T00:16:40Z', other = { 1 } }), 5)
  eq(q, { limits = { { label = 'Session', used = 0.42, resets_at = 1794310215 }, { label = 'Weekly', used = 0.64 } },
    updated = 1000 })
  eq(status._parse_quota_file(vim.json.encode({ limits = { { label = 'x', percent = 0.1 } } }), 7).updated, 7) -- mtime
  for _, bad in ipairs({ '{not json', '[]', '{"limits":{}}', '{"limits":[]}', '{"limits":[{"label":"x"}]}',
    '{"limits":[{"label":1,"percent":0.1}]}' }) do
    eq(status._parse_quota_file(bad, 1), nil)
  end
end

T['quota.file: its limits replace the own values; missing, malformed or old falls back'] = function()
  local config = require('agent-ide.config')
  local file = dir .. '/usage.json'
  local now = os.time()
  use({})
  status._src.now = function() return now end
  local function iso(t) return os.date('!%Y-%m-%dT%H:%M:%SZ', t) end
  local function write(obj) vim.fn.writefile({ type(obj) == 'string' and obj or vim.json.encode(obj) }, file) end
  local function line() return status.statusline() end
  local function wait_line(want, ms)
    if vim.wait(ms or 2000, function() return line() == want end, 10) then return true end
    if ms then return false end
    error('want ' .. want .. ', have ' .. line(), 2)
  end
  write({ limits = { { label = 'Session', percent = 0.42, resetsAt = iso(now + 600) },
    { label = 'Week', percent = 0.9, resetsAt = iso(now - 1) } }, updatedAt = iso(now - 60) })
  config.setup({ quota = { file = file } })
  local ok, err = pcall(function()
    set_quota({ five_hour = { utilization = 0.1 } })
    status._src.now = function() return now end
    eq(wait_line('agents ok · Session ▰▰▱▱▱ 42%% · Week ▪▪▪▪▪ ?'), true)
    -- read at most every 60 s: a change shows only then
    write({ limits = { { label = 'Session', percent = 0.5 } }, updatedAt = iso(now - 60) })
    vim.wait(100)
    eq(line(), 'agents ok · Session ▰▰▱▱▱ 42%% · Week ▪▪▪▪▪ ?')
    now = now + 61
    eq(wait_line('agents ok · Session ▰▰▰▱▱ 50%%'), true)
    -- older than 10 min (written 20 min before, read a minute later): says so; older than 30 min: the own values
    write({ limits = { { label = 'Session', percent = 0.5 } }, updatedAt = iso(now - 20 * 60) })
    now = now + 61
    eq(wait_line('agents ok · Session ▰▰▰▱▱ 50%% · 21m old'), true)
    write({ limits = { { label = 'Session', percent = 0.5 } }, updatedAt = iso(now - 31 * 60 - 61) })
    now = now + 61
    eq(wait_line('agents ok · 5h ▰▱▱▱▱ 10%%'), true)
    -- malformed, then missing
    write({ limits = { { label = 'Session', percent = 0.5 } }, updatedAt = iso(now) })
    now = now + 61
    eq(wait_line('agents ok · Session ▰▰▰▱▱ 50%%'), true)
    write('{"limits": "nope"')
    now = now + 61
    eq(wait_line('agents ok · 5h ▰▱▱▱▱ 10%%'), true)
    write({ limits = { { label = 'Session', percent = 0.5 } }, updatedAt = iso(now) })
    now = now + 61
    eq(wait_line('agents ok · Session ▰▰▰▱▱ 50%%'), true)
    os.remove(file)
    now = now + 61
    eq(wait_line('agents ok · 5h ▰▱▱▱▱ 10%%'), true)
  end)
  config.setup({})
  if not ok then error(err, 0) end
end

T['quota.file: a FIFO (or a symlink to one) is never opened; once it is a regular file the next read works'] = function()
  if vim.fn.executable('mkfifo') == 0 then return MiniTest.skip('mkfifo is missing') end
  local config = require('agent-ide.config')
  local fifo, link = dir .. '/usage.fifo', dir .. '/usage.link'
  vim.fn.system({ 'mkfifo', fifo })
  eq(vim.v.shell_error, 0)
  local now = os.time()
  use({})
  status._src.now = function() return now end
  local function iso(t) return os.date('!%Y-%m-%dT%H:%M:%SZ', t) end
  local function line() return status.statusline() end
  local function wait_line(want)
    if vim.wait(2000, function() return line() == want end, 10) then return true end
    error('want ' .. want .. ', have ' .. line(), 2)
  end
  local ext = 'agents ok · Session ▰▰▰▱▱ 50%%'
  local own = 'agents ok · 5h ▰▱▱▱▱ 10%%'
  config.setup({ quota = { file = link } })
  local ok, err = pcall(function()
    set_quota({ five_hour = { utilization = 0.1 } })
    status._src.now = function() return now end
    -- the link points to a FIFO: the footer shows its own values and stays responsive
    vim.uv.fs_symlink(fifo, link)
    eq(line(), own)
    vim.wait(300)
    eq(line(), own)
    -- the FIFO replaced by a regular file: the next read (60 s later) works
    os.remove(link)
    os.remove(fifo)
    vim.fn.writefile({ vim.json.encode({ limits = { { label = 'Session', percent = 0.5 } }, updatedAt = iso(now) }) }, link)
    now = now + 61
    line()
    eq(wait_line(ext), true)
    -- the path itself a FIFO
    os.remove(link)
    config.setup({ quota = { file = fifo } })
    vim.fn.system({ 'mkfifo', fifo })
    now = now + 61
    line()
    vim.wait(300)
    eq(wait_line(own), true)
    os.remove(fifo)
    vim.fn.writefile({ vim.json.encode({ limits = { { label = 'Session', percent = 0.5 } }, updatedAt = iso(now) }) }, fifo)
    now = now + 61
    line()
    eq(wait_line(ext), true)
  end)
  config.setup({})
  if not ok then error(err, 0) end
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
  eq(status.statusline(), 'agents ok · 5h ▱▱▱▱▱ 7%%')
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
  local obj = read_json(status.file())
  eq(obj, {
    version = 1, pid = vim.fn.getpid(), updated = NOW, level = 4, name = 'input', waiting = 1, review = 0, busy = 2,
    sessions = {
      { id = 'a', project = 'a', title = 'T a', state = 'waiting', reason = 'Bash' },
      { id = 'b', project = 'b', title = 'T b', state = 'busy', reason = '' },
    },
  })
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
  wait_file(status.file())
  status._cleanup()
  eq(vim.uv.fs_stat(status.file()), nil)
end

T['files removed on leave, nothing recreated afterwards'] = function()
  local ss = { sess('a', 'busy') }
  use(ss)
  status.setup()
  wait_file(status.file())
  ss[1].title = 'changed' -- a trailing write is pending
  status.refresh()
  status._cleanup()
  status.refresh()
  session._emit(session.open({ cwd = dir }), 'state')
  vim.wait(500, function() return false end, 20)
  eq(vim.uv.fs_stat(status.file()), nil)
  eq(vim.uv.fs_stat(dir .. '/state/agent-ide/quota.json'), nil)
end

T['a write in flight when leaving is undone'] = function()
  use({ sess('a', 'busy') })
  status.refresh() -- async chain started, not finished
  status._cleanup()
  vim.wait(300, function() return false end, 20)
  eq(vim.uv.fs_stat(status.file()), nil)
end

T['quota is flushed synchronously on leave'] = function()
  use({})
  set_quota({ five_hour = { utilization = 0.5, resets_at = NOW + 10 } })
  status._cleanup() -- no waiting: the file must exist right after
  local file = dir .. '/state/agent-ide/quota.json'
  eq(vim.uv.fs_stat(file) ~= nil, true)
  eq(vim.json.decode(table.concat(vim.fn.readfile(file), '\n')).windows.five_hour.utilization, 0.5)
end

T['sweep removes only status files of dead pids'] = function()
  local d = dir .. '/run/agent-ide'
  vim.fn.mkdir(d, 'p')
  local alive = vim.system({ 'sleep', '30' })
  local dead = vim.system({ 'true' }):wait()
  local dead_pid = vim.system({ 'sh', '-c', 'echo $$' }):wait().stdout:match('%d+')
  local function put(name) vim.fn.writefile({ '{}' }, d .. '/' .. name) end
  put('status-' .. alive.pid .. '.json')
  put('status-' .. dead_pid .. '.json')
  put('status-' .. dead_pid .. '.json.bak')
  put('notes.json')
  local removed
  status.sweep(function(r) removed = r end)
  vim.wait(2000, function() return removed ~= nil end, 10)
  vim.wait(100, function() return false end, 10)
  alive:kill(15)
  eq(removed, { 'status-' .. dead_pid .. '.json' })
  eq(vim.uv.fs_stat(d .. '/status-' .. alive.pid .. '.json') ~= nil, true)
  eq(vim.uv.fs_stat(d .. '/status-' .. dead_pid .. '.json'), nil)
  eq(vim.uv.fs_stat(d .. '/status-' .. dead_pid .. '.json.bak') ~= nil, true)
  eq(vim.uv.fs_stat(d .. '/notes.json') ~= nil, true)
  eq(dead.code, 0)
end

T['heartbeat rewrites while level > 1, not at level 1'] = function()
  status._cfg.heartbeat_ms = 60
  local ss = { sess('a', 'busy') }
  use(ss)
  status.setup()
  vim.wait(300, function() return false end, 20)
  local w = status._writes()
  vim.wait(700, function() return false end, 20)
  eq(status._writes() - w >= 2, true)
  ss[1].state = 'idle'
  status.refresh()
  vim.wait(300, function() return false end, 20)
  w = status._writes()
  vim.wait(500, function() return false end, 20)
  eq(status._writes(), w)
end

T['fallback directory is stdpath run when XDG_RUNTIME_DIR is unset'] = function()
  vim.uv.os_unsetenv('XDG_RUNTIME_DIR')
  eq(status.file(), vim.fn.stdpath('run') .. '/agent-ide/status-' .. vim.fn.getpid() .. '.json')
  use({ sess('a', 'busy') })
  status.refresh()
  eq(wait_file(status.file()), true)
  status._cleanup()
end

T['an existing runtime dir with loose mode is tightened to 0700'] = function()
  vim.fn.mkdir(dir .. '/run/agent-ide', 'p', '0755')
  vim.uv.fs_chmod(dir .. '/run/agent-ide', tonumber('755', 8))
  use({ sess('a', 'busy') })
  status.refresh()
  wait_file(status.file())
  eq(vim.uv.fs_stat(dir .. '/run/agent-ide').mode % 512, tonumber('700', 8))
end

T['a failed rename leaves no tmp file'] = function()
  local d = dir .. '/run/agent-ide'
  vim.fn.mkdir(d .. '/status-' .. vim.fn.getpid() .. '.json', 'p') -- a directory in the way
  use({ sess('a', 'busy') })
  status.refresh()
  vim.wait(300, function() return false end, 20)
  eq(vim.fn.glob(d .. '/*.tmp'), '')
  eq(#vim.tbl_filter(function(n) return n.level == vim.log.levels.WARN end, notes), 1)
end

T['quota reset time in milliseconds is converted'] = function()
  use({})
  local now = 1.78e9
  status._src.now = function() return now end
  set_quota({ five_hour = { utilization = 0.1, resets_at = (now + 100) * 1000 } })
  eq(status.statusline(), 'agents ok · 5h ▰▱▱▱▱ 10%%')
  set_quota({ five_hour = { utilization = 0.1, resets_at = (now - 100) * 1000 } })
  eq(status.statusline(), 'agents ok · 5h ▪▫▫▫▫ ?')
end

T['refresh errors never reach the dispatcher; deltas are ignored'] = function()
  local s = session.open({ cwd = dir })
  status.setup()
  local n = status._refreshes()
  session._emit(s, 'delta')
  eq(status._refreshes(), n)
  status._src.sessions = function() error('boom') end
  eq(pcall(session._emit, s, 'state'), true)
  eq(#notes, 0) -- the dispatcher saw no listener error
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
  local s = session.open({ cwd = dir })
  use({})
  status.setup()
  status.setup()
  local n = status._refreshes()
  session._emit(s, 'state')
  eq(status._refreshes() - n, 1)
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
