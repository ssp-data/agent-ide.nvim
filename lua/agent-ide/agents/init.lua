-- The agents a Session can run: `claude` (built in, agents/claude.lua) and the ACP agents of
-- `config.agents` (agents/acp/adapter.lua). An adapter starts the agent's process for a
-- Session and turns its wire into the shared Actions (session/actions.lua); see the Adapter
-- table in docs/superpowers/plans/2026-11-10-part-6-other-agents.md.
local M = {}

local acp = {} -- name -> adapter, one per configured ACP agent (dropped when the config changes)
local acp_cfg -- the `agents` table the cache was built from

local function cfg()
  local c = require('agent-ide.config').get()
  return type(c.agents) == 'table' and c.agents or {}, c.default_agent
end

---The adapter of agent `name` (nil: the default agent), or nil and why there is none.
---@param name? string
---@return table|nil adapter, string|nil err
function M.get(name)
  name = name or M.default()
  if name == 'claude' then return require('agent-ide.agents.claude') end
  local all = cfg()
  if all ~= acp_cfg then acp, acp_cfg = {}, all end
  local c = all[name]
  if type(c) ~= 'table' then return nil, ('unknown agent "%s" (not in config.agents)'):format(tostring(name)) end
  if c.kind ~= 'acp' then return nil, ('agent "%s" has no supported kind (expected kind = "acp")'):format(name) end
  if not acp[name] then acp[name] = require('agent-ide.agents.acp.adapter').new(name, c) end
  return acp[name]
end

---The agent new sessions start with (`config.default_agent`, else `claude`).
---@return string
function M.default()
  local _, d = cfg()
  return type(d) == 'string' and d ~= '' and d or 'claude'
end

---Every configured agent name: `claude` first, the others sorted.
---@return string[]
function M.names()
  local all = cfg()
  local out = {}
  for name in pairs(all) do
    if name ~= 'claude' then out[#out + 1] = name end
  end
  table.sort(out)
  table.insert(out, 1, 'claude')
  return out
end

---Whether the command of agent `name` can run here (Claude's `claude.cmd`, an ACP agent's `cmd`).
---@param name string
---@return boolean available, string|nil cmd the program looked for
function M.available(name)
  local argv
  if name == 'claude' then
    argv = require('agent-ide.config').get().claude.cmd
  else
    local c = cfg()[name]
    argv = type(c) == 'table' and c.cmd or nil
  end
  if type(argv) ~= 'table' or type(argv[1]) ~= 'string' then return false, nil end
  return vim.fn.executable(argv[1]) == 1, argv[1]
end

---Test only: forget the ACP adapters made so far.
function M._reset() acp, acp_cfg = {}, nil end

return M
