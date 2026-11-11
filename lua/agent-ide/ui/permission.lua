-- What the user sees and does when Claude needs a decision: a tool permission, an
-- AskUserQuestion, an ExitPlanMode plan approval. The choice is a `vim.ui.select`, opened only
-- for the session whose chat the user is in (its transcript or prompt window is the current
-- window), only in plain normal mode (never while typing, in a command line, an operator, or
-- visual mode), and always through `vim.schedule`. Asks of other sessions only show in their
-- transcript and in the drawer, so nothing interrupts.
local api = vim.api
local ask = require('agent-ide.transcript.ask')
local config = require('agent-ide.config')

local M = {}

local QUESTION_CANCELLED = 'User cancelled the question in Neovim'
local KEEP_PLANNING = 'User wants to keep planning'
local STALE = 'Agent-IDE: that ask is no longer open'
local BLOCKED_RETRY_MS = 200

-- session id -> { scheduled, force, cancelled = {}, echoed = {}, seen = {} } (keyed by request_id)
local per = {}
---@type { s: table, request_id: string }|nil the open select (or chain of question selects)
local active = nil
local seq = 0 -- arrival counter for `seen` ("oldest ask first" across sessions)

local function st(s)
  per[s.id] = per[s.id] or { cancelled = {}, echoed = {}, seen = {} }
  return per[s.id]
end

local function chat() return require('agent-ide.ui.chat') end

local function answer_key()
  local keys = config.get().keys
  local k = type(keys) == 'table' and type(keys.chat) == 'table' and require('agent-ide.util.keys').label(keys.chat.answer)
  return k or 'the answer key'
end

local function is_open(s, request_id)
  for _, p in ipairs(s.pending_permissions) do
    if p.request_id == request_id then return true end
  end
  return false
end

-- Where the user is ----------------------------------------------------------------------

---The current window shows the transcript or the prompt of `s`, and the transcript is shown in
---the current tab.
---@param s table Session
---@return boolean
function M.in_chat(s)
  local tbuf, pbuf = chat().buffers(s)
  if not tbuf then return false end
  local cur = api.nvim_get_current_buf()
  if cur ~= tbuf and cur ~= pbuf then return false end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(w) == tbuf then return true end
  end
  return false
end

local function typing_in_prompt(s, mode)
  local _, pbuf = chat().buffers(s)
  return api.nvim_get_current_buf() == pbuf and mode:match('^[iR]') ~= nil
end

local function first_line(v) return (tostring(v or ''):match('^[^\r\n]*')) end

---One line that fits the space left for messages, so it never causes a hit-enter prompt.
local function echo(msg)
  local room = math.max(vim.v.echospace, 1)
  if vim.fn.strdisplaywidth(msg) > room then
    local n = vim.fn.strchars(msg)
    while n > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(msg, 0, n) .. '…') > room do n = n - 1 end
    msg = vim.fn.strcharpart(msg, 0, n) .. '…'
  end
  api.nvim_echo({ { msg } }, true, {})
end

-- Choices ----------------------------------------------------------------------------------

-- VERIFIED DESTINATIONS: the `addRules` destinations whose effect was checked against real
-- Claude (docs/protocol.md, "Applying a suggestion"), with where the rule then lives. Only these
-- are offered. Add `session`, `projectSettings`, `userSettings` here once verified the same way.
local RULE_DESTINATIONS = {
  localSettings = " (saved in this project's local settings)",
}

local function rule_text(rules)
  local parts = {}
  for _, r in ipairs(type(rules) == 'table' and rules or {}) do
    if type(r) ~= 'table' or type(r.toolName) ~= 'string' then return nil end
    local content = type(r.ruleContent) == 'string' and r.ruleContent ~= '' and ('(' .. r.ruleContent .. ')') or ''
    parts[#parts + 1] = first_line(r.toolName .. content)
  end
  return #parts > 0 and table.concat(parts, ', ') or nil
end

---Extra choices for Claude's suggestions, by suggestion type. The suggestion goes back as it
---came, in the allow answer's `updatedPermissions` (verified against real Claude: a `setMode`
---switches the mode, an `addRules` rule stops the same ask from coming back). Other types
---(`addDirectories`, ...) are not offered.
local SUGGESTION_CHOICES = {
  setMode = function(s, p, sugg)
    if type(sugg.mode) ~= 'string' or sugg.destination ~= 'session' then return nil end
    local shown = sugg.mode == 'default' and 'manual' or sugg.mode
    return { label = ('Allow and switch to %s for this session'):format(shown), run = function()
      s:answer(p.request_id, true, { updated_permissions = { sugg } })
    end }
  end,
  addRules = function(s, p, sugg)
    local where, rules = RULE_DESTINATIONS[sugg.destination], rule_text(sugg.rules)
    if sugg.behavior ~= 'allow' or not where or not rules then return nil end
    return { label = 'Allow and always allow ' .. rules .. where, run = function()
      s:answer(p.request_id, true, { updated_permissions = { sugg } })
    end }
  end,
}

