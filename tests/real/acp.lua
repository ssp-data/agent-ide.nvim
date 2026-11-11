-- `make test-real-acp`: drives the plugin's Session against the REAL ACP agents that are
-- installed and configured (`gemini --acp`, `opencode acp`), each in its own temporary git
-- repository, with whatever model the agent's own configuration selects (REAL_ACP_GEMINI_MODEL
-- adds `-m <model>` for Gemini). Not part of `make test`. Prints one PASS / FAIL / SKIP line per
-- check and agent and nothing from the conversations. The plugin's state (its session logs)
-- goes to a temporary XDG_STATE_HOME; the agents keep the user's own login and folders.
-- REAL_ACP_AGENTS="gemini" limits the run; KEEP=1 keeps the temporary folder.
local uv = vim.uv
local TURN_MS = tonumber(vim.env.REAL_TURN_MS) or 180000

local function out(line) io.stdout:write(line .. '\n') end

local tmp = uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
tmp = uv.fs_realpath(tmp)
local saved_state = vim.env.XDG_STATE_HOME
vim.fn.mkdir(tmp .. '/state', 'p', tonumber('700', 8))

local AGENTS = {
  gemini = { kind = 'acp', cmd = { 'gemini', '--acp' }, label = 'Gemini', fs = 'cwd' },
  opencode = { kind = 'acp', cmd = { 'opencode', 'acp' }, label = 'opencode', fs = 'cwd' },
}
if vim.env.REAL_ACP_GEMINI_MODEL and vim.env.REAL_ACP_GEMINI_MODEL ~= '' then
  vim.list_extend(AGENTS.gemini.cmd, { '-m', vim.env.REAL_ACP_GEMINI_MODEL })
end
local wanted = vim.split(vim.env.REAL_ACP_AGENTS or 'gemini opencode', '%s+', { trimempty = true })

local failed = 0
local function report(agent, check, ok, note)
  local word = ok == nil and 'SKIP' or (ok and 'PASS' or 'FAIL')
  if ok == false then failed = failed + 1 end
  out(('%s  %-9s %s%s'):format(word, agent, check, note and (' (' .. note .. ')') or ''))
end

local function wait(pred, ms) return vim.wait(ms or TURN_MS, pred, 50) end

