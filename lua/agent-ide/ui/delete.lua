-- `D` in the drawer: delete an inactive session into the plugin's trash (see trash.lua), and
-- `:AgentsTrash` to restore or purge what is there.
local api = vim.api
local trash = require('agent-ide.trash')

local M = {}

local function notify(msg, level) vim.notify('Agent-IDE: ' .. msg, level or vim.log.levels.INFO) end
local function warn(msg) notify(msg, vim.log.levels.WARN) end

-- Why session `id` may not be deleted now (from what this Neovim knows), or nil.
local function busy_reason(id)
  local s = require('agent-ide.session').get(id)
  if s then
    if require('agent-ide.ui.handoff').away(s) then return 'it is open in native Claude' end
    if s:_alive() or s.state ~= 'parked' then return 'it is active here; park it first (x)' end
  end
  if require('agent-ide.live').fresh()[id] then return 'it runs in another Claude' end
end

-- Buffers of session `id`: its chat (transcript, prompt) and raw view; the prompt's unsent text.
local function buffers_of(id)
  local out, prompt_text = {}, false
  for _, b in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(b)
    if vim.startswith(name, 'agent-ide://') and (name:sub(-#id - 1) == '/' .. id) then
      out[#out + 1] = b
      if vim.startswith(name, 'agent-ide://prompt/') and api.nvim_buf_is_loaded(b) then
        for _, l in ipairs(api.nvim_buf_get_lines(b, 0, -1, false)) do
          if l:find('%S') then prompt_text = true end
        end
      end
    end
  end
  return out, prompt_text
end

-- Close the buffers without closing the windows that show them (they get an empty buffer).
local function close_buffers(bufs)
  for _, b in ipairs(bufs) do
    for _, w in ipairs(vim.fn.win_findbuf(b)) do
      local scratch = api.nvim_create_buf(false, true)
      vim.bo[scratch].bufhidden = 'wipe'
      pcall(api.nvim_win_set_buf, w, scratch)
    end
    pcall(api.nvim_buf_delete, b, { force = true })
  end
end

---Delete the session of drawer node `node` after the checks and a confirm; `done()` runs after
---it was moved to the trash.
---@param node table drawer session node
---@param done fun()
function M.run(node, done)
  local m = node.session
  local id = m.id
  if not trash.valid_id(id) then return warn('cannot delete: not a session id') end
  if not m.path then return warn('cannot delete: the session has no transcript yet') end
  local why = busy_reason(id)
  if why then return warn('not deleted: ' .. why) end
  local _, unsent = buffers_of(id)
  if unsent then return warn('not deleted: its prompt holds unsent text') end
  local plan, err = trash.plan(id, m.path)
  if not plan then return warn('cannot delete: ' .. err) end
  -- the cached live map may be old (a terminal may have opened it a second ago): ask afresh
  local cfg = require('agent-ide.config').get()
  require('agent-ide.live').query({ cmd = cfg.live.cmd, interval_ms = cfg.live.interval_ms }, function(ok, reason)
    if not ok then return warn('not deleted: cannot check whether it runs elsewhere (' .. tostring(reason) .. ')') end
    why = busy_reason(id)
    if why then return warn('not deleted: ' .. why) end
    local bufs
    bufs, unsent = buffers_of(id)
    if unsent then return warn('not deleted: its prompt holds unsent text') end
    local p = node.project or {}
    local age = m.activity and require('agent-ide.ui.tree').ago(m.activity, os.time()) or '?'
    local msg = ('Move this session to the plugin\'s trash? Claude will no longer list it.\n\n%s\n%s · %s')
      :format((m.title or id):gsub('[\r\n]+', ' '), p.name or '?', age)
    if vim.fn.confirm(msg, '&Move to trash\n&Cancel', 2) ~= 1 then return end
    close_buffers(bufs)
    local dir, derr = trash.delete(id, m.path, { title = m.title, project = p.name })
    if not dir then return warn('not deleted: ' .. tostring(derr)) end
    require('agent-ide.session').forget(id)
    local hidden = require('agent-ide.hidden')
    if hidden.is(id) then hidden.set(id, false) end
    notify('moved to the trash (:AgentsTrash to restore)')
    done()
  end)
end

-- :AgentsTrash ---------------------------------------------------------------------------------

local function label(item)
  local m = item.manifest
  return ('%s  %s  %s'):format(os.date('%Y-%m-%d %H:%M', tonumber(m.deleted_at) or 0),
    (tostring(m.title or m.id)):gsub('[\r\n]+', ' '), tostring(m.project or '?'))
end

local function after_change()
  local drawer = package.loaded['agent-ide.ui.drawer']
  if drawer then drawer.rescan() end
end

---`:AgentsTrash`: pick a trashed session, then restore it or delete it for good.
---`:AgentsTrash empty`: delete everything in the trash for good (after a confirm).
---@param arg string|nil
function M.command(arg)
  local items = trash.list()
  if arg == 'empty' then
    if #items == 0 then return notify('the trash is empty') end
    if vim.fn.confirm(('Delete %d trashed session(s) for good?'):format(#items), '&Delete\n&Cancel', 2) ~= 1 then return end
    local n = 0
    for _, it in ipairs(items) do
      if trash.purge(it.dir) then n = n + 1 end
    end
    return notify(('deleted %d session(s) for good'):format(n))
  elseif arg and arg ~= '' then
    return warn('unknown argument: ' .. arg .. ' (only `empty`)')
  end
  if #items == 0 then return notify('the trash is empty') end
  vim.ui.select(items, { prompt = 'Trashed sessions', format_item = label }, function(item)
    if not item then return end
    vim.ui.select({ 'Restore', 'Delete for good', 'Cancel' }, { prompt = label(item) }, function(choice)
      if choice == 'Restore' then
        local ok, err = trash.restore(item)
        if not ok then return warn('not restored: ' .. tostring(err)) end
        notify('restored')
        after_change()
      elseif choice == 'Delete for good' then
        if trash.purge(item.dir) then notify('deleted for good') else warn('could not delete ' .. item.dir) end
      end
    end)
  end)
end

return M
