-- What the drawer shows about sessions, apart from its window: the state of a session, its
-- state word (what a waiting one waits for, why one failed, where it runs), and new sessions
-- no scan has listed yet.
local live = require('agent-ide.live')
local session = require('agent-ide.session')

local M = {}

-- Sessions started from "+ New session" that no scan has listed yet: id -> { key, activity }
local unsaved = {}

---Remember a session started from "+ New session" in project `key` until a scan lists it.
---@param id string
---@param key string project key
function M.add_unsaved(id, key) unsaved[id] = { key = key, activity = os.time() } end

---State shown for a session: its Session's state when this Neovim has one that is not
---parked, else the live state (another Claude, e.g. in a tmux pane).
---@param id string
---@return string
function M.state_of(id)
  local s = session.get(id)
  if s and s.state ~= 'parked' then return s.state end
  -- the live list may still show the process we just stopped until its next poll
  local e = live.get()[id]
  if s and e and s.pid ~= nil and e.pid == s.pid then return 'parked' end
  return live.state_of(live.get(), id)
end

local function first_line(text) return (text or ''):match('^%s*([^\r\n]*)') end

---Pids of the sessions running in another Claude (their tmux panes label the drawer rows).
---@return integer[]
function M.elsewhere_pids()
  local pids = {}
  for id, e in pairs(live.get()) do
    local s = session.get(id)
    if e.pid and (not s or s:_elsewhere()) then pids[#pids + 1] = e.pid end
  end
  table.sort(pids)
  return pids
end

local FAIL_REASON_MAX = 20

-- First line of the last error event of `s`, at most 20 characters.
local function fail_reason(s)
  for i = #s.events, 1, -1 do
    local ev = s.events[i]
    if ev.kind == 'meta' and ev.label == 'error' then
      local r = vim.trim(first_line(ev.text))
      if r == '' then return nil end
      return require('agent-ide.ui.layout').truncate(r, FAIL_REASON_MAX)
    end
  end
end

local WAIT_WORD = { AskUserQuestion = 'question', ExitPlanMode = 'plan to approve' }

---The state word of a session's drawer row, `{ text, hl_group }`, or nil:
---waiting: `permission: <tool>`, `question`, `plan to approve` (another Claude: `input`);
---done: `done, unread`; failed: `failed[: reason]`; handed to native Claude: `native`;
---running in another Claude: `tmux <window>.<pane>` (pane known) or `elsewhere`.
---@param id string
---@param state string as shown (see `state_of`)
---@return table|nil
function M.note_of(id, state)
  local s = session.get(id)
  local handoff = package.loaded['agent-ide.ui.handoff']
  if s and handoff and handoff.away(s) then return { 'native', 'AgentIdeAge' } end
  local e = live.get()[id]
  local elsewhere = e ~= nil and (s == nil or s:_elsewhere())
  if state == 'waiting' then
    local p = not elsewhere and s and s.state == 'waiting' and s.pending_permissions[1]
    if not p then return { 'input', 'AgentIdeWaiting' } end
    local tool = tostring(p.tool_name)
    return { WAIT_WORD[tool] or ('permission: ' .. tool), 'AgentIdeWaiting' }
  elseif state == 'done' then
    return { 'done, unread', 'AgentIdeDone' }
  elseif state == 'failed' then
    local r = s and fail_reason(s)
    return { r and ('failed: ' .. r) or 'failed', 'AgentIdeFailed' }
  elseif elsewhere and (state == 'busy' or state == 'idle') then
    local pane = e.pid and require('agent-ide.tmux').pane_label(e.pid)
    return { pane and ('tmux ' .. pane) or 'elsewhere', 'AgentIdeAge' }
  end
end

---Projects with the unsaved new sessions (once they have a prompt) added to their project.
---A session a scan lists is dropped from `unsaved`, so it never shows twice.
---@param projects table[]
---@return table[]
function M.with_unsaved(projects)
  if next(unsaved) == nil then return projects end
  local listed = {}
  for _, p in ipairs(projects) do
    for _, m in ipairs(p.sessions) do listed[m.id] = true end
  end
  for _, id in ipairs(vim.tbl_keys(unsaved)) do
    if listed[id] or not session.get(id) then unsaved[id] = nil end
  end
  local out = {}
  for i, p in ipairs(projects) do
    local extra = {}
    for id, u in pairs(unsaved) do
      local s = session.get(id)
      if u.key == p.key and #s.events > 0 then
        local title = s.title
        if not title then
          for _, ev in ipairs(s.events) do
            if ev.kind == 'prompt' then title = first_line(ev.text); break end
          end
        end
        extra[#extra + 1] = { id = id, cwd = s.cwd, title = title or 'new session', activity = u.activity }
      end
    end
    if #extra == 0 then
      out[i] = p
    else
      table.sort(extra, function(a, b)
        if a.activity ~= b.activity then return a.activity > b.activity end
        return a.id < b.id
      end)
      out[i] = setmetatable({ sessions = vim.list_extend(extra, p.sessions) }, { __index = p })
    end
  end
  return out
end

return M
