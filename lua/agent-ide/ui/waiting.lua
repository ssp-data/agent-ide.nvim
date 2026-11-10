-- "What needs me next": sessions waiting for an answer, then failed, then finished turns not
-- yet seen; `next_waiting` goes to the first of them.
local api = vim.api
local permission = require('agent-ide.ui.permission')
local session = require('agent-ide.session')

local M = {}

local function chat() return require('agent-ide.ui.chat') end

---Sessions that need the user, in order: waiting (oldest ask first), then failed, then done.
---Sessions waiting in another Claude come after this Neovim's waiting ones. Only sessions in
---scope (see scope.lua) count.
---@return { s: table|nil, id: string, elsewhere: boolean }[]
function M.needing()
  local live = require('agent-ide.live').fresh()
  local matches = require('agent-ide.scope').matches
  local out, mine = {}, {}
  local rank = { waiting = 1, failed = 3, done = 4 }
  for i, s in ipairs(session.all()) do
    mine[s.id] = s.state ~= 'parked' or nil
    local r = rank[s.state]
    if r and matches(s) then out[#out + 1] = { s = s, id = s.id, elsewhere = false, r = r, t = permission.oldest_ask(s), i = i } end
  end
  local n = #out
  for id, e in pairs(live) do
    if not mine[id] and e.status == 'waiting' and matches(e) then
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
  if #list == 0 then
    local scope = require('agent-ide.scope')
    local others = scope.project() and require('agent-ide.ui.drawer_model').others_needing(scope.matches) or 0
    local key = require('agent-ide.util.keys').first('drawer', 'scope')
    local msg = others > 0 and ('nothing in this project; %d in other projects (%s)'):format(others, key) or 'nothing needs you'
    return vim.notify('Agent-IDE: ' .. msg, vim.log.levels.INFO)
  end
  local pick = list[1]
  local cur = chat().current()
  if cur and pick.s == cur and permission.in_chat(cur) and list[2] then pick = list[2] end
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
  permission.maybe_prompt(pick.s, { force = true })
end

return M
