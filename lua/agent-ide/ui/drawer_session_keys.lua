-- Chat keys on a drawer session row: the model picker, the permission mode cycle, interrupt,
-- native Claude in tmux and the raw view, for the session of that row and without opening its
-- chat. The lhs are the chat's (`keys.chat.*`), so a remap applies in both places; a drawer key
-- with the same lhs wins. On other rows a provider's row key with the same lhs still works, the
-- mode and interrupt keys keep Vim's meaning, the others do nothing.
local api = vim.api
local keylist = require('agent-ide.util.keys')

local M = {}

local function elsewhere_msg()
  return 'Agent-IDE: session is running in another Claude; use ' .. keylist.first('drawer', 'tmux') .. ' in the drawer to jump to it'
end

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO) end

-- The Session of a drawer session row (made like `<CR>` makes it; it starts nothing).
local function session_of(node)
  local m, p = node.session, node.project
  return require('agent-ide.session').open({ id = m.id, cwd = m.cwd or p.root or p.key, path = m.path, title = m.title })
end

-- Another Claude runs the session of `node` (a Session's own check, else the live map).
local function elsewhere(node)
  local s = require('agent-ide.session').get(node.session.id)
  if s then return s:_elsewhere() end
  return require('agent-ide.live').fresh()[node.session.id] ~= nil
end

local function later(s) return s:_alive() and '' or '; takes effect when the session starts' end

-- name in `keys.chat`, help text, action on a session row; `fall`: Vim's meaning elsewhere
local ACTIONS = {
  { name = 'model', desc = 'pick the model', run = function(node)
    if elsewhere(node) then return notify(elsewhere_msg(), vim.log.levels.WARN) end
    local s = session_of(node)
    require('agent-ide.ui.mode').pick_model(s, function(model)
      notify(('Agent-IDE: model %s%s'):format(model, later(s)))
    end)
  end },
  { name = 'mode', fall = true, desc = 'next permission mode', run = function(node)
    if elsewhere(node) then return notify(elsewhere_msg(), vim.log.levels.WARN) end
    local s = session_of(node)
    require('agent-ide.ui.mode').cycle(s)
    notify(('Agent-IDE: mode %s%s'):format(tostring(s.mode_requested or s.mode), later(s)))
  end },
  { name = 'interrupt', fall = true, desc = 'interrupt Claude while it works (asks first)', run = function(node)
    if elsewhere(node) then return notify(elsewhere_msg(), vim.log.levels.WARN) end
    local s = require('agent-ide.session').get(node.session.id)
    if not (s and s:_alive() and (s.state == 'busy' or s.state == 'waiting')) then return end
    -- Ctrl-C is a reflex in normal mode; on a row (not in the chat) it asks first
    local title = tostring(node.session.title or s.title or 'session'):gsub('[\r\n\t]+', ' ')
    if vim.fn.confirm(('Interrupt Claude in "%s"?'):format(title), '&Interrupt\n&Cancel', 2) ~= 1 then return end
    require('agent-ide.ui.chat').interrupt(s)
  end },
  { name = 'native', desc = 'continue in native Claude in a tmux pane', run = function(node)
    local s = require('agent-ide.session').get(node.session.id)
    local away = s and require('agent-ide.ui.handoff').away(s) -- again: take it back
    if not away and elsewhere(node) then return notify(elsewhere_msg(), vim.log.levels.WARN) end
    require('agent-ide.ui.chat').native(session_of(node), node.project)
  end },
  { name = 'raw', desc = 'raw view in the main window', run = function(node)
    local main = require('agent-ide.ui.drawer').main_win()
    if not main then return end
    require('agent-ide.ui.raw').open(session_of(node), { win = main })
    api.nvim_set_current_win(main)
  end },
}

---The native Claude action on session row `node` (the drawer's tmux key, ui/drawer.lua).
---@param node table
function M.native(node)
  for _, a in ipairs(ACTIONS) do
    if a.name == 'native' then return M.run(a, nil, node) end
  end
end

---Run the key `lhs` of action `a` on drawer row `node`.
function M.run(a, lhs, node)
  if node and node.type == 'session' then
    local ok, err = pcall(a.run, node)
    if not ok then notify('Agent-IDE: ' .. tostring(err), vim.log.levels.ERROR) end
  elseif node and node.keys and node.keys[lhs] then
    local ok, err = pcall(node.keys[lhs], node)
    if not ok then notify('Agent-IDE: ' .. tostring(err), vim.log.levels.ERROR) end
  elseif a.fall then
    api.nvim_feedkeys(vim.keycode(lhs), 'in', false)
  end
end

---Map the keys in the drawer buffer `buf`; `own` holds the drawer's own lhs (keycodes), which win.
---@param buf integer
---@param own table<string, boolean>
---@param current_node fun(): table|nil
function M.map(buf, own, current_node)
  local keys = require('agent-ide.ui.chat_keys').keys()
  for _, a in ipairs(ACTIONS) do
    for _, lhs in ipairs(keylist.list(keys[a.name])) do
      if not own[vim.keycode(lhs)] then
        vim.keymap.set('n', lhs, function() M.run(a, lhs, current_node()) end,
          { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: session row: ' .. a.desc })
      end
    end
  end
end

---Help rows: a heading, then the keys as mapped (`own` as for `map`).
---@param own table<string, boolean>
---@return table[]
function M.help_rows(own)
  local keys = require('agent-ide.ui.chat_keys').keys()
  local rows = {}
  for _, a in ipairs(ACTIONS) do
    local list = vim.tbl_filter(function(lhs) return not own[vim.keycode(lhs)] end, keylist.list(keys[a.name]))
    local k = keylist.label(list)
    if k then rows[#rows + 1] = { key = k, desc = a.desc } end
  end
  if #rows == 0 then return {} end
  table.insert(rows, 1, { heading = 'On a session row' })
  return rows
end

return M
