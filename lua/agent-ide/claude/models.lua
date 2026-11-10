-- The models Claude Code offers, as its `initialize` answer lists them (docs/protocol.md): one
-- list per session (`s.models`) and one plugin-wide "latest list", kept across restarts in
-- stdpath('state')/agent-ide/models.json:
-- { "version": 1, "at": <epoch>, "claude_version": "x.y.z",
--   "models": [ { "value", "name", "description", "resolved" } ] }.
-- Only those four fields of a model are kept. Read once at setup (asynchronously); written only
-- when the list (or Claude's version) changed, or to renew a copy older than STALE_DAYS.
local jsonfile = require('agent-ide.util.jsonfile')

local M = {}

M.STALE_DAYS = 7

local latest -- { at, claude_version, models } or nil

local function file() return vim.fn.stdpath('state') .. '/agent-ide/models.json' end

local function str(v) return type(v) == 'string' and v ~= '' and v or nil end

---Our list from the `models` of an `initialize` answer (or of models.json): entries without a
---`value` are left out; nil when nothing is left.
---@param raw any
---@return table[]|nil list of { value, name?, description?, resolved? }
function M.normalize(raw)
  if type(raw) ~= 'table' then return nil end
  local out = {}
  for _, m in ipairs(raw) do
    if type(m) == 'table' and str(m.value) then
      out[#out + 1] = {
        value = m.value,
        name = str(m.displayName) or str(m.name),
        description = str(m.description),
        resolved = str(m.resolvedModel) or str(m.resolved),
      }
    end
  end
  return #out > 0 and out or nil
end

local function take(data)
  if type(data) ~= 'table' then return nil end
  local list = M.normalize(data.models)
  if not list then return nil end
  return { at = tonumber(data.at) or 0, claude_version = str(data.claude_version), models = list }
end

---Read models.json, asynchronously (setup). A list recorded meanwhile wins.
---@param cb? fun()
function M.load(cb)
  jsonfile.read_async(file(), function(data)
    if not latest then latest = take(data) end
    if cb then cb() end
  end)
end

local function write(l)
  local new, err = jsonfile.write(file(), { version = 1, at = l.at, claude_version = l.claude_version, models = l.models })
  if not new then vim.notify('Agent-IDE: cannot save the model list: ' .. tostring(err), vim.log.levels.WARN) end
end

---Claude listed `list` (normalized); `claude_version` from the same answer.
---@param list table[]|nil
---@param claude_version string|nil
function M.record(list, claude_version)
  if not list then return end
  local now = os.time()
  local old = latest
  latest = { at = now, claude_version = str(claude_version) or (old and old.claude_version), models = vim.deepcopy(list) }
  local same = old and vim.deep_equal(old.models, latest.models) and old.claude_version == latest.claude_version
  if same and now - old.at < M.STALE_DAYS * 86400 then
    latest.at = old.at -- unchanged and recent: the file is not rewritten
    return
  end
  local entry = latest
  vim.schedule(function() write(entry) end)
end

---The latest list known (this Neovim, else models.json); nil when none.
---@return table[]|nil list, table|nil info { at, claude_version }
function M.latest()
  if not latest then return nil end
  return latest.models, { at = latest.at, claude_version = latest.claude_version }
end

---The latest list is older than STALE_DAYS or from another Claude Code version than `installed`
---(false when there is none: that case is a fetch of its own, see ui/mode.lua).
---@param installed string|nil
---@return boolean
function M.stale(installed)
  if not latest then return false end
  if os.time() - latest.at > M.STALE_DAYS * 86400 then return true end
  return installed ~= nil and latest.claude_version ~= nil and installed ~= latest.claude_version
end

-- `claude-x-1-20250101`, `claude-x-1[1m]` -> `claude-x-1`.
local function base(id) return (id:gsub('%[.-%]$', ''):gsub('%-%d%d%d%d%d%d%d%d$', '')) end

---The entry of `list` for the model id `model` (an alias such as `sonnet`, a full id, possibly
---dated or with a `[1m]`-style suffix). Several can fit (`default` and `fable` both resolve to
---the same id): `chosen` (the value the user picked) wins, then an exact `value`, then the first
---in Claude's order.
---@param list table[]|nil
---@param model string|nil
---@param chosen string|nil
---@return table|nil
function M.match(list, model, chosen)
  if not list or type(model) ~= 'string' or model == '' then return nil end
  local b = base(model)
  local fits = {}
  for _, e in ipairs(list) do
    if e.value == model then return e end
    if e.value == b or e.resolved == model or (e.resolved and base(e.resolved) == b) or base(e.value) == b then
      fits[#fits + 1] = e
    end
  end
  for _, e in ipairs(fits) do
    if e.value == chosen then return e end
  end
  return fits[1]
end

---The entry other than `default` that resolves to the same model as `e` (for `default`'s name).
---@param list table[]
---@param e table
---@return table|nil
function M.same_as(list, e)
  if not e.resolved then return nil end
  for _, x in ipairs(list) do
    if x ~= e and x.value ~= 'default' and (x.resolved == e.resolved or x.value == e.resolved) then return x end
  end
end

---Display name of model `model` for a winbar or a footer, lowercased (`fable 5.1`); `default`
---reads as the model it stands for. Nil when `list` does not know it.
---@param list table[]|nil
---@param model string|nil
---@param chosen string|nil
---@return string|nil
function M.label(list, model, chosen)
  local e = M.match(list, model, chosen)
  if not e then return nil end
  if e.value == 'default' then e = M.same_as(list, e) or e end
  return e.name and e.name:lower() or nil
end

---Test only: forget the list (the file stays).
function M._reset() latest = nil end

M._file = file

return M