local function suggestion_items(s, p)
  local items = {}
  for _, sugg in ipairs(type(p.suggestions) == 'table' and p.suggestions or {}) do
    local make = type(sugg) == 'table' and SUGGESTION_CHOICES[sugg.type]
    local item = make and make(s, p, sugg)
    if item then items[#items + 1] = item end
  end
  return items
end

local function select(items, prompt, done)
  vim.ui.select(items, { prompt = prompt, format_item = function(it) return it.label end }, function(choice)
    vim.schedule(function() done(choice) end)
  end)
end

-- An ACP agent's own choices beyond the one Allow and Deny send (`allow_always`, `reject_always`,
-- …): offered with the agent's labels, answered with its option ids.
local function option_items(s, p)
  local items = {}
  local translate = require('agent-ide.agents.acp.translate')
  local used = { [translate.pick_option(p.options, true) or ''] = true, [translate.pick_option(p.options, false) or ''] = true }
  for _, o in ipairs(type(p.options) == 'table' and p.options or {}) do
    if type(o) == 'table' and o.optionId ~= nil and not used[o.optionId] then
      local allow = type(o.kind) == 'string' and o.kind:find('^allow') ~= nil
      items[#items + 1] = { label = tostring(o.name or o.optionId), run = function()
        s:answer(p.request_id, allow, { option_id = o.optionId })
      end }
    end
  end
  return items
end

---Ask the user about `p`; `finish(cancelled, choice)` once the select (chain) is over.
local function ask_permission(s, p, finish)
  local items = {
    { label = 'Allow', run = function() s:answer(p.request_id, true) end },
    { label = 'Deny', run = function() s:answer(p.request_id, false) end },
  }
  vim.list_extend(items, p.options and option_items(s, p) or suggestion_items(s, p))
  local prompt = ('%s wants to use %s: %s'):format(s.adapter.label, tostring(p.tool_name), ask.summary(p))
  if type(p.description) == 'string' and p.description ~= '' then prompt = prompt .. ' (' .. p.description .. ')' end
  select(items, prompt, function(choice) finish(choice == nil, choice) end)
end

-- Approving a plan can set the mode Claude continues in (sent with the approval).
local ACCEPT_EDITS = { type = 'setMode', mode = 'acceptEdits', destination = 'session' }

local function ask_plan(s, p, finish)
  select({
    { label = 'Approve plan', run = function() s:answer(p.request_id, true) end },
    { label = 'Approve plan and accept edits for this session', run = function()
      s:answer(p.request_id, true, { updated_permissions = { vim.deepcopy(ACCEPT_EDITS) } })
    end },
    { label = 'Keep planning', run = function() s:answer(p.request_id, false, { message = KEEP_PLANNING }) end },
  }, 'Approve Claude\'s plan?', function(choice) finish(choice == nil, choice) end)
end

local DONE = 'Done choosing'

