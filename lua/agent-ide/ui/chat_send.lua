-- Sending a prompt from the chat (ui/chat.lua): the prompt buffer's text, or a text given by
-- the plugin itself (a review comment sent at once), through the same gates: the plugin's own
-- commands, a session handed to native Claude, a load in progress, a fresh `claude agents`
-- check before a start, and the resume-size question. A given text is held across the
-- asynchronous gates and the prompt buffer is left alone; `done(ok)` says whether it went.
local api = vim.api
local prompt = require('agent-ide.ui.prompt')

local M = {}

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO) end
local function valid_buf(b) return b ~= nil and api.nvim_buf_is_valid(b) and api.nvim_buf_is_loaded(b) end

local function elsewhere_msg()
  return 'Agent-IDE: session is running in another Claude; use '
    .. require('agent-ide.util.keys').first('drawer', 'tmux') .. ' in the drawer to jump to it'
end
M.elsewhere_msg = elsewhere_msg

-- `done(ok)` of a given text, once.
local function finish(given, ok)
  if given and given.done then
    local d = given.done
    given.done = nil
    d(ok)
  end
end

---End the pre-send live check of `c` (its answer, a timeout, a cancel): the timer is stopped and
---closed, a late answer finds `check_n` changed and does nothing.
local function end_check(c)
  c.check_n = (c.check_n or 0) + 1
  c.checking = false
  local t = c.check_timer
  c.check_timer = nil
  if t then
    t:stop()
    if not t:is_closing() then t:close() end
  end
end

M.end_check = end_check

---Cancel a running check; the prompt text stays, `why` says so when the chat is still open.
---A given text held for the check is dropped (`done(false)`).
---@param c table Chat
---@param why string|nil
function M.cancel_check(c, why)
  if not c.checking then return end
  end_check(c)
  local given = c.check_given
  c.check_given = nil
  if why and (valid_buf(c.pbuf) or given) then notify(why, vim.log.levels.WARN) end
  finish(given, false)
end

