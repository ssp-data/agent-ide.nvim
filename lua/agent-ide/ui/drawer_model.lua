-- What the drawer shows about sessions, apart from its window: the state of a session, what a
-- waiting one waits for, and new sessions no scan has listed yet.
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

---Tool a waiting Session of this Neovim waits for (its oldest open ask), for its drawer row.
---@param id string
---@return string|nil
function M.waits_for(id)
  local s = session.get(id)
  local p = s and s.state == 'waiting' and s.pending_permissions[1]
  return p and (tostring(p.tool_name):gsub('[\r\n]', ' ')) or nil
end

local function first_line(text) return (text or ''):match('^%s*([^\r\n]*)') end

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
