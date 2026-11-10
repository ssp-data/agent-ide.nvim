-- What the user sees and does when Claude needs a decision: a tool permission, an
-- AskUserQuestion, an ExitPlanMode plan approval. The choice is a `vim.ui.select`, opened only
-- for the session whose chat the user is in (its transcript or prompt window is the current
-- window), never while the user types in that prompt, and always through `vim.schedule`. Asks
-- of other sessions only show in their transcript and in the drawer, so nothing interrupts.
local api = vim.api
local ask = require('agent-ide.transcript.ask')
local config = require('agent-ide.config')
local session = require('agent-ide.session')

local M = {}

local QUESTION_CANCELLED = 'User cancelled the question in Neovim'
local KEEP_PLANNING = 'User wants to keep planning'

local per = {} -- session id -> { scheduled, force, cancelled = { [request_id] = true }, echoed = {} }
local active = false -- a select (or a chain of question selects) is open
local seen, seq = {}, 0 -- request_id -> order of arrival (for "oldest ask first" across sessions)

local function st(s)
  per[s.id] = per[s.id] or { cancelled = {}, echoed = {} }
  return per[s.id]
end

local function chat() return require('agent-ide.ui.chat') end

local function answer_key()
  local keys = config.get().keys
  local k = type(keys) == 'table' and type(keys.chat) == 'table' and keys.chat.answer
  return k or 'the answer key'
end

-- Where the user is ----------------------------------------------------------------------

---The current window shows the transcript or the prompt of `s`, and the transcript is shown in
---the current tab.
local function in_chat(s)
  local tbuf, pbuf = chat().buffers(s)
  if not tbuf then return false end
  local cur = api.nvim_get_current_buf()
  if cur ~= tbuf and cur ~= pbuf then return false end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(w) == tbuf then return true end
  end
  return false
end

local function typing_in_prompt(s)
  local _, pbuf = chat().buffers(s)
  local m = api.nvim_get_mode().mode
  return api.nvim_get_current_buf() == pbuf and m:match('^[iR]') ~= nil
end

local function echo(msg)
  msg = vim.fn.strcharpart(msg, 0, math.max(vim.o.columns - 12, 20)) -- never a hit-enter prompt
  api.nvim_echo({ { msg } }, true, {})
end

-- Choices ----------------------------------------------------------------------------------

