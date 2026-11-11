-- Permission mode and model of a chat's session: the `<S-Tab>` mode cycle, the model picker
-- and how both read in the winbar (what Claude confirmed; `old→new` while a change waits).
local config = require('agent-ide.config')

local M = {}

local DEFAULT_MODES = { 'manual', 'acceptEdits', 'auto' }
local DEFAULT_MODELS = { 'fable', 'opus', 'sonnet', 'haiku' }

local function claude_cfg()
  local c = config.get().claude
  return type(c) == 'table' and c or {}
end

local function modes()
  local m = claude_cfg().modes
  return type(m) == 'table' and #m > 0 and m or DEFAULT_MODES
end

---Mode after `current` in `config.claude.modes`. An unknown current mode (nil: Claude has not
---reported one yet) counts as `config.claude.default_mode`, else as the list's first mode; a
---mode that is not in the list goes back to the first.
---@param current string|nil
---@return string
function M.next_mode(current)
  local list = modes()
  current = current or claude_cfg().default_mode or list[1]
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
  local mode = M.next_mode(s.mode_requested or s.mode)
  s.mode_tried = { [mode] = true } -- the modes this press asked for (a refused one is skipped)
  s:set_mode(M.claude_name(mode))
end

---Plan mode on for session `s`, or, when plan is in effect or asked for, off again: back to the
---mode before it (else `config.claude.default_mode`, else the cycle's first mode).
---@param s table Session
function M.toggle_plan(s)
  s.mode_tried = nil
  local current = s.mode_requested or s.mode
  if current ~= 'plan' then
    s.mode_before_plan = current
    s:set_mode('plan')
    return
  end
  local back = s.mode_before_plan
  if not back or back == 'plan' then back = claude_cfg().default_mode or modes()[1] end
  s.mode_before_plan = nil
  s:set_mode(M.claude_name(back))
end

-- After Claude refused `refused` from a cycle: the next mode in the list not tried yet and not
-- the one in effect, else nil.
local function skip_to(s, refused)
  local mode = refused
  for _ = 1, #modes() do
    mode = M.next_mode(mode)
    if mode == s.mode then return nil end
    if not s.mode_tried[mode] then return mode end
  end
end

-- Picker opens at the latest this long after a model fetch started (claude/models_fetch.lua).
M._wait_ms = 1500
local refreshed = false -- the stale latest list was refreshed in this Neovim

local function models() return require('agent-ide.claude.models') end

-- The list Claude gave: the session's own, else the latest one known (this Neovim or models.json).
local function known(s) return (s and s.models) or models().latest() end

local function one_line(t) return (t:gsub('%s*\n%s*', ' ')) end

---What the picker offers `s`, in order: `config.claude.models` when set (as given; entries Claude
---knows get its name and description), else Claude's list, else the four aliases.
---@param s table|nil Session
---@return table[] items { value, name?, description?, resolved? }, table[]|nil list Claude's list
function M.items(s)
  local list = known(s)
  local cfg = claude_cfg().models
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
  for i, v in ipairs(DEFAULT_MODELS) do out[i] = { value = v } end
  return out, nil
end

---Row text of `item`: `Alpha 2 — For hard problems (claude-alpha-2)`, `Default (recommended) —
---Alpha 2`, or the bare value when Claude did not name it.
---@param item table
---@param list table[]|nil Claude's list (for the model `default` stands for)
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
---last one used here; nil for Claude's own default.
---@param s table Session
---@return string|nil
function M.start_model(s) return require('agent-ide.prefs').start_model(s) end

---The item of `items` that is the current model of `s` (nil: none fits). Before Claude reported
---one, the model the session starts with (`start_model`), else `default`.
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
---@param s table Session
---@param on_pick? fun(model: string)
function M.pick_model(s, on_pick)
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

---Tell the user Claude refused the last mode or model change of `s` (session change
---`control_error`); only for the session on screen, the others keep it in their transcript.
---A mode the `<S-Tab>` cycle asked for that Claude refused is skipped: the next one is asked.
---@param s table Session
function M.control_error(s)
  local e = s.control_error
  if not e then return end
  local next_mode = e.what == 'mode' and s.mode_tried and s.mode_tried[e.value] and skip_to(s, e.value)
  if next_mode then
    s.mode_tried[next_mode] = true
    s:set_mode(M.claude_name(next_mode))
  else
    s.mode_tried = nil
  end
  if not s.visible then return end
  local msg = ('Agent-IDE: cannot switch %s to %s: %s'):format(e.what, tostring(e.value), tostring(e.error))
  vim.notify(next_mode and msg .. '; trying ' .. next_mode or msg, vim.log.levels.WARN)
end

---`claude-haiku-5-5-20261001` -> `haiku-5-5`.
local function short_model(model)
  if not model then return 'model ?' end
  return (model:gsub('^claude%-', ''):gsub('%-%d%d%d%d%d%d%d%d$', ''))
end

---How model `model` of `s` reads in the winbar and the footer: Claude's name for it, lowercased
---(`fable 5.1`), else nil.
---@param s table Session
---@param model string|nil
---@return string|nil
function M.model_name(s, model)
  return models().label(known(s), model, s.model_chosen)
end

---Winbar parts for the model and the mode of `s`. Before Claude reported a model, the one the
---session will start with (`start_model`; `default` when that is Claude's own and not known by
---name); a requested change shows as `old→new`.
---@param s table Session
---@return string model, string mode
function M.labels(s)
  local shown = s.model or M.start_model(s) or 'default'
  local model = M.model_name(s, shown) or short_model(shown)
  if s.model_requested and s.model_requested ~= shown then
    model = model .. '→' .. (M.model_name(s, s.model_requested) or s.model_requested)
  end
  local mode = 'mode:' .. (s.mode or '?')
  if s.mode_requested and s.mode_requested ~= s.mode then mode = mode .. '→' .. s.mode_requested end
  return model, mode
end

return M
