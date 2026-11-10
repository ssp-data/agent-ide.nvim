-- Close a Claude that runs in a tmux pane, the way you would there: Ctrl-C twice into its pane
-- (Claude's own exit). `X` on a drawer row, `:AgentsCloseIdle` for every idle one. The order is
-- always: ask (synchronously, on the key or command, never from a callback), then ask Claude
-- afresh which sessions run (`live.query`) and keep only those still run by the same process
-- (and still idle where idle was what you confirmed), then verify each pane (ui/tmux_verify.lua:
-- that Claude is the pane's foreground program, the pane in no mode and not synchronized), then
-- type the keys. The process is never signalled. A Claude still running 5 s later is left alone.
local live = require('agent-ide.live')
local session = require('agent-ide.session')
local verify = require('agent-ide.ui.tmux_verify')

local M = {}

M._gap_ms, M._wait_ms, M._step_ms = 300, 5000, 100 -- tests shorten them

local function notify(msg, level) vim.notify('Agent-IDE: ' .. msg, level or vim.log.levels.INFO) end

local function in_tmux() return vim.env.TMUX ~= nil and vim.env.TMUX ~= '' end

local function run(cmd, cb)
  local ok = pcall(vim.system, cmd, { text = true, timeout = 2000 }, function(res) vim.schedule(function() cb(res) end) end)
  if not ok then vim.schedule(function() cb({ code = 127, stdout = '' }) end) end
end

M.parse_ps, M.parse_panes, M.verify, M.lookup = verify.parse_ps, verify.parse_panes, verify.verify, verify.lookup

-- Whether process `pid` exists (signal 0 checks, it sends nothing). Only "no such process"
-- means gone: a process of another user answers "not permitted" and still runs.
local function exists(pid)
  local ok, _, name = vim.uv.kill(pid, 0)
  return ok == 0 or name ~= 'ESRCH'
end
M._exists = exists

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

local function query(cb)
  local cfg = require('agent-ide.config').get()
  live.query({ cmd = cfg.live.cmd, interval_ms = cfg.live.interval_ms }, cb)
end

-- One live poll now, so the drawer and the footer show what is left.
local function poll_now()
  query(function()
    require('agent-ide.status').refresh()
    require('agent-ide.ui.drawer').refresh()
  end)
end

local function one_line(t) return (tostring(t or ''):gsub('[\r\n\t]+', ' ')) end

local WORD = { busy = 'working', waiting = 'waiting for input' }
local LOST, LOSTS = 'Text typed in its input box is lost.', 'Text typed in their input boxes is lost.'

---`X` on a drawer session row: close the Claude running it in a tmux pane after a confirm (a
---second one when it is working or waiting for input). The drawer's pane label may lag a poll
---behind a restarted Claude; the confirm then says "its tmux pane", and the check afterwards
---decides. `X` always ends in a confirm or a notice.
---@param node table drawer session row
function M.close_row(node)
  local id = node.session.id
  local s = session.get(id)
  if s and (s.owned or s:_alive()) then return notify('this session runs in this Neovim; use x to park it') end
  local e = live.get()[id]
  if not e or not e.pid or (s and not s:_elsewhere()) then return notify('session is not running') end
  if not in_tmux() then return notify('cannot reach that session (not in tmux); gp jumps to it') end
  local label = require('agent-ide.tmux').pane_label(e.pid)
  local state = require('agent-ide.ui.drawer_model').state_of(id)
  local title = one_line(node.session.title or s and s.title or 'session')
  local where = label and ('tmux pane ' .. label) or 'its tmux pane'
  local msg = ('Close Claude "%s" in %s (%s)? %s'):format(title, where, WORD[state] or state, LOST)
  if vim.fn.confirm(msg, '&Close\n&Cancel', 2) ~= 1 then return end
  if WORD[state] and vim.fn.confirm(('It is %s; close anyway?'):format(WORD[state]), '&Close anyway\n&Cancel', 2) ~= 1 then
    return
  end
  local pid, want_idle = e.pid, not WORD[state]
  local function skip(why) notify(('"%s": nothing sent; %s'):format(title, why), vim.log.levels.WARN) end
  query(function(ok, reason)
    if not ok then return skip('cannot ask Claude which sessions run (' .. tostring(reason) .. ')') end
    local now = live.get()[id]
    if not now or now.pid ~= pid then return skip('it no longer runs') end
    if want_idle and now.status ~= 'idle' then return skip('it started working') end
    verify.lookup({ pid }, function(res)
      local r = res[pid] or { reason = 'cannot verify its pane' }
      if not r.pane then return skip(r.reason) end
      send_exit(r.pane.id, pid, function(gone)
        if gone then
          notify('closed "' .. title .. '"')
        else
          notify(('"%s" still runs 5 s later (pane %s); nothing more was done'):format(title, r.pane.label), vim.log.levels.WARN)
        end
        poll_now()
      end)
    end)
  end)
end

-- Idle sessions running elsewhere in `map` that `pred` keeps: id -> pid.
local function idle_in(map, pred)
  local out, n = {}, 0
  for id, e in pairs(map or {}) do
    local s = session.get(id)
    if e.pid and e.status == 'idle' and (not s or s:_elsewhere()) and (not pred or pred(id, e)) then
      out[id], n = e.pid, n + 1
    end
  end
  return out, n
end

---`:AgentsCloseIdle`: close every Claude that is idle in a tmux pane, after one confirm (with
---their count when the live map is current). `pred(id, entry)` limits them (e.g. to a project
---scope: a predicate on the session id and its live entry `{ pid, cwd, status }`); `of` names
---that limit in the confirm and the notices (`... session(s) of <of> in tmux panes`).
---@param pred? fun(id: string, entry: table): boolean
---@param of? string
function M.close_idle(pred, of)
  local where = (of and (' of ' .. one_line(of)) or '') .. ' in tmux panes'
  if not in_tmux() then return notify('not in tmux; nothing to close') end
  local fresh = live.fresh()
  local known = next(fresh) ~= nil or live.active() and not live.stale()
  local asked, n = idle_in(fresh, pred)
  if known and n == 0 then return notify('no idle Claude sessions' .. where) end
  local msg = known and ('Close %d idle Claude session(s)%s? %s'):format(n, where, LOSTS)
    or ('Close the idle Claude sessions%s? %s'):format(where, LOSTS)
  if vim.fn.confirm(msg, '&Close\n&Cancel', 2) ~= 1 then return end
  query(function(ok, reason)
    if not ok then return notify('cannot ask Claude which sessions run (' .. tostring(reason) .. '); nothing sent', vim.log.levels.WARN) end
    local now = idle_in(live.get(), pred)
    local targets, skipped = {}, {}
    local function skip(why) skipped[why] = (skipped[why] or 0) + 1 end
    if known then
      for id, pid in pairs(asked) do
        local e = live.get()[id]
        if now[id] == pid then
          targets[#targets + 1] = pid
        else
          skip((e and e.pid == pid) and 'no longer idle' or 'no longer running')
        end
      end
    else
      for _, pid in pairs(now) do targets[#targets + 1] = pid end
    end
    table.sort(targets)
    local function summary(closed, running, total)
      local parts = { ('closed %d of %d'):format(closed, total) }
      if running > 0 then parts[#parts + 1] = running .. ' still running' end
      local whys = vim.tbl_keys(skipped)
      table.sort(whys)
      for _, why in ipairs(whys) do parts[#parts + 1] = ('%d skipped (%s)'):format(skipped[why], why) end
      notify(table.concat(parts, '; '), (running > 0 or #whys > 0) and vim.log.levels.WARN or nil)
      poll_now()
    end
    local total = #targets + (function() local c = 0 for _, k in pairs(skipped) do c = c + k end return c end)()
    if #targets == 0 then
      if total == 0 then return notify('no idle Claude sessions' .. where) end
      return summary(0, 0, total)
    end
    verify.lookup(targets, function(res)
      local left, closed, running = #targets, 0, 0
      local function one_done()
        left = left - 1
        if left == 0 then summary(closed, running, total) end
      end
      for _, pid in ipairs(targets) do
        local r = res[pid] or { reason = 'cannot verify its pane' }
        if not r.pane then
          skip(r.reason)
          one_done()
        else
          send_exit(r.pane.id, pid, function(gone)
            if gone then closed = closed + 1 else running = running + 1 end
            one_done()
          end)
        end
      end
    end)
  end)
end

---`:AgentsCloseIdle[!]`: in project scope only the scoped project's sessions (by the live entry's
---folder); with the bang, or in 'all' scope, every project.
---@param bang boolean
function M.command(bang)
  local scope = require('agent-ide.scope')
  local p = not bang and scope.project()
  if not p then return M.close_idle() end
  M.close_idle(function(_, e) return scope.matches(e) end, p.name)
end

return M
