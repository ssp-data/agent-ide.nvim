-- Questions about the size of a session's conversation before it costs tokens, and the
-- /compact key. A send that resumes a session from disk reads its whole conversation again (in
-- full after a pause, when the prompt cache is cold); parking a session you will come back to
-- is the moment to compact, so that resume reads less. Both only from `context.threshold`
-- tokens on, and each can be turned off (`context.confirm_resume`, `context.compact_before_park`).
local usage = require('agent-ide.claude.usage')

local M = {}

local function cfg()
  local c = require('agent-ide.config').get().context
  return type(c) == 'table' and c or {}
end

local function threshold()
  local t = cfg().threshold
  return type(t) == 'number' and t or nil
end

local function notify(msg, level) vim.notify('Agent-IDE: ' .. msg, level or vim.log.levels.INFO) end

---Before a send that would start Claude for `s` from its transcript: `cb('send' | 'compact' |
---'cancel')` on the main loop ('compact': /compact goes first, the prompt after it). Without a
---question (below the threshold, turned off, or the size unknown): 'send'.
---@param s table Session
---@param cb fun(choice: 'send'|'compact'|'cancel')
function M.before_resume(s, cb)
  local t = threshold()
  if not t or cfg().confirm_resume == false then return vim.schedule(function() cb('send') end) end
  require('agent-ide.session.context').refresh(s, function(tokens)
    if not tokens or tokens < t then return cb('send') end
    local choice = vim.fn.confirm(
      ('Resuming this session reads its whole conversation again: ~%s tokens (uncached after a pause).\n'
        .. 'Compact first costs that same read once; every turn after it is smaller.'):format(usage.fmt(tokens)),
      '&Send\n&Compact first\nCa&ncel', 1)
    cb(choice == 1 and 'send' or choice == 2 and 'compact' or 'cancel')
  end)
end

---Before parking `s`: `cb('park' | 'compact' | 'cancel')`, at once. The question comes for a
---session between turns whose size is known and above the threshold; `opts.no_ask` skips it.
---@param s table Session
---@param opts? { no_ask?: boolean }
---@param cb fun(choice: 'park'|'compact'|'cancel')
function M.before_park(s, opts, cb)
  local t = threshold()
  local tokens = s.context_tokens
  local between = s.state ~= 'busy' and s.state ~= 'waiting'
  if (opts and opts.no_ask) or not t or cfg().compact_before_park == false or not between
    or not s:_alive() or not tokens or tokens < t then
    return cb('park')
  end
  local choice = vim.fn.confirm(
    ('This session holds ~%s tokens of conversation. Compact it before parking, so the next resume reads less?')
      :format(usage.fmt(tokens)),
    '&Park now\n&Compact, then park\nCa&ncel', 1)
  cb(choice == 1 and 'park' or choice == 2 and 'compact' or 'cancel')
end

-- A session marked `park_after_compact` is parked when its compaction turn ends; an
-- interrupt (ui/chat.lua), a failure or a park meanwhile drops the mark.
local watching = false
local function watch()
  if watching then return end
  watching = true
  require('agent-ide.session').on_change(function(s, what)
    if what ~= 'state' or not s.park_after_compact then return end
    if s.state == 'idle' or s.state == 'done' then
      s.park_after_compact = nil
      vim.schedule(function()
        if s.state == 'idle' or s.state == 'done' then require('agent-ide.ui.chat').park(s, { no_ask = true }) end
      end)
    elseif s.state == 'parked' or s.state == 'failed' then
      s.park_after_compact = nil
    end
  end)
end

---Send Claude's own /compact to `s`: one request that reads the whole conversation and
---summarizes it; every turn after it is smaller. Queued behind a running turn; a session
---without a process is resumed for it. `opts.then_park`: park once the compaction has ended.
---@param s table Session
---@param opts? { then_park?: boolean }
function M.compact(s, opts)
  if require('agent-ide.ui.handoff').away(s) then
    return notify('cannot compact: the session is open in native Claude (tmux pane)', vim.log.levels.WARN)
  end
  local running = s.state == 'busy' or s.state == 'waiting'
  local ok, reason = s:send('/compact')
  if not ok then return notify('cannot compact: ' .. tostring(reason), vim.log.levels.WARN) end
  if opts and opts.then_park then
    s.park_after_compact = true
    watch()
  end
  notify(running and '/compact queued behind the running turn' or 'compacting the conversation…')
end

return M
