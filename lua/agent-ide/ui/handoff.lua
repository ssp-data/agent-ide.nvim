-- Hand a chat session over to native Claude in a tmux pane, and take it back when that Claude
-- exits: park the session here, run `claude --resume <id>` in a split, then wait
-- (asynchronously) on a tmux channel that the pane signals when it ends. The pane's shell
-- signals on any exit (also when the pane is killed), the pane is polled in case even that
-- never happens, and the user can take the session back by hand. The chat reloads it from disk.
-- Outside tmux the session is parked and the command to run by hand is shown.
local M = {}

M._poll_ms = 5000 -- how often a pane that is away is looked for; tests shorten it

-- session id -> { channel, waiter (vim.system handle), timer, pane, done(), on } while native
-- Claude in a tmux pane has the session
local away = {}
local count = 0 -- hand-offs so far: every one gets its own channel
local augroup

local function notify(msg, level) vim.notify('Agent-IDE: ' .. msg, level or vim.log.levels.INFO) end

local function run(cmd, cb)
  local ok, handle = pcall(vim.system, cmd, { text = true }, function(res) vim.schedule(function() cb(res) end) end)
  if not ok then
    vim.schedule(function() cb({ code = 127, stdout = '' }) end)
    return nil
  end
  return handle
end

-- A word for a POSIX shell in double quotes; the script that holds it has no single quotes, so
-- the pane's own shell (whatever `default-shell` is) passes it to `sh -c` unchanged.
local function dq(word) return '"' .. tostring(word):gsub('[\\"$`]', '\\%0') .. '"' end

---Shell command the pane runs: `sh -c` with a script that signals `channel` whenever it exits
---(normally, or on SIGHUP/SIGTERM/SIGINT when the pane is killed), running the configured
---Claude (without the API key unless the user allows it).
---@param s table Session
---@param channel string
---@return string
function M.pane_command(s, channel)
  local cfg = require('agent-ide.config').get().claude
  local argv = vim.deepcopy(cfg.cmd)
  -- tmux starts the pane with the server's environment, whose PATH may resolve a bare
  -- `claude` to a different binary than this Neovim sees (a version manager's wrapper,
  -- say); run the one this Neovim would run
  if argv[1] and not argv[1]:find('/', 1, true) then
    local full = vim.fn.exepath(argv[1])
    if full ~= '' then argv[1] = full end
  end
  vim.list_extend(argv, { '--resume', s.id })
  local words = vim.tbl_map(dq, argv)
  if cfg.strip_api_key then table.insert(words, 1, 'env -u ANTHROPIC_API_KEY') end
  local script = ('trap %s EXIT; trap %s HUP TERM INT; %s'):format(
    dq('tmux wait-for -S ' .. channel), dq('exit 129'), table.concat(words, ' '))
  return 'sh -c ' .. vim.fn.shellescape(script)
end

---True while native Claude in a tmux pane has session `s`.
---@param s table Session
---@return boolean
function M.away(s) return away[s.id] ~= nil end

local function by_hand(s)
  return ('cd %s && claude --resume %s'):format(vim.fn.shellescape(s.cwd or '.'), s.id)
end

local function cleanup_on_leave()
  if augroup then return end
  augroup = vim.api.nvim_create_augroup('agent-ide.handoff', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = augroup, callback = function()
    for _, a in pairs(away) do
      if a.timer then a.timer:stop() end
      if a.waiter then pcall(a.waiter.kill, a.waiter, 15) end
    end
  end })
end

-- The session is back here: stop waiting and polling, tell the caller (once).
local function finish(s)
  local a = away[s.id]
  if not a then return end
  away[s.id] = nil
  if a.timer then
    a.timer:stop()
    if not a.timer:is_closing() then a.timer:close() end
  end
  if a.waiter then pcall(a.waiter.kill, a.waiter, 15) end
  a.on.back(s)
end

-- Every `_poll_ms` while away: the pane is gone without a signal (it can be killed in ways no
-- trap sees) -> the session is back.
local function poll(s, a)
  a.timer = vim.uv.new_timer()
  a.timer:start(M._poll_ms, M._poll_ms, vim.schedule_wrap(function()
    if away[s.id] ~= a or not a.pane or a.polling then return end
    a.polling = true
    run({ 'tmux', 'list-panes', '-a', '-F', '#{pane_id}' }, function(res)
      a.polling = false
      if away[s.id] ~= a or res.code ~= 0 then return end
      for line in vim.gsplit(res.stdout or '', '\n', { plain = true }) do
        if vim.trim(line) == a.pane then return end
      end
      finish(s)
    end)
  end))
end

-- `<leader>at` while away: take the session back, unless native Claude still runs it (two
-- Claudes must never drive one session). Asks `claude agents` afresh, not the cached list.
local function take_back(s)
  if vim.fn.confirm('Agent-IDE: this session is open in native Claude (tmux pane). Take it back here?',
    '&Take back\n&Cancel', 2) ~= 1 then
    return
  end
  local live = require('agent-ide.live')
  run(require('agent-ide.config').get().live.cmd, function(res)
    if not away[s.id] then return end
    if res.code ~= 0 then return notify('cannot ask Claude which sessions run; not taken back', vim.log.levels.WARN) end
    local map, readable = live.parse(res.stdout)
    if not readable then return notify('cannot read which sessions run; not taken back', vim.log.levels.WARN) end
    if map[s.id] then
      return notify('native Claude still runs this session; quit it there first', vim.log.levels.WARN)
    end
    finish(s)
  end)
end

---Park `s` (asks first when it is working) and continue it in native Claude. While it is away,
---the same call offers to take it back.
---@param s table Session
---@param on { away: fun(s: table), back: fun(s: table) } `away` once the session is handed
---  over, `back` once it is back here (the caller reloads it from disk)
function M.start(s, on)
  if away[s.id] then return take_back(s) end
  if not s.cwd or s.cwd == '' then return notify('cannot continue in native Claude: the session has no folder') end
  local in_tmux = vim.env.TMUX ~= nil and vim.env.TMUX ~= ''
  s:park(function(parked)
    if not parked or away[s.id] then return end
    if not in_tmux then return notify('parked; not in tmux, so continue it by hand: ' .. by_hand(s)) end
    count = count + 1
    local a = { channel = ('agent-ide-%s-%d-%d'):format(s.id, count, os.time()), on = on }
    away[s.id] = a
    cleanup_on_leave()
    on.away(s)
    -- wait first, so the signal cannot come before anyone listens
    a.waiter = run({ 'tmux', 'wait-for', a.channel }, function()
      if away[s.id] == a then finish(s) end
    end)
    -- beside this Neovim's pane, even when another pane is active by the time this runs
    local split = { 'tmux', 'split-window', '-h' }
    local pane = vim.env.TMUX_PANE
    if pane and pane ~= '' then vim.list_extend(split, { '-t', pane }) end
    vim.list_extend(split, { '-P', '-F', '#{pane_id}', '-c', s.cwd, M.pane_command(s, a.channel) })
    run(split, function(res)
      if away[s.id] ~= a then return end
      if res.code ~= 0 then
        notify('cannot open a tmux pane; continue by hand: ' .. by_hand(s), vim.log.levels.WARN)
        return finish(s)
      end
      a.pane = vim.trim(res.stdout or '')
      poll(s, a)
    end)
  end)
end

function M._reset()
  for id in pairs(away) do
    local a = away[id]
    if a.timer then a.timer:stop() end
    if a.waiter then pcall(a.waiter.kill, a.waiter, 15) end
  end
  away, count = {}, 0
  M._poll_ms = 5000
end

return M
