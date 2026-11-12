-- Changing the queue of a session from the queue panel (ui/queue.lua): `e` opens a queued prompt
-- in a buffer of its own, `:w` puts the text back in its place in the queue, byte for byte (an
-- empty save takes it out); `dd` deletes a queued prompt (into the unnamed register, as Vim's
-- `dd` does); `J` and `K` move one down or up. Claude never sees a queued prompt before it
-- starts (the plugin holds the queue), so all of this is safe until then; a prompt that started
-- meanwhile is not changed, and the save says so.
local api = vim.api

local M = {}

local edits = {} -- buf -> { s, text } the queued text the buffer stands for

-- Index of `text` in the queue of `s`, nearest to `near` first (equal texts may be queued twice).
local function find(s, text, near)
  if near and s.queue[near] == text then return near end
  for i, t in ipairs(s.queue) do
    if t == text then return i end
  end
end

local function save(buf)
  local e = edits[buf]
  if not e then return end
  local i = find(e.s, e.text, e.n)
  if not i then
    vim.notify('Agent-IDE: this prompt is no longer queued (it was sent or taken back); nothing changed', vim.log.levels.WARN)
    return
  end
  local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  if vim.trim(text) == '' then
    table.remove(e.s.queue, i)
    edits[buf] = nil
    vim.bo[buf].modified = false
    e.s:_emit('meta')
    vim.notify('Agent-IDE: empty prompt taken out of the queue', vim.log.levels.INFO)
    return
  end
  e.s.queue[i] = text
  e.text, e.n = text, i
  vim.bo[buf].modified = false
  e.s:_emit('meta')
end

---Open queued prompt `n` of `s` in a buffer, in a split above the transcript window `twin`
---(else above the current window). The focus goes there.
---@param s table Session
---@param n integer
---@param twin integer|nil
function M.edit(s, n, twin)
  local text = s.queue[n]
  if not text then return end
  for b, e in pairs(edits) do -- the same prompt already open: go there
    if e.s == s and e.text == text and api.nvim_buf_is_valid(b) then
      local w = vim.fn.win_findbuf(b)[1]
      if w then return api.nvim_set_current_win(w) end
      return api.nvim_open_win(b, true, { split = 'above', win = (twin and api.nvim_win_is_valid(twin)) and twin or 0 })
    end
  end
  local buf = api.nvim_create_buf(false, false)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.b[buf].agent_ide_kind, vim.b[buf].agent_ide_session = 'queued', s.id
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = 'markdown'
  require('agent-ide.ui.bufname').track(buf, s, ' · queued prompt', function() return require('agent-ide.ui.chat').project_of(s) end)
  edits[buf] = { s = s, text = text, n = n }
  api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function(ev) save(ev.buf) end })
  api.nvim_create_autocmd('BufWipeout', { buffer = buf, callback = function(ev) edits[ev.buf] = nil end })
  local win = api.nvim_open_win(buf, true, { split = 'above', win = (twin and api.nvim_win_is_valid(twin)) and twin or 0,
    height = math.max(6, math.min(15, #vim.split(text, '\n', { plain = true }) + 2)) })
  api.nvim_set_option_value('winbar', '%=%#AgentIdePromptLabel#queued prompt · :w saves it back%*', { scope = 'local', win = win })
end

---Delete queued prompt `n` of `s`; the text goes to the unnamed register.
---@param s table Session
---@param n integer
function M.delete(s, n)
  local text = table.remove(s.queue, n)
  if not text then return end
  vim.fn.setreg('"', text)
  s:_emit('meta')
end

---Move queued prompt `n` of `s` by `by` (-1 up, 1 down); returns its new place, nil when it
---cannot move.
---@param s table Session
---@param n integer
---@param by integer
---@return integer|nil
function M.move(s, n, by)
  local to = n + by
  if not s.queue[n] or to < 1 or to > #s.queue then return nil end
  s.queue[n], s.queue[to] = s.queue[to], s.queue[n]
  s:_emit('meta')
  return to
end

return M
