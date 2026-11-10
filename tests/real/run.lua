-- `make test-real`: drives the plugin in a headless child Neovim against the REAL `claude`
-- (model haiku; sonnet for one turn), in a temporary git repository. Not part of `make test`.
-- Prints one PASS/FAIL line per check and nothing from the conversation's content.
-- Cleans up after itself: the temporary repository, the transcript directory Claude made for
-- it under ~/.claude/projects (only the one named after the temporary path, and only when the
-- run created it) and the plan files Claude reported writing. KEEP=1 keeps them for debugging.
local uv = vim.uv
local child = MiniTest.new_child_neovim()

local TURN_MS = tonumber(vim.env.REAL_TURN_MS) or 240000
local results, turns, pids, pid_seen, plan_files = {}, 0, {}, {}, {}

local function out(line) io.stdout:write(line .. '\n') end

-- Temporary project --------------------------------------------------------------------------

local tmp = uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
tmp = uv.fs_realpath(tmp)
local repo = tmp .. '/repo'
local projects = tmp .. '/projects'
vim.fn.mkdir(repo, 'p')
vim.fn.mkdir(projects, 'p')
vim.fn.writefile({ 'zebra crossing', 'second line' }, repo .. '/notes.txt')
vim.fn.writefile({ 'kiwi orange' }, repo .. '/my notes.txt')
vim.fn.system({ 'git', '-C', repo, 'init', '-q' })
vim.fn.system({ 'git', '-C', repo, 'add', '.' })
vim.fn.system({ 'git', '-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'init' })

-- Claude keeps the transcripts of a folder in ~/.claude/projects/<path with every
-- non-alphanumeric character as '-'>. The drawer reads a projects folder holding only a link
-- to that one directory, so it never scans the user's other sessions.
local claude_projects = vim.fn.expand('~/.claude/projects')
local slug = repo:gsub('[^%w]', '-')
local real_dir = claude_projects .. '/' .. slug
if uv.fs_stat(real_dir) then
  out('ABORT: ' .. real_dir .. ' exists already; not touching it')
  vim.cmd('cquit 1')
end
uv.fs_symlink(real_dir, projects .. '/' .. slug)

-- Child ------------------------------------------------------------------------------------

child.restart({ '-u', 'tests/minimal_init.lua' })
child.lua([==[
  local opts = ...
  vim.env.TMUX = nil
  _G.R = { selects = {}, notes = {}, asks = {}, ask_ids = {}, pids = {}, pid_seen = {}, plans = {} }
  vim.notify = function(msg) table.insert(R.notes, msg) end
  local session = require('agent-ide.session')
  local chat = require('agent-ide.ui.chat')

  -- vim.ui.select answers by policy; the prompt and labels are recorded, never printed
  local POLICY = {
    allow = function(l) return vim.tbl_contains(l, 'Allow') and 'Allow' or l[1] end,
    deny = function(l) return vim.tbl_contains(l, 'Deny') and 'Deny' or nil end,
    first = function(l) return l[1] end,
    plan_accept = function(l)
      local want = 'Approve plan and accept edits for this session'
      if vim.tbl_contains(l, want) then return want end
      return vim.tbl_contains(l, 'Allow') and 'Allow' or l[1]
    end,
  }
  vim.ui.select = function(items, o, cb)
    local labels = {}
    for i, it in ipairs(items) do labels[i] = o.format_item and o.format_item(it) or tostring(it) end
    table.insert(R.selects, { prompt = o.prompt or '', labels = labels })
    local p = R.policy
    local want = type(p) == 'string' and (POLICY[p] and POLICY[p](labels) or p) or nil
    for i, l in ipairs(labels) do
      if l == want then return cb(items[i], i) end
    end
    cb(nil, nil)
  end

  session.on_change(function(s, what)
    if what == 'permission' then
      for _, p in ipairs(s.pending_permissions) do
        if not R.ask_ids[p.request_id] then
          R.ask_ids[p.request_id] = true
          table.insert(R.asks, p.tool_name)
          if p.tool_name == 'ExitPlanMode' and type(p.input) == 'table' and type(p.input.planFilePath) == 'string' then
            table.insert(R.plans, p.input.planFilePath)
          end
        end
      end
    elseif what == 'delta' and R.interrupt_on_delta then
      -- run the prompt buffer's interrupt key mapping as soon as the first text arrives (typed
      -- keys wait for the input loop, and haiku can finish 200 lines before that)
      R.interrupt_on_delta = false
      local m = vim.fn.maparg('<C-c>', 'n', false, true)
      R.interrupt_mapped = type(m.callback) == 'function'
      if R.interrupt_mapped then m.callback() end
    elseif what == 'state' and s.pid and not R.pid_seen[s.pid] then
      R.pid_seen[s.pid] = true
      table.insert(R.pids, s.pid)
    end
  end)

  function R.s() return session.get(R.sid) end
  function R.results()
    local n = 0
    for _, e in ipairs(R.s().raw) do
      if e.dir == 'in' then
        local ok, o = pcall(vim.json.decode, e.line)
        if ok and type(o) == 'table' and o.type == 'result' then n = n + 1 end
      end
    end
    return n
  end
  function R.prompt_win() return chat._windows().prompt end
  -- the last `result` object received (subtype and terminal_reason only)
  function R.last_result()
    for i = #R.s().raw, 1, -1 do
      local e = R.s().raw[i]
      if e.dir == 'in' then
        local ok, o = pcall(vim.json.decode, e.line)
        if ok and type(o) == 'table' and o.type == 'result' then
          return { subtype = o.subtype, terminal_reason = o.terminal_reason }
        end
      end
    end
  end
  function R.tbuf() return (chat.buffers(R.s())) end
  function R.buffer() return vim.api.nvim_buf_get_lines(R.tbuf(), 0, -1, false) end
  function R.focus_prompt()
    vim.cmd('stopinsert')
    vim.api.nvim_set_current_win(R.prompt_win())
  end
  function R.set_prompt(lines)
    R.focus_prompt()
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(R.prompt_win()), 0, -1, false, lines)
  end
  -- text of the assistant `text` events after the last prompt event
  function R.answer()
    local ev, parts = R.s().events, {}
    for i = #ev, 1, -1 do
      if ev[i].kind == 'prompt' then break end
      if ev[i].kind == 'text' then table.insert(parts, 1, ev[i].text) end
    end
    return table.concat(parts, '\n')
  end
  function R.transcript_path()
    local f = vim.fn.glob(opts.real_dir .. '/' .. R.sid .. '.jsonl')
    return f ~= '' and f or nil
  end

  local function tag(e)
    if not e then return '-' end
    return e.kind .. (e.label and ('/' .. e.label) or '') .. (e.sidechain and '/sidechain' or '')
  end
  -- History equals live: Claude's transcript file against what the session showed.
  function R.compare(save)
    local render = require('agent-ide.transcript.render')
    local path = R.transcript_path()
    if not path then return { missing = true } end
    local f = assert(io.open(path, 'rb'))
    local text = f:read('*a')
    f:close()
    local file = require('agent-ide.transcript.parse').parse_text(text)
    local live = vim.tbl_filter(function(e) return not e.live_only end, R.s().events)
    -- align the two lists (longest common subsequence), then report what is not shared
    local n, m = #live, #file
    local L = {}
    for i = n + 1, 1, -1 do
      L[i] = {}
      for j = m + 1, 1, -1 do
        if i > n or j > m then L[i][j] = 0
        elseif vim.deep_equal(live[i], file[j]) then L[i][j] = L[i + 1][j + 1] + 1
        else L[i][j] = math.max(L[i + 1][j], L[i][j + 1]) end
      end
    end
    local diffs, i, j = {}, 1, 1
    while i <= n or j <= m do
      if i <= n and j <= m and vim.deep_equal(live[i], file[j]) then
        i, j = i + 1, j + 1
      elseif i <= n and j <= m and tag(live[i]) == tag(file[j]) and L[i + 1][j + 1] >= math.max(L[i + 1][j], L[i][j + 1]) then
        diffs[#diffs + 1] = ('live event %d / file event %d: %s, fields differ'):format(i, j, tag(live[i]))
        i, j = i + 1, j + 1
      elseif j > m or (i <= n and L[i + 1][j] >= L[i][j + 1]) then
        diffs[#diffs + 1] = ('live event %d (%s): not in the file'):format(i, tag(live[i]))
        i = i + 1
      else
        diffs[#diffs + 1] = ('file event %d (%s): not shown live'):format(j, tag(file[j]))
        j = j + 1
      end
    end
    if save and opts.keep and #diffs > 0 then
      local dir = opts.diag_dir
      local f2 = io.open(dir .. '/diff-' .. (#vim.fn.glob(dir .. '/diff-*', false, true) + 1) .. '.json', 'w')
      if f2 then
        f2:write(vim.json.encode({ live = live, file = file }))
        f2:close()
      end
    end
    return {
      diffs = diffs,
      buffer_is_live_render = vim.deep_equal(R.buffer(), render.render(R.s().events).lines),
      live_render_is_file_render = vim.deep_equal(render.render(live).lines, render.render(file).lines),
    }
  end

  require('agent-ide').setup(opts.setup)
]==], { {
  real_dir = real_dir,
  -- KEEP=1 writes the events of each history mismatch to REAL_DIAG (default: the temporary folder)
  diag_dir = vim.env.REAL_DIAG or tmp,
  keep = vim.env.KEEP == '1',
  setup = { projects_dir = projects, claude = { model = 'haiku' } },
} })

-- Helpers ----------------------------------------------------------------------------------

local function get(expr, ...) return child.lua_get(expr, { ... }) end

local function wait_for(cond, what, ms)
  if not vim.wait(ms or 30000, function()
    local ok, v = pcall(cond)
    return ok and v
  end, 100) then
    error('timed out waiting for ' .. what, 0)
  end
end

local function expect(cond, what)
  if not cond then error(what, 0) end
end

local function state() return get('R.s().state') end

-- every process that belongs to the session's claude (for the leftover check)
local function note_descendants()
  local list = vim.fn.systemlist({ 'ps', '-e', '-o', 'pid=,ppid=' })
  local kids = {}
  for _, l in ipairs(list) do
    local p, pp = l:match('^%s*(%d+)%s+(%d+)')
    if p then
      kids[tonumber(pp)] = kids[tonumber(pp)] or {}
      table.insert(kids[tonumber(pp)], tonumber(p))
    end
  end
  local function walk(pid)
    for _, k in ipairs(kids[pid] or {}) do
      if not pid_seen[k] then
        pid_seen[k] = true
        table.insert(pids, k)
      end
      walk(k)
    end
  end
  for _, pid in ipairs(get('R.pids')) do
    if not pid_seen[pid] then
      pid_seen[pid] = true
      table.insert(pids, pid)
    end
    walk(pid)
  end
end

---Type the prompt into the prompt buffer and press the send key; wait until the turn is over.
local function turn(lines, opts)
  opts = opts or {}
  local before = get('R.results()')
  child.lua('R.set_prompt(...)', { lines })
  child.type_keys('<C-CR>')
  turns = turns + 1
  wait_for(function() return get('R.s().state') == 'busy' or get('R.results()') > before end, 'turn start', 20000)
  if opts.no_wait then return before end
  local n = opts.results or 1
  wait_for(function() return get('R.results()') >= before + n and get('R.s().state') == 'idle' end, 'turn end', TURN_MS)
  note_descendants()
  return before
end

-- Check 8 runs after every turn: the file Claude writes may lag behind the result a little.
local history = { ok = true, diffs = {}, compared = 0 }
local function compare_history(label)
  local res
  local ok = vim.wait(20000, function()
    res = get('R.compare()')
    return not res.missing and #res.diffs == 0 and res.live_render_is_file_render
  end, 250)
  if not ok and res and not res.missing then res = get('R.compare(true)') end
  history.compared = history.compared + 1
  if not res or res.missing then
    history.ok = false
    table.insert(history.diffs, label .. ': transcript file not found')
    return
  end
  if not res.buffer_is_live_render then
    history.ok = false
    table.insert(history.diffs, label .. ': buffer differs from render(session events)')
  end
  if not ok then
    history.ok = false
    for _, d in ipairs(res.diffs) do table.insert(history.diffs, label .. ': ' .. d) end
    if #res.diffs == 0 then table.insert(history.diffs, label .. ': rendered lines differ') end
  end
end

-- REAL_ONLY=1,6 runs only those checks (check 1 starts the session and always runs)
local only = vim.env.REAL_ONLY and vim.split(vim.env.REAL_ONLY, ',', { trimempty = true }) or nil

local function check(n, name, fn)
  if only and n ~= 1 and not vim.tbl_contains(only, tostring(n)) then return end
  local ok, err = pcall(fn)
  results[#results + 1] = { n = n, name = name, ok = ok }
  out(('%s %2d %s%s'):format(ok and 'PASS' or 'FAIL', n, name, ok and '' or (': ' .. tostring(err))))
end

local function answer_has(word) return get('R.answer()'):lower():find(word, 1, true) ~= nil end

local function last_header_has(word)
  local lines = get('R.buffer()')
  local header
  for i = #lines, 1, -1 do
    if lines[i] == '## Claude' then header = i; break end
  end
  if not header then return false end
  for i = header + 1, #lines do
    if lines[i]:lower():find(word, 1, true) then return true end
  end
  return false
end

local function mode_is(m)
  wait_for(function()
    return get('R.s().mode') == m and get('R.s().mode_requested') == vim.NIL
  end, 'mode ' .. m, 30000)
end

local FIRST_PROMPT = 'Reply with exactly: pong'
local ASK_FIRST = 'What was the very first message I sent you in this conversation? Reply with that message only.'

-- Checks -----------------------------------------------------------------------------------

local api_key_present = get('vim.env.ANTHROPIC_API_KEY ~= nil')
out('ANTHROPIC_API_KEY set in the test Neovim: ' .. (api_key_present and 'yes' or 'no'))

check(1, 'new session answers pong; idle; model and mode known; API key stripped', function()
  child.lua([[
    local repo = ...
    require('agent-ide').toggle()
    local s = require('agent-ide.session').open({ cwd = repo })
    R.sid = s.id
    require('agent-ide.ui.chat').open(s, { key = repo, name = 'repo', root = repo, is_git = true, sessions = {} })
  ]], { repo })
  turn({ FIRST_PROMPT })
  expect(last_header_has('pong'), 'pong not under the last ## Claude header')
  expect(state() == 'idle', 'state is not idle')
  local bar = get('vim.wo[require("agent-ide.ui.chat")._windows().transcript].winbar')
  expect(not bar:find('model ?', 1, true) and not bar:find('mode:?', 1, true), 'winbar lacks model or mode')
  -- the child's environment, and what Claude reports as its key source
  local pid = get('R.s().pid')
  local f = io.open('/proc/' .. pid .. '/environ', 'rb')
  expect(f ~= nil, 'cannot read the environment of the claude process')
  local env = f:read('*a')
  f:close()
  expect(not ('\0' .. env):find('\0ANTHROPIC_API_KEY=', 1, true), 'claude process has ANTHROPIC_API_KEY')
  local sources = get([[vim.tbl_map(function(e)
    local o = vim.json.decode(e.line); return o.apiKeySource or '' end,
    vim.tbl_filter(function(e) return e.dir == 'in' and e.line:find('"subtype":"init"', 1, true) ~= nil end, R.s().raw))]])
  expect(#sources > 0, 'no init seen')
  for _, src in ipairs(sources) do expect(src == 'none', 'init apiKeySource is not none') end
  compare_history('turn 1')
end)

check(2, '[attach] lines (one path with a space) make Claude read the files', function()
  turn({ '[attach] notes.txt', '[attach] my notes.txt',
    'Without using any tools: reply with the first word of each attached file, separated by one space.' })
  expect(answer_has('zebra'), 'first word of notes.txt missing')
  expect(answer_has('kiwi'), 'first word of "my notes.txt" missing')
  compare_history('turn 2')
end)

check(3, 'manual mode: Write asks; Allow writes the file; Deny leaves it absent and ends the turn', function()
  child.lua('R.s():set_mode("default")')
  mode_is('manual')
  child.lua('R.policy = "allow"')
  local asks = #get('R.asks')
  turn({ 'Use the Write tool to create the file new.txt containing the word hi. Do nothing else.' })
  expect(#get('R.asks') > asks and get('R.asks')[asks + 1] == 'Write', 'no Write ask')
  expect(uv.fs_stat(repo .. '/new.txt') ~= nil, 'new.txt was not written')
  compare_history('turn 3')
  child.lua('R.policy = "deny"')
  asks = #get('R.asks')
  turn({ 'Use the Write tool to create the file denied.txt containing the word no. If that is denied, do not retry; reply only: denied.' })
  expect(#get('R.asks') > asks, 'no ask for the second Write')
  expect(uv.fs_stat(repo .. '/denied.txt') == nil, 'denied.txt exists')
  expect(state() == 'idle', 'turn did not end')
  child.lua('R.policy = nil')
  compare_history('turn 4')
end)

check(4, '<S-Tab> to plan is confirmed by Claude; back to manual', function()
  child.lua('R.focus_prompt()')
  child.type_keys('<S-Tab>')
  mode_is('acceptEdits')
  child.type_keys('<S-Tab>')
  mode_is('plan')
  child.lua('R.s():set_mode("default")')
  mode_is('manual')
end)

check(5, 'model switch to sonnet confirmed; context kept; back to haiku', function()
  child.lua('R.focus_prompt(); R.policy = "sonnet"')
  child.type_keys('\\aM')
  wait_for(function() return get('R.s().model') == 'sonnet' end, 'sonnet confirmed')
  child.lua('R.policy = nil')
  turn({ ASK_FIRST })
  expect(get('R.s().model'):find('sonnet', 1, true) ~= nil, 'turn did not run on sonnet')
  expect(answer_has('pong'), 'first prompt not remembered')
  compare_history('turn 5')
  child.lua('R.focus_prompt(); R.policy = "haiku"')
  child.type_keys('\\aM')
  wait_for(function() return get('R.s().model') == 'haiku' end, 'haiku confirmed')
  child.lua('R.policy = nil')
end)

check(6, 'interrupt a long answer; the turn ends idle; the next prompt is answered', function()
  child.lua('R.interrupt_on_delta = true')
  local before = turn({ 'Count from 1 to 200, one number per line, nothing else.' }, { no_wait = true })
  wait_for(function() return get('R.results()') > before and state() == 'idle' end, 'interrupted turn end', TURN_MS)
  expect(get('R.interrupt_on_delta') == false, 'no delta arrived')
  expect(get('R.interrupt_mapped') == true, 'the interrupt key is not mapped in the prompt buffer')
  local res = get('R.last_result()')
  local sent = get([[#vim.tbl_filter(function(e)
    return e.dir == 'out' and e.line:find('"subtype":"interrupt"', 1, true) ~= nil end, R.s().raw)]])
  expect(sent > 0, 'no interrupt request was sent')
  expect(res.subtype == 'error_during_execution' and res.terminal_reason == 'aborted_streaming',
    ('the turn was not ended by the interrupt (result %s/%s)'):format(tostring(res.subtype), tostring(res.terminal_reason)))
  compare_history('turn 6 (interrupted)')
  turn({ 'Reply with exactly: ok' })
  expect(answer_has('ok'), 'no answer after the interrupt')
  compare_history('turn 7')
end)

check(7, 'a prompt sent while busy is queued and answered after the current turn, in order', function()
  local before = turn({ 'Reply with exactly: one' }, { no_wait = true })
  child.lua('R.set_prompt(...)', { { 'Reply with exactly: two' } })
  child.type_keys('<C-CR>')
  turns = turns + 1
  expect(get('#R.s().queue') == 1, 'second prompt was not queued by the plugin')
  wait_for(function() return get('R.results()') >= before + 2 and state() == 'idle' end, 'both turns', TURN_MS * 2)
  note_descendants()
  local seq = get([[(function()
    local out = {}
    for _, e in ipairs(R.s().events) do
      if e.kind == 'prompt' then out[#out + 1] = 'p:' .. e.text
      elseif e.kind == 'text' then out[#out + 1] = 't:' .. e.text:lower() end
    end
    return vim.list_slice(out, #out - 3)
  end)()]])
  expect(seq[1] == 'p:Reply with exactly: one' and seq[2]:find('one', 1, true)
    and seq[3] == 'p:Reply with exactly: two' and seq[4]:find('two', 1, true), 'prompts or answers out of order')
  compare_history('turns 8-9 (queued)')
end)

check(9, 'park, reopen from the drawer, the resumed session remembers the first prompt', function()
  -- the "running elsewhere" rule compares the live entry's pid with the one we spawned
  wait_for(function() return get('require("agent-ide.live").get()[R.sid] ~= nil') end, 'live entry', 30000)
  expect(get('require("agent-ide.live").get()[R.sid].pid') == get('R.s().pid'), 'live pid differs from the spawned pid')
  child.lua('R.parked = false; R.s():park(function(ok) R.parked = ok end)')
  wait_for(function() return get('R.parked') == true and state() == 'parked' end, 'parked', 30000)
  -- the drawer: rescan, expand the project, open the session row
  child.lua([[
    local d = require('agent-ide.ui.drawer')
    vim.api.nvim_set_current_win(d.state().win)
  ]])
  child.type_keys('R')
  local function row(pred)
    return get([[(function(kind, id)
      local st = require('agent-ide.ui.drawer').state()
      for i, n in ipairs(st.nodes or {}) do
        if kind == 'session' and n.type == 'session' and n.session.id == id then return i end
        if kind == 'project' and n.type == 'project' and n.project.root == id then return i end
      end
      return 0
    end)(...)]], pred[1], pred[2])
  end
  wait_for(function() return row({ 'project', repo }) > 0 end, 'project row', 30000)
  if row({ 'session', get('R.sid') }) == 0 then
    child.lua('vim.api.nvim_win_set_cursor(0, { ..., 0 })', { row({ 'project', repo }) })
    child.type_keys('<CR>')
  end
  wait_for(function() return row({ 'session', get('R.sid') }) > 0 end, 'session row', 30000)
  child.lua('vim.api.nvim_win_set_cursor(0, { ..., 0 })', { row({ 'session', get('R.sid') }) })
  child.type_keys('<CR>')
  wait_for(function() return get('require("agent-ide.ui.chat").current() == R.s()') end, 'chat reopened', 30000)
  wait_for(function() return get('R.s().path') ~= vim.NIL end, 'session path', 10000)
  turn({ ASK_FIRST })
  local f = io.open('/proc/' .. get('R.s().pid') .. '/cmdline', 'rb')
  local argv = f and f:read('*a') or ''
  if f then f:close() end
  expect(argv:find('\0--resume\0', 1, true) ~= nil, 'process not started with --resume')
  expect(answer_has('pong'), 'resumed session did not remember the first prompt')
  compare_history('turn 10 (resumed)')
end)

check(10, '/context renders output and the session returns to idle', function()
  expect(get('vim.tbl_contains(R.s().slash_commands or {}, "context")'), 'context not among the slash commands')
  local n = get('#R.s().events')
  turn({ '/context' })
  local labels = get('vim.tbl_map(function(e) return e.kind .. "/" .. tostring(e.label) end, vim.list_slice(R.s().events, ...))', n + 1)
  expect(vim.tbl_contains(labels, 'meta/command output'), 'no command output rendered')
  expect(state() == 'idle', 'not idle')
  compare_history('turn 11 (/context)')
end)

check(11, 'AskUserQuestion: choosing the first option continues the turn', function()
  child.lua('R.policy = "first"')
  local sel = #get('R.selects')
  turn({ 'Use the AskUserQuestion tool to ask me exactly one single-choice question "Pick a color" with the options Red and Blue. After my answer, reply with only the chosen color.' })
  child.lua('R.policy = nil')
  expect(vim.tbl_contains(get('R.asks'), 'AskUserQuestion'), 'no question asked')
  local chosen
  for _, s in ipairs(vim.list_slice(get('R.selects'), sel + 1)) do
    if #s.labels >= 2 then chosen = s.labels[1]:match('^(.-) — ') or s.labels[1] end
  end
  expect(chosen ~= nil, 'no question select')
  expect(answer_has(chosen:lower()), 'answer does not name the chosen option')
  compare_history('turn 12 (question)')
end)

check(12, 'plan mode: approving the plan (and accept edits) lets Claude proceed', function()
  child.lua('R.s():set_mode("plan")')
  mode_is('plan')
  child.lua('R.policy = "plan_accept"')
  turn({ 'Create the file plan.txt containing the word hi. Keep the plan to one short step.' })
  child.lua('R.policy = nil')
  for _, p in ipairs(get('R.plans')) do plan_files[#plan_files + 1] = p end
  expect(vim.tbl_contains(get('R.asks'), 'ExitPlanMode'), 'no plan approval asked')
  expect(uv.fs_stat(repo .. '/plan.txt') ~= nil, 'plan.txt was not written')
  expect(get('R.s().mode') == 'acceptEdits', 'mode after approval is not acceptEdits')
  compare_history('turn 13 (plan)')
  child.lua('R.s():set_mode("default")')
  mode_is('manual')
end)

check(13, 'raw view (gr) holds the sent prompt line byte-exact', function()
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().transcript)')
  child.type_keys('gr')
  wait_for(function() return get('vim.api.nvim_buf_get_name(0)'):find('agent-ide://raw/', 1, true) ~= nil end, 'raw view')
  local sent = get([[(function()
    for _, e in ipairs(R.s().raw) do
      if e.dir == 'out' and e.line:find('"type":"user"', 1, true) then return e.line end
    end
  end)()]])
  local obj = vim.json.decode(sent)
  expect(obj.message.content == FIRST_PROMPT and sent:find('"content":"' .. FIRST_PROMPT .. '"', 1, true),
    'first sent line is not the first prompt')
  expect(vim.tbl_contains(get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), '>> ' .. sent), 'line missing in the raw view')
  child.type_keys('q')
end)

local quota
check(14, 'statusline shows the 5h quota', function()
  wait_for(function() return get('require("agent-ide").statusline()'):find('5h', 1, true) ~= nil end, '5h in statusline', 10000)
  quota = get('require("agent-ide.session").quota()')
end)

out('check  8 runs after every turn: ' .. history.compared .. ' comparisons')
results[#results + 1] = { n = 8, ok = history.ok }
out(('%s  8 history equals live%s'):format(history.ok and 'PASS' or 'FAIL', history.ok and '' or ':'))
for _, d in ipairs(history.diffs) do out('       ' .. d) end

if type(quota) == 'table' then
  local function pct(w) return w and w.utilization and ('%d%%'):format(math.floor(w.utilization * 100 + 0.5)) or '?' end
  out(('quota used: 5h %s, 7d %s'):format(pct(quota.five_hour), pct(quota.seven_day)))
end

-- Stop, check leftovers, clean up ----------------------------------------------------------------

note_descendants()
local unread_notes = get('#R.notes')
child.stop()
vim.wait(3000, function()
  for _, pid in ipairs(pids) do
    if uv.kill(pid, 0) == 0 then return false end
  end
  return true
end, 100)
local alive = 0
for _, pid in ipairs(pids) do
  if uv.kill(pid, 0) == 0 then alive = alive + 1 end
end

local passed, failed = 0, 0
for _, r in ipairs(results) do
  if r.ok then passed = passed + 1 else failed = failed + 1 end
end
out(('checks: %d passed, %d failed; turns: %d; notices: %d'):format(passed, failed, turns, unread_notes))
out(('claude processes started by this run still running: %d (of %d seen)'):format(alive, #pids))

if vim.env.KEEP ~= '1' then
  local plans_dir = vim.fn.expand('~/.claude/plans')
  for _, p in ipairs(plan_files) do
    if vim.fs.dirname(p) == plans_dir and uv.fs_stat(p) then os.remove(p) end
  end
  -- only the transcript directory this run made for its own temporary path
  if vim.fs.dirname(real_dir) == claude_projects and vim.fs.basename(real_dir) == slug and uv.fs_stat(real_dir) then
    vim.fn.delete(real_dir, 'rf')
  end
  vim.fn.delete(tmp, 'rf')
  out('cleaned up: temporary repository, its transcript directory, ' .. #plan_files .. ' plan file(s)')
else
  out('KEEP=1: left ' .. tmp .. ' and ' .. real_dir)
end

vim.cmd(failed == 0 and alive == 0 and 'qall!' or 'cquit 1')