---A multi-select question: one select per round, each offering the options not chosen yet
---(and Done once something is chosen). `done(labels)` gets the chosen labels in option order,
---or nil when a round is cancelled.
local function ask_several(q, items, done)
  local chosen = {}
  local prompt = tostring(q.question) .. ' (several: one per round, then ' .. DONE .. ')'
  local function picked()
    local out = {}
    for _, it in ipairs(items) do
      if chosen[it.value] then out[#out + 1] = it.value end
    end
    return out
  end
  local function round()
    local left, list = {}, picked()
    if #list > 0 then left[1] = { label = DONE, done = true } end
    for _, it in ipairs(items) do
      if not chosen[it.value] then left[#left + 1] = it end
    end
    if #left == 1 and left[1].done then return done(list) end -- every option chosen
    select(left, #list > 0 and (prompt .. ' — chosen: ' .. table.concat(list, ', ')) or prompt, function(choice)
      if not choice then return done(nil) end
      if choice.done then return done(picked()) end
      chosen[choice.value] = true
      round()
    end)
  end
  round()
end

---One select per question, in order; a multi-select question takes several rounds. Claude
---reads a multi-select answer as the chosen labels joined by ", ".
local function ask_questions(s, p, finish)
  local input = type(p.input) == 'table' and p.input or {}
  local questions = type(input.questions) == 'table' and input.questions or {}
  local answers = {}
  local function cancel()
    -- cancelling a question that is gone anyway needs no answer and no notice
    finish(false, is_open(s, p.request_id) and { run = function()
      s:answer(p.request_id, false, { message = QUESTION_CANCELLED })
    end } or nil)
  end
  local function step(i)
    local q = questions[i]
    if q == nil then
      local updated = vim.deepcopy(input)
      updated.answers = answers
      return finish(false, { run = function() s:answer(p.request_id, true, { updated_input = updated }) end })
    end
    local items = {}
    for _, o in ipairs(type(q) == 'table' and type(q.options) == 'table' and q.options or {}) do
      if type(o) == 'table' and type(o.label) == 'string' then
        local d = type(o.description) == 'string' and o.description ~= '' and (' — ' .. o.description) or ''
        items[#items + 1] = { label = o.label .. d, value = o.label }
      end
    end
    if #items == 0 then return cancel() end
    local function answered(value)
      if value == nil then return cancel() end
      -- the ask went away while this question was open: say so instead of asking on
      if not is_open(s, p.request_id) then return finish(false, { run = function() end }) end
      answers[tostring(q.question)] = value
      step(i + 1)
    end
    if q.multiSelect == true then
      return ask_several(q, items, function(labels) answered(labels and table.concat(labels, ', ')) end)
    end
    select(items, tostring(q.question), function(choice) answered(choice and choice.value) end)
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
  if active or not M.in_chat(s) then return end
  local p = oldest(s, force)
  if not p then return end
  local c = st(s)
  local m = api.nvim_get_mode()
  if m.mode ~= 'n' or m.blocking then
    -- not now: `ModeChanged *:n` brings us back; a blocking key wait has no mode change
    if force then c.force = true end
    if m.mode == 'n' then
      vim.defer_fn(function() M.maybe_prompt(s) end, BLOCKED_RETRY_MS)
    elseif typing_in_prompt(s, m.mode) and not c.echoed[p.request_id] then
      c.echoed[p.request_id] = true
      echo(('%s asks: %s: %s  (%s to answer)'):format(s.adapter.label, first_line(p.tool_name), first_line(ask.summary(p)), answer_key()))
    end
    return
  end
  local token = { s = s, request_id = p.request_id }
  active = token
  c.cancelled[p.request_id] = nil
  local function finish(cancelled, choice)
    if active == token then active = nil end
    if cancelled then c.cancelled[p.request_id] = true end
    if choice and choice.run then
      if is_open(s, p.request_id) then
        choice.run()
      else
        vim.notify(STALE, vim.log.levels.INFO)
      end
    end
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
---`force` (the answer key, `next_waiting`) also reopens a cancelled ask.
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

---The answer key: reopen the oldest open ask of `s` (not while its select is already open).
---@param s table Session
function M.answer(s)
  if #s.pending_permissions == 0 then
    return vim.notify('Agent-IDE: Claude is not asking anything here', vim.log.levels.INFO)
  end
  M.maybe_prompt(s, { force = true })
end

---Session change 'permission': note the arrival order, forget answered asks, then maybe open
---the select.
---@param s table Session
function M.on_permission(s)
  if s.replaying then return end -- a keeper's replay: the ask is shown once the replay is in
  local c = st(s)
  local ids = {}
  for _, p in ipairs(s.pending_permissions) do
    ids[p.request_id] = true
    if not c.seen[p.request_id] then
      seq = seq + 1
      c.seen[p.request_id] = seq
    end
  end
  for _, t in ipairs({ c.cancelled, c.echoed, c.seen }) do
    for id in pairs(t) do
      if not ids[id] then t[id] = nil end
    end
  end
  -- a select whose ask is gone no longer blocks others (its late answer is reported as stale)
  if active and active.s == s and not ids[active.request_id] then active = nil end
  M.maybe_prompt(s)
end

---Arrival order of the oldest open ask of `s` (math.huge when none).
---@param s table Session
---@return number
function M.oldest_ask(s)
  local best, seen = math.huge, st(s).seen
  for _, p in ipairs(s.pending_permissions) do best = math.min(best, seen[p.request_id] or math.huge) end
  return best
end

local augroup = api.nvim_create_augroup('agent-ide.permission', { clear = true })
local set_up = false

---Entering a chat window, or getting back to normal mode in one, opens the select for an ask
---that is waiting there. Entering a normal window outside the chat of the open select's
---session forgets that select (a picker that never reports back must not block for ever).
function M.setup()
  if set_up then return end
  set_up = true
  local function check(ev)
    local s = chat().session_of(ev and ev.buf or api.nvim_get_current_buf())
    if s then M.maybe_prompt(s) end
  end
  api.nvim_create_autocmd('WinEnter', { group = augroup, callback = function(ev)
    if active and api.nvim_win_get_config(0).relative == '' and not M.in_chat(active.s) then active = nil end
    check(ev)
  end })
  api.nvim_create_autocmd('BufEnter', { group = augroup, callback = check })
  api.nvim_create_autocmd('ModeChanged', { group = augroup, pattern = '*:n', callback = function() check() end })
end

return M