local function run(agent)
  local repo = tmp .. '/' .. agent .. '-repo'
  vim.fn.mkdir(repo, 'p')
  vim.fn.writefile({ 'a line' }, repo .. '/notes.txt')
  vim.fn.system({ 'git', '-C', repo, 'init', '-q' })
  vim.fn.system({ 'git', '-C', repo, 'add', '.' })
  vim.fn.system({ 'git', '-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'init' })

  local session = require('agent-ide.session')
  local s = session.open({ cwd = repo, agent = agent })
  local policy, asks = 'allow', 0
  local seen = {}
  local on_delta
  local function listener(x, what)
    if x ~= s then return end
    if what == 'permission' then
      for _, p in ipairs(vim.list_slice(s.pending_permissions)) do
        if not seen[p.request_id] then
          seen[p.request_id] = true
          asks = asks + 1
          vim.schedule(function() s:answer(p.request_id, policy == 'allow') end)
        end
      end
    elseif what == 'delta' and on_delta then
      local fn = on_delta
      on_delta = nil
      fn()
    end
  end
  session.on_change(listener)

  local function turn(text, ms)
    local n = #s.events
    local ok, err = s:send(text)
    if not ok then return false, tostring(err) end
    if not wait(function() return s.state ~= 'busy' and s.state ~= 'waiting' and #s.events > n end, ms) then return false, 'timeout' end
    return s.state ~= 'failed', s.state
  end
  local function texts_since(n)
    local c = 0
    for i = n + 1, #s.events do
      if s.events[i].kind == 'text' and s.events[i].text:find('%S') then c = c + 1 end
    end
    return c
  end

  -- 1. a plain answer
  local n = #s.events
  local ok, why = turn('Reply with the single word: pong')
  -- an agent that is not logged in (or whose provider is not): its error is shown; not a failure of the plugin
  local auth = false
  for i = n + 1, #s.events do
    local ev = s.events[i]
    if ev.kind == 'meta' and ev.label == 'error' and tostring(ev.text):lower():find('authenticat', 1, true) then auth = true end
  end
  if auth then
    report(agent, 'a plain answer renders', nil, 'the agent says authentication is required; its error is shown in the transcript')
  else
    report(agent, 'a plain answer renders', ok and texts_since(n) > 0, not ok and why or nil)
  end
  if not ok then
    session.off_change(listener)
    s:park()
    return report(agent, 'the remaining checks', nil, 'the first turn failed')
  end

  -- 2. an edit that is allowed
  policy, asks = 'allow', 0
  ok = turn('Create a file named made.txt in the current folder whose only content is the word ok. Do it now, no questions.')
  local made = uv.fs_stat(repo .. '/made.txt') ~= nil
  report(agent, 'an allowed edit is applied', ok and made, asks == 0 and 'the agent asked nothing' or (asks .. ' ask(s)'))

  -- 3. an edit that is denied (only meaningful when the agent asks)
  policy, asks = 'deny', 0
  ok = turn('Create a file named denied.txt in the current folder whose only content is the word no. Do it now, no questions.')
  if asks == 0 then
    report(agent, 'a denied edit leaves the file', nil, 'the agent asked nothing (its own permission settings allow it)')
  else
    report(agent, 'a denied edit leaves the file', uv.fs_stat(repo .. '/denied.txt') == nil, asks .. ' ask(s)')
  end
  policy = 'allow'

  -- 4. interrupt, then a new prompt
  if s.capabilities.interrupt == false then
    report(agent, 'interrupt ends the turn', nil, 'no interrupt capability')
  else
    local interrupted = false
    on_delta = function()
      interrupted = true
      s:interrupt()
    end
    n = #s.events
    s:send('Count from 1 to 300, one number per line, nothing else.')
    local ended = wait(function() return s.state ~= 'busy' and s.state ~= 'waiting' and #s.events > n end)
    report(agent, 'interrupt ends the turn', ended and interrupted, not interrupted and 'no text streamed before the turn ended' or nil)
    on_delta = nil
    n = #s.events
    ok = turn('Reply with the single word: again')
    report(agent, 'a prompt after the interrupt works', ok and texts_since(n) > 0)
  end

  -- 5. raw view: the JSON-RPC traffic
  local rpc = 0
  for _, e in ipairs(s.raw) do
    if e.line:find('"jsonrpc"', 1, true) then rpc = rpc + 1 end
  end
  report(agent, 'the raw view holds the JSON-RPC traffic', rpc > 4)

  -- 6. park, then history equals live from the plugin's own log
  local live = vim.tbl_filter(function(ev) return not ev.live_only end, vim.deepcopy(s.events))
  local parked = false
  s:park(function(done) parked = done end)
  wait(function() return parked and not s:_alive() end, 15000)
  report(agent, 'park stops the agent', parked and not s:_alive())
  wait(function() return not s.log or s.log:idle() end, 5000)
  local loaded = false
  s.loaded_key = nil
  s:load(function() loaded = true end)
  wait(function() return loaded end, 10000)
  local same = #s.events == #live
  for i = 1, math.min(#s.events, #live) do
    if s.events[i].kind ~= live[i].kind or s.events[i].text ~= live[i].text then same = false end
  end
  report(agent, 'history from the log equals the live events', loaded and same, ('%d events'):format(#live))

  -- 7. reopen: load the agent's session, or the documented new-session notice
  n = #s.events
  ok = turn('Reply with the single word: back')
  local notice = false
  for i = n + 1, #s.events do
    if s.events[i].kind == 'meta' and s.events[i].label == 'new session' then notice = true end
  end
  report(agent, 'a prompt after reopening works', ok and texts_since(n) > 0, notice and 'new agent session (it cannot reload)' or 'session loaded')

  session.off_change(listener)
  local done = false
  s:park(function() done = true end)
  wait(function() return done end, 15000)
end

vim.uv.os_setenv('XDG_STATE_HOME', tmp .. '/state')
vim.notify = function() end
require('agent-ide').setup({ helper = { enabled = false }, projects_dir = tmp .. '/projects', agents = AGENTS,
  sound = { waiting = false }, keeper = { enabled = false }, keys = false })
vim.fn.mkdir(tmp .. '/projects', 'p')

for _, agent in ipairs(wanted) do
  local cfg = AGENTS[agent]
  if not cfg then
    report(agent, 'known agent', false, 'not one of gemini, opencode')
  elseif vim.fn.executable(cfg.cmd[1]) ~= 1 then
    report(agent, 'all checks', nil, cfg.cmd[1] .. ' is not installed')
  else
    local ok, err = pcall(run, agent)
    if not ok then report(agent, 'run without an error', false, (tostring(err):gsub('%s+', ' '):sub(1, 160))) end
  end
end

if saved_state then vim.uv.os_setenv('XDG_STATE_HOME', saved_state) else vim.uv.os_unsetenv('XDG_STATE_HOME') end
if vim.env.KEEP ~= '1' then vim.fn.delete(tmp, 'rf') else out('kept ' .. tmp) end
out(failed == 0 and 'real ACP agents: no failures' or ('real ACP agents: ' .. failed .. ' failure(s)'))
vim.cmd(failed == 0 and 'qall!' or 'cquit 1')