local function rule_summary(sugg)
  local out = {}
  for _, r in ipairs(type(sugg.rules) == 'table' and sugg.rules or {}) do
    if type(r) == 'table' then
      local name = tostring(r.toolName or '?')
      out[#out + 1] = type(r.ruleContent) == 'string' and r.ruleContent ~= '' and (name .. '(' .. r.ruleContent .. ')') or name
    end
  end
  return table.concat(out, ', ')
end

---Extra choices for Claude's suggestions. Only kinds whose effect we can carry out are offered:
---`setMode` (allow, then `set_permission_mode`) and `addRules` (allow; see the report: the
---protocol notes record no shape for sending a rule back, so the rule itself is not sent).
local function suggestion_items(s, p)
  local items = {}
  for _, sugg in ipairs(type(p.suggestions) == 'table' and p.suggestions or {}) do
    if type(sugg) == 'table' and sugg.type == 'setMode' and type(sugg.mode) == 'string' then
      local shown = sugg.mode == 'default' and 'manual' or sugg.mode
      items[#items + 1] = { label = ('Allow and switch to %s for this session'):format(shown), run = function()
        if s:answer(p.request_id, true) then s:set_mode(sugg.mode) end
      end }
    elseif type(sugg) == 'table' and sugg.type == 'addRules' and rule_summary(sugg) ~= '' then
      items[#items + 1] = { label = 'Allow and always allow ' .. rule_summary(sugg), run = function()
        s:answer(p.request_id, true)
      end }
    end
  end
  return items
end

local function select(items, prompt, done)
  vim.ui.select(items, { prompt = prompt, format_item = function(it) return it.label end }, function(choice)
    vim.schedule(function() done(choice) end)
  end)
end

---Ask the user about `p`; `finish(cancelled)` once the select (chain) is over.
local function ask_permission(s, p, finish)
  local items = {
    { label = 'Allow', run = function() s:answer(p.request_id, true) end },
    { label = 'Deny', run = function() s:answer(p.request_id, false) end },
  }
  vim.list_extend(items, suggestion_items(s, p))
  local prompt = ('Claude wants to use %s: %s'):format(tostring(p.tool_name), ask.summary(p))
  if type(p.description) == 'string' and p.description ~= '' then prompt = prompt .. ' (' .. p.description .. ')' end
  select(items, prompt, function(choice) finish(choice == nil, choice) end)
end

local function ask_plan(s, p, finish)
  select({
    { label = 'Approve plan', run = function() s:answer(p.request_id, true) end },
    { label = 'Keep planning', run = function() s:answer(p.request_id, false, { message = KEEP_PLANNING }) end },
  }, 'Approve Claude\'s plan?', function(choice) finish(choice == nil, choice) end)
end

---One select per question, in order. Multi-select questions are answered with one choice.
local function ask_questions(s, p, finish)
  local input = type(p.input) == 'table' and p.input or {}
  local questions = type(input.questions) == 'table' and input.questions or {}
  local answers = {}
  local function cancel()
    s:answer(p.request_id, false, { message = QUESTION_CANCELLED })
    finish(false)
  end
  local function step(i)
    local q = questions[i]
    if q == nil then
      local updated = vim.deepcopy(input)
      updated.answers = answers
      s:answer(p.request_id, true, { updated_input = updated })
      return finish(false)
    end
    local items = {}
    for _, o in ipairs(type(q) == 'table' and type(q.options) == 'table' and q.options or {}) do
      if type(o) == 'table' and type(o.label) == 'string' then
        local d = type(o.description) == 'string' and o.description ~= '' and (' — ' .. o.description) or ''
        items[#items + 1] = { label = o.label .. d, value = o.label }
      end
    end
    if #items == 0 then return cancel() end
    select(items, tostring(q.question), function(choice)
      if not choice then return cancel() end
      answers[tostring(q.question)] = choice.value
      step(i + 1)
    end)
  end
  step(1)
end

-- Opening ----------------------------------------------------------------------------------

local function oldest(s, force)
  local c = st(s)
  for _, p in ipairs(s.pending_permissions) do
    if force or not c.cancelled[p.request_id] then return p end
  end
end

local function open_now(s, force)
  -- forced (the user asked): also when an earlier select never reported back
  if (active and not force) or not in_chat(s) then return end
  local p = oldest(s, force)
  if not p then return end
  local c = st(s)
  if typing_in_prompt(s) and not force then
    if not c.echoed[p.request_id] then
      c.echoed[p.request_id] = true
      echo(('Claude asks: %s: %s  (%s to answer)'):format(tostring(p.tool_name), ask.summary(p), answer_key()))
    end
    return
  end
  active = true
  c.cancelled[p.request_id] = nil
  local function finish(cancelled, choice)
    active = false
    if cancelled then c.cancelled[p.request_id] = true end
    -- an ask closed meanwhile (turn ended) is no longer answerable: `answer` returns false
    if choice and choice.run then choice.run() end
    M.maybe_prompt(s)
  end
  if p.tool_name == 'AskUserQuestion' then
    ask_questions(s, p, finish)
  elseif p.tool_name == 'ExitPlanMode' then
    ask_plan(s, p, finish)
  else
    ask_permission(s, p, finish)
  end
end

---Open the select for the oldest open ask of `s` when the user is in its chat (scheduled).
---`force` (the answer key, `next_waiting`) also reopens a cancelled ask and opens while typing.
---@param s table Session
---@param opts? { force?: boolean }
function M.maybe_prompt(s, opts)
  if #s.pending_permissions == 0 then return end
  local c = st(s)
  if opts and opts.force then c.force = true end
  if c.scheduled then return end
  c.scheduled = true
  vim.schedule(function()
    c.scheduled = false
    local force = c.force
    c.force = nil
    open_now(s, force)
  end)
end

---The answer key: reopen the oldest open ask of `s`.
---@param s table Session
function M.answer(s)
  if #s.pending_permissions == 0 then
    return vim.notify('Agent-IDE: Claude is not asking anything here', vim.log.levels.INFO)
  end
  M.maybe_prompt(s, { force = true })
end

---Session change 'permission': note the arrival order, then maybe open the select.
---@param s table Session
function M.on_permission(s)
  local ids = {}
  for _, p in ipairs(s.pending_permissions) do
    ids[p.request_id] = true
    if not seen[p.request_id] then
      seq = seq + 1
      seen[p.request_id] = seq
    end
  end
  local c = st(s)
  for id in pairs(c.cancelled) do
    if not ids[id] then c.cancelled[id] = nil end
  end
  M.maybe_prompt(s)
end

---Arrival order of the oldest open ask of `s` (math.huge when none).
---@param s table Session
---@return number
function M.oldest_ask(s)
  local best = math.huge
  for _, p in ipairs(s.pending_permissions) do best = math.min(best, seen[p.request_id] or math.huge) end
  return best
end

local augroup = api.nvim_create_augroup('agent-ide.permission', { clear = true })
local set_up = false

---Entering a chat window, or leaving insert (or any) mode for normal mode in one, opens the
---select for an ask that is waiting there.
function M.setup()
  if set_up then return end
  set_up = true
  local function check(ev)
    local s = chat().session_of(ev and ev.buf or api.nvim_get_current_buf())
    if s then M.maybe_prompt(s) end
  end
  api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, { group = augroup, callback = check })
  api.nvim_create_autocmd('ModeChanged', { group = augroup, pattern = '*:n', callback = function() check() end })
end

---Sessions that need the user, in order: waiting (oldest ask first), then failed, then done.
---Sessions waiting in another Claude come after this Neovim's waiting ones.
---@return { s: table|nil, id: string, elsewhere: boolean }[]
function M.needing()
  local live = require('agent-ide.live').get()
  local out, mine = {}, {}
  local rank = { waiting = 1, failed = 3, done = 4 }
  for i, s in ipairs(session.all()) do
    mine[s.id] = s.state ~= 'parked' or nil
    local r = rank[s.state]
    if r then out[#out + 1] = { s = s, id = s.id, elsewhere = false, r = r, t = M.oldest_ask(s), i = i } end
  end
  local n = #out
  for id, e in pairs(live) do
    if not mine[id] and e.status == 'waiting' then
      n = n + 1
      out[#out + 1] = { id = id, elsewhere = true, r = 2, t = 0, i = n, pid = e.pid }
    end
  end
  table.sort(out, function(a, b)
    if a.r ~= b.r then return a.r < b.r end
    if a.t ~= b.t then return a.t < b.t end
    if a.i ~= b.i then return a.i < b.i end
    return a.id < b.id
  end)
  return out
end

---Go to the next session that needs the user (see `needing`): its chat in the Agents tab, with
---the select for its oldest ask; a session waiting in another Claude is jumped to in tmux.
function M.next_waiting()
  local list = M.needing()
  if #list == 0 then return vim.notify('Agent-IDE: nothing needs you', vim.log.levels.INFO) end
  local pick = list[1]
  local cur = chat().current()
  if cur and pick.s == cur and in_chat(cur) and list[2] then pick = list[2] end
  if pick.elsewhere then
    if vim.env.TMUX and vim.env.TMUX ~= '' and pick.pid then
      return require('agent-ide.tmux').jump_to_pid(pick.pid, function(ok, reason)
        if not ok then vim.notify('Agent-IDE: cannot jump (' .. tostring(reason) .. ')', vim.log.levels.INFO) end
      end)
    end
    return vim.notify('Agent-IDE: a session waits in another Claude', vim.log.levels.INFO)
  end
  local drawer = require('agent-ide.ui.drawer')
  local tab = drawer.state().tab
  if not tab then
    require('agent-ide').toggle()
  elseif api.nvim_get_current_tabpage() ~= tab then
    api.nvim_set_current_tabpage(tab)
  end
  chat().open(pick.s, chat().project_of(pick.s))
  M.maybe_prompt(pick.s, { force = true })
end

return M
