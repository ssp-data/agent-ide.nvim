-- Close a Claude that runs in a tmux pane, the way you would there: Ctrl-C twice into its pane
-- (Claude's own exit), after a confirm. `X` on a drawer row, `:AgentsCloseIdle` for every idle
-- one. The process is never signalled: the plugin only types the keys, and only into the pane
-- whose process the Claude descends from, looked up again right before the keys are sent, so
-- they never land in a pane that meanwhile runs something else. A Claude still running 5 s
-- later is left alone.
local live = require('agent-ide.live')
local session = require('agent-ide.session')

local M = {}

M._gap_ms, M._wait_ms, M._step_ms = 300, 5000, 100 -- tests shorten them

local function notify(msg, level) vim.notify('Agent-IDE: ' .. msg, level or vim.log.levels.INFO) end

local function in_tmux() return vim.env.TMUX ~= nil and vim.env.TMUX ~= '' end

local function run(cmd, cb)
  local ok = pcall(vim.system, cmd, { text = true, timeout = 2000 }, function(res) vim.schedule(function() cb(res) end) end)
  if not ok then vim.schedule(function() cb({ code = 127, stdout = '' }) end) end
end

---@param out string lines of `ps -A -o pid=,ppid=`
---@return table<integer, integer> pid -> parent pid
function M.parse_parents(out)
  local parents = {}
  for line in vim.gsplit(out or '', '\n', { plain = true }) do
    local pid, ppid = line:match('^%s*(%d+)%s+(%d+)')
    if pid then parents[tonumber(pid)] = tonumber(ppid) end
  end
  return parents
end

---@param out string lines of `tmux list-panes -a -F '#{pane_id} #{pane_pid} #{window_index}.#{pane_index}'`
---@return { id: string, pid: integer, label: string }[]
function M.parse_panes(out)
  local panes = {}
  for line in vim.gsplit(out or '', '\n', { plain = true }) do
    local id, pid, label = line:match('^(%%%d+)%s+(%d+)%s+(%S+)$')
    if id then panes[#panes + 1] = { id = id, pid = tonumber(pid), label = label } end
  end
  return panes
end

---The pane whose process is `pid` or an ancestor of it; nil when `pid` is not running (not in
---`parents`) or descends from no pane.
---@param pid integer
---@param parents table<integer, integer>
---@param panes { id: string, pid: integer, label: string }[]
---@return table|nil
function M.pane_of(pid, parents, panes)
  if parents[pid] == nil then return nil end
  local by_pid = {}
  for _, p in ipairs(panes) do by_pid[p.pid] = p end
  local seen, cur = {}, pid
  while cur and cur > 1 and not seen[cur] do
    if by_pid[cur] then return by_pid[cur] end
    seen[cur] = true
    cur = parents[cur]
  end
end

---Look up, now and asynchronously, the pane of each of `pids` (one `ps`, one `tmux list-panes`).
---@param pids integer[]
---@param cb fun(panes: table<integer, table>) pid -> pane (missing: none)
function M.lookup(pids, cb)
  run({ 'ps', '-A', '-o', 'pid=,ppid=' }, function(ps)
    if ps.code ~= 0 then return cb({}) end
    local parents = M.parse_parents(ps.stdout)
    run({ 'tmux', 'list-panes', '-a', '-F', '#{pane_id} #{pane_pid} #{window_index}.#{pane_index}' }, function(lp)
      local out = {}
      if lp.code == 0 then
        local panes = M.parse_panes(lp.stdout)
        for _, pid in ipairs(pids) do out[pid] = M.pane_of(pid, parents, panes) end
      end
      cb(out)
    end)
  end)
end

-- Whether process `pid` exists (signal 0 checks, it sends nothing).
local function exists(pid) return vim.uv.kill(pid, 0) == 0 end

-- Ctrl-C into pane `pane_id`, again `_gap_ms` later unless `pid` already ended, then wait up to
-- `_wait_ms` for `pid` to end: `cb(true)` when it did, `cb(false)` when it still runs.
local function send_exit(pane_id, pid, cb)
  run({ 'tmux', 'send-keys', '-t', pane_id, 'C-c' }, function(first)
    if first.code ~= 0 then return cb(false) end
    vim.defer_fn(function()
      if not exists(pid) then return cb(true) end
      run({ 'tmux', 'send-keys', '-t', pane_id, 'C-c' }, function()
        local t0, timer, done = vim.uv.now(), vim.uv.new_timer(), false
        timer:start(M._step_ms, M._step_ms, vim.schedule_wrap(function()
          if done then return end
          local gone = not exists(pid)
          if gone or vim.uv.now() - t0 >= M._wait_ms then
            done = true
            timer:stop()
            if not timer:is_closing() then timer:close() end
            cb(gone)
          end
        end))
      end)
    end, M._gap_ms)
  end)
end

-- One live poll now, so the drawer and the footer show what is left.
local function poll_now()
  local cfg = require('agent-ide.config').get()
  live.query({ cmd = cfg.live.cmd, interval_ms = cfg.live.interval_ms }, function()
    require('agent-ide.status').refresh()
    require('agent-ide.ui.drawer').refresh()
  end)
end

local function one_line(t) return (tostring(t or ''):gsub('[\r\n\t]+', ' ')) end

local WORD = { busy = 'working', waiting = 'waiting for input' }

local CANNOT = 'cannot reach that session (no tmux pane known here); gp jumps to it'

-- The confirms and the keys, once the pane label is known.
local function confirm_and_close(node, s, e, label)
  local id = node.session.id
  local state = require('agent-ide.ui.drawer_model').state_of(id)
  local title = one_line(node.session.title or s and s.title or 'session')
  local msg = ('Close Claude "%s" in tmux pane %s (%s)?'):format(title, label, WORD[state] or state)
  if vim.fn.confirm(msg, '&Close\n&Cancel', 2) ~= 1 then return end
  if WORD[state] and vim.fn.confirm(('It is %s; close anyway?'):format(WORD[state]), '&Close anyway\n&Cancel', 2) ~= 1 then
    return
  end
  local pid = e.pid
  M.lookup({ pid }, function(panes)
    local pane = panes[pid]
    if not pane then return notify('the pane of "' .. title .. '" is gone or runs something else; nothing sent', vim.log.levels.WARN) end
    send_exit(pane.id, pid, function(gone)
      if gone then
        notify('closed "' .. title .. '"')
      else
        notify(('"%s" still runs 5 s later (pane %s); nothing more was done'):format(title, pane.label), vim.log.levels.WARN)
      end
      poll_now()
    end)
  end)
end

---`X` on a drawer session row: close the Claude running it in a tmux pane after a confirm (a
---second one when it is working or waiting for input). The drawer's pane labels lag a poll
---behind a new process (Claude restarted in its pane); when the label is not known yet, one
---fresh lookup decides, so `X` always ends in a confirm or a notice.
---@param node table drawer session row
function M.close_row(node)
  local id = node.session.id
  local s = session.get(id)
  if s and (s.owned or s:_alive()) then return notify('this session runs in this Neovim; use x to park it') end
  local e = live.get()[id]
  if not e or not e.pid or (s and not s:_elsewhere()) then return notify('session is not running') end
  if not in_tmux() then return notify(CANNOT) end
  local label = require('agent-ide.tmux').pane_label(e.pid)
  if label then return confirm_and_close(node, s, e, label) end
  M.lookup({ e.pid }, function(panes)
    local pane = panes[e.pid]
    if not pane then return notify(CANNOT) end
    confirm_and_close(node, s, e, pane.label)
  end)
end

---`:AgentsCloseIdle`: close every Claude that is idle in a tmux pane (asked afresh), after one
---confirm with their count. `pred(id, entry)` limits them (e.g. to a project scope: a caller
---passes a predicate on the session id and its live entry `{ pid, cwd, status }`).
---@param pred? fun(id: string, entry: table): boolean
function M.close_idle(pred)
  if not in_tmux() then return notify('not in tmux; nothing to close') end
  local cfg = require('agent-ide.config').get()
  live.query({ cmd = cfg.live.cmd, interval_ms = cfg.live.interval_ms }, function(ok, reason)
    if not ok then return notify('cannot ask Claude which sessions run (' .. tostring(reason) .. ')', vim.log.levels.WARN) end
    local found = {}
    for id, e in pairs(live.get()) do
      local s = session.get(id)
      if e.pid and e.status == 'idle' and (not s or s:_elsewhere()) and (not pred or pred(id, e)) then
        found[#found + 1] = e.pid
      end
    end
    table.sort(found)
    M.lookup(found, function(panes)
      local targets = vim.tbl_filter(function(pid) return panes[pid] ~= nil end, found)
      if #targets == 0 then return notify('no idle Claude sessions in tmux panes') end
      if vim.fn.confirm(('Close %d idle Claude session(s) in tmux panes?'):format(#targets), '&Close\n&Cancel', 2) ~= 1 then
        return
      end
      M.lookup(targets, function(now)
        local left, closed, running, skipped = #targets, 0, 0, 0
        local function one_done()
          left = left - 1
          if left > 0 then return end
          local parts = { ('closed %d of %d'):format(closed, #targets) }
          if running > 0 then parts[#parts + 1] = running .. ' still running' end
          if skipped > 0 then parts[#parts + 1] = skipped .. ' skipped (pane gone or changed)' end
          notify(table.concat(parts, '; '), (running + skipped > 0) and vim.log.levels.WARN or nil)
          poll_now()
        end
        for _, pid in ipairs(targets) do
          local pane = now[pid]
          if not pane or pane.id ~= panes[pid].id then
            skipped = skipped + 1
            one_done()
          else
            send_exit(pane.id, pid, function(gone)
              if gone then closed = closed + 1 else running = running + 1 end
              one_done()
            end)
          end
        end
      end)
    end)
  end)
end

return M
