-- Permission mode and model of a chat's session: the `<S-Tab>` mode cycle, the model picker
-- and how both read in the winbar (what the agent confirmed; `old→new` while a change waits).
-- Claude's modes come from `config.claude.modes` and its models from claude/models.lua; another
-- agent's come from what it listed at its start (`s.modes`, `s.models`), and a session whose
-- agent offers neither gets a notice instead of a control that does nothing.
local config = require('agent-ide.config')

local M = {}

local DEFAULT_MODES = { 'manual', 'acceptEdits', 'plan', 'auto' }
local DEFAULT_MODELS = { 'fable', 'opus', 'sonnet', 'haiku' }

local function claude_cfg()
  local c = config.get().claude
  return type(c) == 'table' and c or {}
end

local function is_claude(s) return s == nil or s.agent == nil or s.agent == 'claude' end

---The agent of `s` offers `cap`: true; else a one-line notice naming `feature` and false.
---@param s table Session
---@param cap string a capability name
---@param feature string what the user asked for
---@return boolean
function M.offers(s, cap, feature)
  if s.capabilities == nil or s.capabilities[cap] then return true end
  vim.notify(('Agent-IDE: %s does not offer %s through ACP'):format(s.adapter and s.adapter.label or s.agent, feature),
    vim.log.levels.INFO)
  return false
end

-- The modes `s` cycles through: Claude's from the config, another agent's as it listed them.
local function modes(s)
  if not is_claude(s) then
    return vim.tbl_map(function(m) return m.id end, type(s.modes) == 'table' and s.modes or {})
  end
  local m = claude_cfg().modes
  return type(m) == 'table' and #m > 0 and m or DEFAULT_MODES
end

