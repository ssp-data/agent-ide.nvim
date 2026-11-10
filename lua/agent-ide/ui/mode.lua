-- Permission mode and model of a chat's session: the `<S-Tab>` mode cycle, the model picker
-- and how both read in the winbar (what Claude confirmed; `old→new` while a change waits).
local config = require('agent-ide.config')

local M = {}

local DEFAULT_MODES = { 'manual', 'acceptEdits', 'plan', 'auto' }
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
  s:set_mode(M.claude_name(M.next_mode(s.mode_requested or s.mode)))
end

---Pick a model from `config.claude.models` for session `s`; `on_pick(model)` after a request.
---@param s table Session
---@param on_pick? fun(model: string)
function M.pick_model(s, on_pick)
  local list = claude_cfg().models
  list = type(list) == 'table' and #list > 0 and list or DEFAULT_MODELS
  vim.ui.select(list, { prompt = 'Model' }, function(choice)
    if choice and s:set_model(choice) and on_pick then on_pick(choice) end
  end)
end

---Tell the user Claude refused the last mode or model change of `s` (session change
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

---Winbar parts for the model and the mode of `s`.
---@param s table Session
---@return string model, string mode
function M.labels(s)
  local model = short_model(s.model)
  if s.model_requested and s.model_requested ~= s.model then model = model .. '→' .. s.model_requested end
  local mode = 'mode:' .. (s.mode or '?')
  if s.mode_requested and s.mode_requested ~= s.mode then mode = mode .. '→' .. s.mode_requested end
  return model, mode
end

return M