---Hand the text to the Session (queued behind a running turn): the prompt buffer's, which is
---cleared when it went, or `given.text`, which leaves the prompt alone.
local function deliver(c, given)
  local text
  if given then
    text = given.text
  else
    if not valid_buf(c.pbuf) then return end
    text = prompt.text_to_send(api.nvim_buf_get_lines(c.pbuf, 0, -1, false))
  end
  local mark = not given and vim.b[c.pbuf].agent_ide_review or nil
  local ok, reason = c.s:send(text)
  if ok then
    if not given then
      prompt.clear(c.pbuf)
      vim.b[c.pbuf].agent_ide_review = nil
      -- the review put into this prompt went with it: its comments leave the review (a prompt
      -- rewritten by hand, without the review's first line, keeps them)
      if mark and type(mark.intro) == 'string' and text:find(mark.intro, 1, true) then
        require('agent-ide.ui.review_send').sent_from_prompt(mark)
      end
    end
  elseif reason == 'running elsewhere' then
    notify(elsewhere_msg(), vim.log.levels.WARN)
  elseif reason ~= 'empty' then
    notify('Agent-IDE: ' .. tostring(reason), vim.log.levels.WARN)
  end
  finish(given, ok)
end

---Send the prompt buffer's text of chat `c`, or `given.text` (`given.done(ok)` once it went or
---could not). Held while the history loads, so the prompt lands below it.
---@param c table Chat
---@param given? { text: string, done?: fun(ok: boolean) }
function M.send(c, given)
  local text
  if given then
    text = given.text
  else
    if not valid_buf(c.pbuf) then return end
    text = prompt.text_to_send(api.nvim_buf_get_lines(c.pbuf, 0, -1, false))
    if not text:find('%S') then return end
    -- `/model`, `/copy` alone: the plugin's own commands, nothing is sent to Claude
    local own = prompt.plugin_command(text)
    if own then
      prompt.clear(c.pbuf)
      return own(c.s)
    end
  end
  if require('agent-ide.ui.handoff').away(c.s) then
    notify('Agent-IDE: this session is open in native Claude (tmux pane); quit it there to continue here', vim.log.levels.WARN)
    return finish(given, false)
  end
  if c.loading then
    if given then
      c.pending = c.pending or {}
      c.pending[#c.pending + 1] = given
    else
      c.send_after_load = true
    end
    return
  end
  -- A send that starts Claude for a session not alive here first asks `claude agents` afresh
  -- (the cached map may be old): two Claudes must never drive one session. The text stays in
  -- the prompt meanwhile (typing goes on); what the prompt holds when the answer comes is sent.
  -- (A session the polled map lists as elsewhere is refused at once, below.)
  if not c.live_checked and c.s:needs_start() and not c.s:_elsewhere() then
    if c.checking then -- one question at a time; the answer sends the prompt
      if given then notify('Agent-IDE: not sent: checking where this session runs; send again', vim.log.levels.WARN) end
      return finish(given, false)
    end
    c.checking = true
    c.check_given = given
    local tick = valid_buf(c.pbuf) and api.nvim_buf_get_changedtick(c.pbuf) or nil
    local pbuf = c.pbuf
    c.check_n = (c.check_n or 0) + 1
    local n = c.check_n
    local cfg = require('agent-ide.config').get()
    -- One timer: after 300 ms a check still running says so; then it waits out the live command
    -- (killed after max(interval, 2 s)) plus 2 s, so a callback that never comes cannot leave the
    -- chat stuck.
    local limit = math.max(cfg.live.interval_ms, 2000) + 2000
    local guard = vim.uv.new_timer()
    c.check_timer = guard
    guard:start(300, 0, vim.schedule_wrap(function()
      if c.check_n ~= n then return end
      notify('Agent-IDE: checking where this session runs…')
      guard:start(limit - 300, 0, vim.schedule_wrap(function()
        if c.check_n ~= n then return end
        M.cancel_check(c, 'Agent-IDE: could not tell where this session runs (no answer); send again')
      end))
    end))
    require('agent-ide.live').query({ cmd = cfg.live.cmd, interval_ms = cfg.live.interval_ms }, function()
      if c.check_n ~= n then return end -- cancelled or timed out meanwhile
      c.check_given = nil
      end_check(c)
      if given then
        if c.s:_elsewhere() then
          notify(elsewhere_msg(), vim.log.levels.WARN)
          return finish(given, false)
        end
      else
        local unchanged = c.pbuf == pbuf and valid_buf(pbuf) and api.nvim_buf_get_changedtick(pbuf) == tick
        -- the prompt moved on while the question ran: what it holds now was never meant to go
        if not unchanged then
          if not valid_buf(c.pbuf) then return end
          if c.s:_elsewhere() then return notify(elsewhere_msg(), vim.log.levels.WARN) end
          notify('Agent-IDE: not sent: the prompt changed while checking; send again', vim.log.levels.WARN)
          return
        end
      end
      -- a failed question leaves the cached map to decide, as without the drawer
      c.live_checked = true
      local ok, err = pcall(M.send, c, given)
      c.live_checked = false
      if not ok then error(err, 0) end
    end)
    return
  end
  -- A send that resumes a session from its transcript reads the whole conversation again: from
  -- `context.threshold` tokens on it asks first (Send / Compact first / Cancel). The text stays
  -- in the prompt meanwhile; what changed under the question is not sent.
  if c.s:needs_start() and (c.s.sent_before or c.s:_has_transcript()) then
    if c.asking then return finish(given, false) end
    c.asking = true
    local pbuf, tick = c.pbuf, valid_buf(c.pbuf) and api.nvim_buf_get_changedtick(c.pbuf) or nil
    require('agent-ide.ui.context_ask').before_resume(c.s, function(choice)
      c.asking = false
      if choice == 'cancel' then return finish(given, false) end
      if not given then
        if c.pbuf ~= pbuf or not valid_buf(pbuf) then return end
        if api.nvim_buf_get_changedtick(pbuf) ~= tick then
          return notify('Agent-IDE: not sent: the prompt changed while checking; send again', vim.log.levels.WARN)
        end
      end
      if choice == 'compact' then
        local ok, reason = c.s:send('/compact')
        if not ok then
          notify('Agent-IDE: ' .. tostring(reason), vim.log.levels.WARN)
          return finish(given, false)
        end
      end
      deliver(c, given)
    end)
    return
  end
  deliver(c, given)
end

---Texts held while the history loaded: sent now, in order.
---@param c table Chat
function M.flush_pending(c)
  local list = c.pending
  c.pending = nil
  for _, given in ipairs(list or {}) do M.send(c, given) end
end

---Drop the texts held for a load (`done(false)` each).
---@param c table Chat
function M.drop_pending(c)
  local list = c.pending
  c.pending = nil
  for _, given in ipairs(list or {}) do finish(given, false) end
end

return M