---Mode after `current` in the list of `s` (`config.claude.modes` for Claude). An unknown current
---mode (nil: the agent has not reported one yet) counts as `config.claude.default_mode` for
---Claude, else as the list's first mode; a mode that is not in the list goes back to the first.
---@param current string|nil
---@param s? table Session (nil: Claude)
---@return string|nil nil when the agent listed no modes
function M.next_mode(current, s)
  local list = modes(s)
  if #list == 0 then return nil end
  current = current or (is_claude(s) and claude_cfg().default_mode) or list[1]
  for i, m in ipairs(list) do
    if m == current then return list[i % #list + 1] end
  end
  return list[1]
end

---The name Claude knows a plugin mode by (`manual` is Claude's `default`).
---@param mode string
---@return string
function M.claude_name(mode) return mode == 'manual' and 'default' or mode end

---Request the next mode for session `s` (sent at the next start when no process runs).
---@param s table Session
function M.cycle(s)
  if not M.offers(s, 'modes', 'permission modes') then return end
  local nxt = M.next_mode(s.mode_requested or s.mode, s)
  if not nxt then return vim.notify('Agent-IDE: the agent listed no modes', vim.log.levels.INFO) end
  s:set_mode(is_claude(s) and M.claude_name(nxt) or nxt)
end

-- Picker opens at the latest this long after a model fetch started (claude/models_fetch.lua).
M._wait_ms = 1500
local refreshed = false -- the stale latest list was refreshed in this Neovim

local function models() return require('agent-ide.claude.models') end

-- The list the agent gave: the session's own, else (Claude) the latest one known (this Neovim
-- or models.json).
local function known(s)
  if s and s.models then return s.models end
  if is_claude(s) then return models().latest() end
  return nil
end

local function one_line(t) return (t:gsub('%s*\n%s*', ' ')) end

---What the picker offers `s`, in order: `config.claude.models` when set (Claude; as given,
---entries Claude knows get its name and description), else the agent's list, else (Claude) the
---four aliases.
---@param s table|nil Session
---@return table[] items { value, name?, description?, resolved? }, table[]|nil list the agent's list
function M.items(s)
  local list = known(s)
  local cfg = is_claude(s) and claude_cfg().models or nil
  local out = {}
  if type(cfg) == 'table' and #cfg > 0 then
    for _, v in ipairs(cfg) do
      if type(v) == 'string' and v ~= '' then
        local e = models().match(list, v)
        if e and e.value == 'default' and v ~= 'default' then e = models().same_as(list, e) or e end
        out[#out + 1] = e and vim.tbl_extend('force', e, { value = v }) or { value = v }
      end
    end
    if #out > 0 then return out, list end
  end
  if list then return list, list end
  if not is_claude(s) then return {}, nil end
  for i, v in ipairs(DEFAULT_MODELS) do out[i] = { value = v } end
  return out, nil
end

---Row text of `item`: `Alpha 2 — For hard problems (claude-alpha-2)`, `Default (recommended) —
---Alpha 2`, or the bare value when the agent did not name it.
---@param item table
---@param list table[]|nil the agent's list (for the model `default` stands for)
---@return string
function M.row_text(item, list)
  if not item.name then return item.value end
  local t = one_line(item.name)
  if item.value == 'default' then
    local same = list and models().same_as(list, item)
    local what = same and same.name or item.resolved
    return what and (t .. ' — ' .. one_line(what)) or t
  end
  if item.description then t = t .. ' — ' .. one_line(item.description) end
  if item.resolved then t = t .. ' (' .. item.resolved .. ')' end
  return t
end

---The model `s` starts with (prefs.lua): asked for or picked, else `claude.model`, else the
---last one used here; nil for the agent's own default.
---@param s table Session
---@return string|nil
function M.start_model(s) return require('agent-ide.prefs').start_model(s) end

---The item of `items` that is the current model of `s` (nil: none fits). Before the agent
---reported one, the model the session starts with (`start_model`), else `default`.
local function current(s, items)
  local chosen = M.start_model(s)
  return models().match(items, s.model or chosen or 'default', s.model_chosen or chosen)
end

---Picker rows of `s` as shown: `● ` before the current model, two spaces before the others.
---@param s table Session
---@return string[]
function M.rows(s)
  local items, list = M.items(s)
  local cur = current(s, items)
  local out = {}
  for i, it in ipairs(items) do out[i] = (it == cur and '● ' or '  ') .. M.row_text(it, list) end
  return out
end

local function open_picker(s, on_pick)
  local items, list = M.items(s)
  local cur = current(s, items)
  vim.ui.select(items, {
    prompt = 'Model',
    format_item = function(it) return (it == cur and '● ' or '  ') .. M.row_text(it, list) end,
  }, function(choice)
    if choice and s:set_model(choice.value) and on_pick then on_pick(choice.value) end
  end)
end

---Pick a model for session `s`; `on_pick(value)` after a request. Without any list from Claude
---(a fresh install) and none configured, the list is fetched first: the picker opens when it is in or after
---`_wait_ms`, whichever comes first, with what is known then (unless the user typed meanwhile).
---A latest list that is stale (claude/models.lua) is refreshed in the background, once per Neovim.
---Another agent's picker shows the list it gave at its start (a notice before that).
---@param s table Session
---@param on_pick? fun(model: string)
function M.pick_model(s, on_pick)
  if not M.offers(s, 'models', 'a choice of models') then return end
  if not is_claude(s) then
    if not known(s) then return vim.notify('Agent-IDE: the agent has not listed its models yet', vim.log.levels.INFO) end
    return open_picker(s, on_pick)
  end
  local fetch = require('agent-ide.claude.models_fetch')
  local cfg = claude_cfg().models
  if known(s) or (type(cfg) == 'table' and #cfg > 0) then
    if not refreshed and not fetch.busy() and models().stale(require('agent-ide.claude.version').found()) then
      refreshed = true
      fetch.fetch()
    end
    return open_picker(s, on_pick)
  end
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local tick, opened = vim.b[buf].changedtick, false
  local function open()
    if opened then return end
    opened = true
    -- never pop up over typing: the user moved on or typed meanwhile
    if vim.api.nvim_get_current_win() ~= win or not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].changedtick ~= tick then return end
    open_picker(s, on_pick)
  end
  fetch.fetch(function() open() end)
  vim.defer_fn(open, M._wait_ms)
end

---Test only: allow the background refresh again.
function M._reset() refreshed = false end

---Tell the user the agent refused the last mode or model change of `s` (session change
---`control_error`); only for the session on screen, the others keep it in their transcript.
---@param s table Session
function M.control_error(s)
  local e = s.control_error
  if not e or not s.visible then return end
  vim.notify(('Agent-IDE: cannot switch %s to %s: %s'):format(e.what, tostring(e.value), tostring(e.error)), vim.log.levels.WARN)
end

---`claude-haiku-5-5-20261001` -> `haiku-5-5`.
local function short_model(model)
  if not model then return 'model ?' end
  return (model:gsub('^claude%-', ''):gsub('%-%d%d%d%d%d%d%d%d$', ''))
end

---How model `model` of `s` reads in the winbar and the footer: the agent's name for it,
---lowercased (`fable 5.1`), else nil.
---@param s table Session
---@param model string|nil
---@return string|nil
function M.model_name(s, model)
  return models().label(known(s), model, s.model_chosen)
end

---Winbar parts for the model and the mode of `s`. Before the agent reported a model, the one
---the session will start with (`start_model`; `default` when that is Claude's own and not
---known by name; nil for another agent that named none); a requested change shows as `old→new`.
---@param s table Session
---@return string|nil model, string mode
function M.labels(s)
  local shown = s.model or M.start_model(s) or (is_claude(s) and 'default' or nil)
  local model = shown and (M.model_name(s, shown) or short_model(shown)) or nil
  if model and s.model_requested and s.model_requested ~= shown then
    model = model .. '→' .. (M.model_name(s, s.model_requested) or s.model_requested)
  end
  local mode = 'mode:' .. (s.mode or '?')
  if s.mode_requested and s.mode_requested ~= s.mode then mode = mode .. '→' .. s.mode_requested end
  return model, mode
end

return M
