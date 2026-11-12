-- The prompt window's winbar: a dim label on the right naming the session the prompt belongs to
-- and the model it sends with (`↑ Fix the parser · opus 5.5`), so a prompt is never taken for
-- another session's. When the transcript shown in the same tab is another session's, the label
-- says so in a warning colour; the chat puts the matching prompt in the window where that is safe
-- (`M.target`, chat.lua). `config.chat.prompt_label = false` leaves the winbar empty.
local api = vim.api

local M = {}

local function esc(t) return (t:gsub('%%', '%%%%')) end

local function seg(group, text) return '%#' .. group .. '#' .. esc(text) .. '%*' end

local function one_line(t) return (tostring(t or ''):gsub('[\r\n\t]+', ' ')) end

local function enabled()
  local c = require('agent-ide.config').get().chat
  return not (type(c) == 'table' and c.prompt_label == false)
end

---Winbar text of the prompt of `s` in a window `width` columns wide; `other` when the transcript
---above is another session's.
---@param s table Session
---@param width integer
---@param other boolean
---@return string
function M.text(s, width, other)
  if not enabled() then return '' end
  local title = one_line(s.title or 'new session')
  local truncate = require('agent-ide.ui.layout').truncate
  local W = vim.fn.strdisplaywidth
  if other then
    local tail = ' · not the transcript above'
    local room = width - W('prompt of ') - W(tail) - 1
    if room < 4 then return '%=' .. seg('AgentIdePromptOther', truncate('prompt of ' .. title, math.max(0, width - 1))) end
    return '%=' .. seg('AgentIdePromptOther', 'prompt of ' .. truncate(title, room) .. tail)
  end
  local model = one_line((require('agent-ide.ui.mode').labels(s)))
  local away = not s.model and (s:_elsewhere() or require('agent-ide.ui.handoff').away(s))
  local right = (not away and model ~= '') and (' · ' .. model) or ''
  local room = width - W('↑ ') - W(right) - 1
  if room < 4 then right, room = '', width - W('↑ ') - 1 end
  if room < 1 then return '' end
  return '%=' .. seg('AgentIdePromptLabel', '↑ ' .. truncate(title, room) .. right)
end

-- Session ids of the transcripts shown in tab `tab` (chat buffers), in window order.
local function shown_transcripts(tab)
  local ids, seen = {}, {}
  for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
    local b = api.nvim_win_get_buf(w)
    local id = vim.b[b].agent_ide_kind == 'chat' and vim.b[b].agent_ide_session or nil
    if id and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  return ids
end

---The session whose prompt window `win` should show instead of its own: the one transcript shown
---in its tab, when that is another session's; nil when they match, when no or several
---transcripts are shown, or while the user types in `win` (never swapped under typing).
---@param win integer a window showing a prompt buffer
---@return string|nil session id
function M.target(win)
  local own = vim.b[api.nvim_win_get_buf(win)].agent_ide_session
  local ids = shown_transcripts(api.nvim_win_get_tabpage(win))
  if #ids ~= 1 or ids[1] == own then return nil end
  if api.nvim_get_current_win() == win and api.nvim_get_mode().mode:sub(1, 1) ~= 'n' then return nil end
  return ids[1]
end

---Set the label of every prompt window in the current tab (a prompt buffer of a known session).
function M.refresh()
  local session = require('agent-ide.session')
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    local b = api.nvim_win_get_buf(w)
    if vim.b[b].agent_ide_kind == 'prompt' and api.nvim_win_get_config(w).relative == '' then
      local s = session.get(vim.b[b].agent_ide_session)
      if s then
        local ids = shown_transcripts(api.nvim_win_get_tabpage(w))
        local other = #ids > 0 and not vim.tbl_contains(ids, s.id)
        api.nvim_set_option_value('winbar', M.text(s, api.nvim_win_get_width(w), other), { scope = 'local', win = w })
      end
    end
  end
end

return M
